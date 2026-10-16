// §622 — сервер приёма настроек на TV (фича 031, функция «Сессия приёма»).
//
// С `DebugServer` код не делится намеренно: тот слушает только loopback и
// проверяет Host, этот слушает LAN и доверяет только ключу из QR — гарантии
// противоположные.
//
// Порядок обработки `POST /transfer`: размер (413) → конверт (400) →
// расшифровка (403; 400 и 403 — в счётчик отказов) → разбор бэкапа (422 с
// причиной) → 200 → закрытие сессии. Остальные маршруты — 404, после
// закрытия — 409, пока обрабатывается другой запрос — 503.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../app_log.dart';
import '../backup_service.dart';
import 'transfer_code.dart';
import 'transfer_envelope.dart';

/// Чем закончилась сессия приёма.
sealed class TransferSessionEnd {
  const TransferSessionEnd();
}

/// Принят и разобран бэкап. Дальше — предпросмотр восстановления.
class TransferReceived extends TransferSessionEnd {
  const TransferReceived(this.contents);
  final BackupContents contents;
}

/// Истекло время сессии.
class TransferExpired extends TransferSessionEnd {
  const TransferExpired();
}

/// Слишком много попыток с чужим ключом.
class TransferRejectedTooOften extends TransferSessionEnd {
  const TransferRejectedTooOften();
}

/// Сессию закрыл экран (уход, «New code»).
class TransferCancelled extends TransferSessionEnd {
  const TransferCancelled();
}

/// Последняя отвергнутая попытка — для строки состояния на экране приёма.
sealed class TransferProblem {
  const TransferProblem();
}

/// Содержимое не расшифровалось ключом сессии.
class TransferWrongKey extends TransferProblem {
  const TransferWrongKey(this.count);
  final int count;
}

/// Расшифровалось, но не является пригодным бэкапом (P6 на получателе).
class TransferInvalidBackup extends TransferProblem {
  const TransferInvalidBackup(this.reason);
  final String reason;
}

/// Разбор принятого текста. По умолчанию — тот же, что у файла бэкапа (P4).
typedef TransferParse = Future<BackupContents> Function(String raw);

class TransferReceiver {
  TransferReceiver._(
    this._server,
    this.key,
    this._parse,
    this._log,
    this._maxBodyBytes,
    this._maxRejects,
    Duration ttl,
  ) : port = _server.port {
    _timer = Timer(ttl, () {
      if (_accepted) return;
      _log('session expired');
      unawaited(_finish(const TransferExpired(), force: true));
    });
    _server.listen(_handle, onError: (Object e) => _log('server error: $e'));
  }

  static const sessionTtl = Duration(minutes: 10);
  static const maxBodyBytes = 32 * 1024 * 1024;
  static const maxRejects = 5;
  static const path = '/transfer';

  /// Открывает сессию: случайный ключ, порт, выбранный ОС.
  ///
  /// [bindAddress], [key], [ttl], пределы и [log] — для тестов; в работе
  /// сессия слушает все IPv4-интерфейсы.
  static Future<TransferReceiver> open({
    InternetAddress? bindAddress,
    List<int>? key,
    Duration ttl = sessionTtl,
    int maxBody = maxBodyBytes,
    int maxRejected = maxRejects,
    TransferParse? parse,
    void Function(String line)? log,
  }) async {
    final sink = log ?? (line) => AppLog.I.info('[transfer] $line');
    final server = await HttpServer.bind(
      bindAddress ?? InternetAddress.anyIPv4,
      0,
    );
    final rx = TransferReceiver._(
      server,
      Uint8List.fromList(key ?? newTransferKey()),
      parse ?? const BackupService().parseImport,
      sink,
      maxBody,
      maxRejected,
      ttl,
    );
    sink('session open, port ${server.port}');
    return rx;
  }

  final HttpServer _server;

  /// Ключ сессии. В журнал не пишется (P9).
  final Uint8List key;

  final TransferParse _parse;
  final void Function(String) _log;
  final int _maxBodyBytes;
  final int _maxRejects;
  late final Timer _timer;

  final _done = Completer<TransferSessionEnd>();
  bool _closed = false;

  /// Бэкап принят, ответ 200 ещё уходит: остальные запросы — 409.
  bool _accepted = false;

  /// В обработке один запрос (чтение тела, расшифровка, разбор): иначе
  /// параллельные запросы по 32 МиБ уронили бы TV по памяти. Остальные
  /// получают 503 до чтения тела.
  bool _busy = false;
  int _rejected = 0;

  /// Последняя отвергнутая попытка; null — пока не было. Не освобождается:
  /// запрос, начатый до [close], может дописать сюда уже после закрытия.
  final ValueNotifier<TransferProblem?> problem = ValueNotifier(null);

  /// Порт сессии; остаётся известным и после закрытия.
  final int port;

  bool get isClosed => _closed;

  /// Завершение сессии — ровно одно.
  Future<TransferSessionEnd> get done => _done.future;

  /// Код передачи для QR этой сессии.
  TransferCode codeFor(List<String> hosts, String name) => TransferCode(
    addresses: [for (final h in hosts) TransferEndpoint(h, port)],
    key: key,
    name: name,
  );

  /// Закрывает сессию; повторный вызов ничего не делает.
  Future<void> close() => _finish(const TransferCancelled(), force: true);

  Future<void> _finish(TransferSessionEnd end, {required bool force}) async {
    if (_closed) return;
    _closed = true;
    _timer.cancel();
    _log('session closed: ${end.runtimeType}');
    // Сначала порт, потом [done]: подписчик [done] вправе считать, что
    // порт уже отказывает (P1). Мягкое закрытие ждёт открытых соединений —
    // медленный клиент из LAN держал бы его сколько угодно, поэтому через
    // [_closeGrace] соединения рвутся.
    try {
      await _server.close(force: force).timeout(
            _closeGrace,
            onTimeout: () => _server.close(force: true),
          );
    } catch (e) {
      _log('server close failed: ${e.runtimeType}');
    } finally {
      if (!_done.isCompleted) _done.complete(end);
    }
  }

  static const _closeGrace = Duration(seconds: 2);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      if (req.method != 'POST' || req.uri.path != path) {
        await _reply(res, HttpStatus.notFound, 'not found');
        return;
      }
      if (_closed || _accepted) {
        await _reply(res, HttpStatus.conflict, 'session closed');
        return;
      }
      if (_busy) {
        _log('request refused: busy');
        await _reply(res, HttpStatus.serviceUnavailable, 'busy');
        return;
      }
      _busy = true;
      try {
        await _process(req, res);
      } finally {
        _busy = false;
      }
    } catch (e) {
      _log('request failed: ${e.runtimeType}');
      try {
        await _reply(res, HttpStatus.internalServerError, 'error');
      } catch (_) {}
    }
  }

  /// Попытка с неразобранным конвертом (400) или чужим ключом (403): идёт в
  /// счётчик, на [_maxRejects]-й сессия закрывается. Мусор тоже считается —
  /// иначе им можно было бы занимать единственный слот всю сессию.
  Future<void> _rejectAttempt(
    HttpResponse res,
    int status,
    String text,
    String why,
  ) async {
    _rejected++;
    _log('request rejected: $why ($_rejected/$_maxRejects)');
    problem.value = TransferWrongKey(_rejected);
    await _reply(res, status, text);
    if (_rejected >= _maxRejects) {
      await _finish(const TransferRejectedTooOften(), force: false);
    }
  }

  Future<void> _process(HttpRequest req, HttpResponse res) async {
    final body = await _readLimited(req);
    if (body == null) {
      _log('request rejected: too large');
      await _reply(res, HttpStatus.requestEntityTooLarge, 'too large');
      return;
    }

    final Uint8List clear;
    try {
      clear = await openTransferEnvelope(
        utf8.decode(body, allowMalformed: true),
        key,
      );
    } on TransferEnvelopeFormatException catch (e) {
      await _rejectAttempt(
        res,
        HttpStatus.badRequest,
        'bad envelope',
        'bad envelope (${e.message})',
      );
      return;
    } on TransferEnvelopeAuthException {
      await _rejectAttempt(res, HttpStatus.forbidden, 'wrong key', 'wrong key');
      return;
    }

    final BackupContents contents;
    try {
      final raw = utf8.decode(clear);
      contents = await _parse(raw);
    } on FormatException catch (e) {
      _log('request rejected: invalid backup');
      problem.value = TransferInvalidBackup(e.message);
      await _reply(res, HttpStatus.unprocessableEntity, e.message);
      return;
    }

    // Пока шёл разбор, сессию мог закрыть другой запрос или таймер.
    if (_closed || _accepted) {
      await _reply(res, HttpStatus.conflict, 'session closed');
      return;
    }
    _accepted = true;
    _log('backup received (${clear.length} bytes)');
    try {
      await _reply(res, HttpStatus.ok, 'ok');
    } finally {
      await _finish(TransferReceived(contents), force: false);
    }
  }

  /// Тело запроса не длиннее предела; null — предел превышен.
  Future<Uint8List?> _readLimited(HttpRequest req) async {
    if (req.contentLength > _maxBodyBytes) return null;
    final out = BytesBuilder(copy: false);
    await for (final chunk in req) {
      if (out.length + chunk.length > _maxBodyBytes) return null;
      out.add(chunk);
    }
    return out.takeBytes();
  }

  static Future<void> _reply(HttpResponse res, int status, String text) async {
    final bytes = utf8.encode(text);
    res
      ..statusCode = status
      ..persistentConnection = false
      ..headers.contentType = ContentType.text
      ..contentLength = bytes.length
      ..add(bytes);
    await res.close();
  }
}

/// Адреса для QR: IPv4 без loopback, link-local и туннелей; Wi-Fi и Ethernet
/// раньше прочих. Порядок внутри группы — как отдала система.
List<String> pickTransferAddresses(
  List<({String interface, String address})> candidates,
) {
  bool isTunnel(String name) =>
      name.startsWith('tun') ||
      name.startsWith('ppp') ||
      name.startsWith('wg') ||
      name.startsWith('ipsec');
  bool isLan(String name) =>
      name.startsWith('wlan') ||
      name.startsWith('eth') ||
      name.startsWith('en') ||
      name.startsWith('ap');
  bool usable(String ip) =>
      !ip.startsWith('127.') && !ip.startsWith('169.254.') && ip != '0.0.0.0';

  final lan = <String>[];
  final other = <String>[];
  for (final c in candidates) {
    if (isTunnel(c.interface) || !usable(c.address)) continue;
    final list = isLan(c.interface) ? lan : other;
    if (!list.contains(c.address)) list.add(c.address);
  }
  return [...lan, ...other.where((a) => !lan.contains(a))];
}

/// Локальные адреса устройства для кода передачи.
Future<List<String>> localTransferAddresses() async {
  final ifaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  return pickTransferAddresses([
    for (final i in ifaces)
      for (final a in i.addresses) (interface: i.name, address: a.address),
  ]);
}
