// §622 — код передачи настроек (содержимое QR на экране приёма TV).
//
// Формат — фича 031-DEVICE_TRANSFER, «Код передачи»:
//   lxbox-transfer:1?a=<ipv4>:<port>[,<ipv4>:<port>…]&k=<ключ base64url>&n=<имя>
//
// Чистые функции без ввода-вывода. Сканер может принести любой QR, поэтому
// разбор отвергает чужую схему, другую версию и код без ключа — `null`, а не
// исключение: вызывающему нужен только факт «это не наш код».

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Схема кода передачи.
const kTransferScheme = 'lxbox-transfer';

/// Версия формата кода и конверта.
const kTransferVersion = 1;

/// Длина одноразового ключа сессии (AES-256).
const kTransferKeyLength = 32;

/// Один адрес получателя: локальный IPv4 и порт сессии.
class TransferEndpoint {
  const TransferEndpoint(this.host, this.port);

  final String host;
  final int port;

  @override
  String toString() => '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is TransferEndpoint && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

/// Разобранный код передачи.
///
/// [toString] ключ не показывает (P9): объект может попасть в журнал через
/// интерполяцию, а полный текст кода — только [encode].
class TransferCode {
  TransferCode({
    required List<TransferEndpoint> addresses,
    required List<int> key,
    required this.name,
  })  : addresses = List.unmodifiable(addresses),
        key = Uint8List.fromList(key) {
    if (this.addresses.isEmpty) {
      throw ArgumentError.value(addresses, 'addresses', 'empty');
    }
    if (this.key.length != kTransferKeyLength) {
      throw ArgumentError.value(key.length, 'key', 'must be 32 bytes');
    }
  }

  /// Адреса по порядку предпочтения: отправитель пробует их по очереди.
  final List<TransferEndpoint> addresses;

  /// Ключ сессии, 32 байта.
  final Uint8List key;

  /// Имя устройства-получателя, показывается отправителю до отправки.
  final String name;

  /// Текст для QR. Адреса и ключ пишутся как есть (их алфавит безопасен в
  /// query), имя — через percent-encoding.
  String encode() {
    final a = addresses.join(',');
    final k = encodeTransferKey(key);
    final n = Uri.encodeQueryComponent(name);
    return '$kTransferScheme:$kTransferVersion?a=$a&k=$k&n=$n';
  }

  /// Разбор текста из сканера. `null` — не код передачи версии 1.
  static TransferCode? tryParse(String text) {
    final s = text.trim();
    const prefix = '$kTransferScheme:';
    if (!s.startsWith(prefix)) return null;
    final rest = s.substring(prefix.length);
    final q = rest.indexOf('?');
    if (q < 0) return null;
    if (rest.substring(0, q) != '$kTransferVersion') return null;

    final Map<String, String> params;
    try {
      params = Uri.splitQueryString(rest.substring(q + 1));
    } catch (_) {
      return null;
    }

    final key = decodeTransferKey(params['k'] ?? '');
    if (key == null) return null;

    final addresses = <TransferEndpoint>[];
    for (final part in (params['a'] ?? '').split(',')) {
      final ep = _parseEndpoint(part.trim());
      if (ep == null) return null;
      addresses.add(ep);
    }
    if (addresses.isEmpty) return null;

    return TransferCode(
      addresses: addresses,
      key: key,
      name: (params['n'] ?? '').trim(),
    );
  }

  @override
  String toString() =>
      '$kTransferScheme:$kTransferVersion?a=${addresses.join(',')}&k=***&n=$name';
}

/// Новый одноразовый ключ сессии из криптостойкого генератора.
Uint8List newTransferKey([Random? random]) {
  final rnd = random ?? Random.secure();
  return Uint8List.fromList(
      List<int>.generate(kTransferKeyLength, (_) => rnd.nextInt(256)));
}

/// Ключ в base64url без `=` — форма в коде передачи.
String encodeTransferKey(List<int> key) =>
    base64Url.encode(key).replaceAll('=', '');

/// Обратное [encodeTransferKey]; `null` — не base64url или не 32 байта.
Uint8List? decodeTransferKey(String text) {
  if (text.isEmpty) return null;
  try {
    final bytes = base64Url.decode(base64Url.normalize(text));
    return bytes.length == kTransferKeyLength ? bytes : null;
  } on FormatException {
    return null;
  }
}

final _ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');

TransferEndpoint? _parseEndpoint(String text) {
  final colon = text.lastIndexOf(':');
  if (colon <= 0) return null;
  final host = text.substring(0, colon);
  final port = int.tryParse(text.substring(colon + 1));
  if (port == null || port < 1 || port > 65535) return null;
  final m = _ipv4.firstMatch(host);
  if (m == null) return null;
  for (var i = 1; i <= 4; i++) {
    if (int.parse(m.group(i)!) > 255) return null;
  }
  return TransferEndpoint(host, port);
}
