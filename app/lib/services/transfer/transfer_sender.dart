// §622 — отправка настроек на TV (фича 031, функция «Отправка на TV»).
//
// P7: отправитель идёт на локальный адрес мимо своего туннеля. В allow-mode
// LxBox сам лежит в туннеле (`BoxService.buildOverrideOptions`, «+self»), и
// запрос на 192.168.x.x мог бы уйти в sing-box. Поэтому сначала — нативный
// `lanPost`: сокет привязан к сети Wi-Fi/Ethernet без TRANSPORT_VPN
// (владелец VPN вправе выбрать физическую сеть и без allowBypass). Нет такой
// сети или канала — обычный `HttpClient`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../app_log.dart';
import '../platform_channels.dart';
import '../subscription/user_agent.dart';
import 'transfer_code.dart';
import 'transfer_receiver.dart';

/// Итог отправки — по нему экран выбирает текст (P6).
enum TransferSendStatus {
  /// 200: получатель принял и разобрал бэкап.
  sent,

  /// Ни один адрес не ответил: другая сеть или изоляция клиентов в Wi-Fi.
  unreachable,

  /// Порт закрыт или 409: сессия истекла или уже использована.
  expired,

  /// 403: ключ не подошёл (код от другой сессии).
  rejected,

  /// 413: содержимое больше предела получателя.
  tooLarge,

  /// 422: получатель расшифровал, но не может восстановить такой бэкап.
  invalid,

  /// 503: получатель обрабатывает другой запрос (один за раз).
  busy,

  /// Прочие ответы.
  failed,
}

class TransferSendResult {
  const TransferSendResult(this.status, {this.httpStatus, this.detail});
  final TransferSendStatus status;
  final int? httpStatus;

  /// Причина от получателя (422) или текст сетевой ошибки.
  final String? detail;
}

/// Ответ получателя → итог. Чистая функция для юнитов.
TransferSendResult transferResultForResponse(int status, String body) =>
    switch (status) {
      200 => const TransferSendResult(TransferSendStatus.sent, httpStatus: 200),
      403 =>
        const TransferSendResult(TransferSendStatus.rejected, httpStatus: 403),
      409 =>
        const TransferSendResult(TransferSendStatus.expired, httpStatus: 409),
      413 =>
        const TransferSendResult(TransferSendStatus.tooLarge, httpStatus: 413),
      503 =>
        const TransferSendResult(TransferSendStatus.busy, httpStatus: 503),
      422 => TransferSendResult(TransferSendStatus.invalid,
          httpStatus: 422, detail: body.trim()),
      _ => TransferSendResult(TransferSendStatus.failed, httpStatus: status),
    };

/// Исход одной попытки на один адрес.
sealed class LanPostOutcome {
  const LanPostOutcome();
}

/// Получатель ответил.
class LanPostResponse extends LanPostOutcome {
  const LanPostResponse(this.status, this.body);
  final int status;
  final String body;
}

/// Хост ответил отказом соединения: порт сессии закрыт.
class LanPostRefused extends LanPostOutcome {
  const LanPostRefused();
}

/// Таймаут или нет маршрута.
class LanPostUnreachable extends LanPostOutcome {
  const LanPostUnreachable(this.detail);
  final String detail;
}

/// Нативной не-VPN сети нет (или нет канала) — пробовать Dart-клиентом.
class LanPostNoNetwork extends LanPostOutcome {
  const LanPostNoNetwork();
}

typedef LanPost = Future<LanPostOutcome> Function(
    TransferEndpoint endpoint, Uint8List body);

const _connectTimeout = Duration(seconds: 5);

/// Ответ ждём дольше соединения: TV расшифровывает и разбирает бэкап.
const _responseTimeout = Duration(seconds: 60);

/// Отправляет конверт по адресам кода по очереди.
class TransferSender {
  TransferSender({LanPost? nativePost, LanPost? dartPost})
      : _native = nativePost ?? nativeLanPost,
        _dart = dartPost ?? dartLanPost;

  final LanPost _native;
  final LanPost _dart;

  Future<TransferSendResult> send(TransferCode code, String envelope) async {
    final body = Uint8List.fromList(utf8.encode(envelope));
    var refused = false;
    String? lastError;
    for (final ep in code.addresses) {
      var out = await _native(ep, body);
      if (out is LanPostNoNetwork) {
        AppLog.I.info('[transfer] no non-VPN network, plain socket to $ep');
        out = await _dart(ep, body);
      }
      switch (out) {
        case LanPostResponse(:final status, body: final text):
          AppLog.I.info('[transfer] $ep answered $status');
          return transferResultForResponse(status, text);
        case LanPostRefused():
          AppLog.I.info('[transfer] $ep refused');
          refused = true;
        case LanPostUnreachable(:final detail):
          AppLog.I.info('[transfer] $ep unreachable: $detail');
          lastError = detail;
        case LanPostNoNetwork():
          lastError = 'no network';
      }
    }
    return refused
        ? const TransferSendResult(TransferSendStatus.expired)
        : TransferSendResult(TransferSendStatus.unreachable, detail: lastError);
  }
}

const _utils = MethodChannel(PlatformChannels.utils);

/// Kotlin `lanPost`: сокет на сети Wi-Fi/Ethernet без VPN (`MainActivity`).
Future<LanPostOutcome> nativeLanPost(
    TransferEndpoint ep, Uint8List body) async {
  try {
    final r = await _utils.invokeMapMethod<String, Object?>('lanPost', {
      'host': ep.host,
      'port': ep.port,
      'path': TransferReceiver.path,
      'body': body,
      'connectTimeoutMs': _connectTimeout.inMilliseconds,
      'readTimeoutMs': _responseTimeout.inMilliseconds,
      'userAgent': resolveAppUserAgent(),
    });
    return switch (r?['outcome']) {
      'response' => LanPostResponse(
          (r!['status'] as num?)?.toInt() ?? 0, r['body']?.toString() ?? ''),
      'refused' => const LanPostRefused(),
      'unreachable' => LanPostUnreachable(r!['detail']?.toString() ?? ''),
      _ => const LanPostNoNetwork(),
    };
  } on MissingPluginException {
    return const LanPostNoNetwork();
  } on PlatformException {
    return const LanPostNoNetwork();
  }
}

/// Обычный `HttpClient` без прокси.
Future<LanPostOutcome> dartLanPost(TransferEndpoint ep, Uint8List body) async {
  final client = HttpClient()
    ..connectionTimeout = _connectTimeout
    ..findProxy = ((_) => 'DIRECT')
    ..userAgent = resolveAppUserAgent();
  try {
    final req = await client
        .post(ep.host, ep.port, TransferReceiver.path)
        .timeout(_connectTimeout + const Duration(seconds: 1));
    req.headers.contentType = ContentType.json;
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close().timeout(_responseTimeout);
    final text = await res
        .transform(utf8.decoder)
        .join()
        .timeout(_responseTimeout);
    return LanPostResponse(res.statusCode, text);
  } on SocketException catch (e) {
    // ECONNREFUSED: 111 на Linux/Android, 61 на macOS (юниты на хосте).
    final code = e.osError?.errorCode;
    if (code == 111 || code == 61) return const LanPostRefused();
    return LanPostUnreachable(e.osError?.message ?? e.message);
  } on TimeoutException {
    return const LanPostUnreachable('timeout');
  } on HttpException catch (e) {
    return LanPostUnreachable(e.message);
  } finally {
    client.close(force: true);
  }
}
