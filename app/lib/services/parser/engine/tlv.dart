/// §717 (контракт 1.1.175, MAPPER_ENGINE §4a) — бинарный контейнер
/// «тег–длина–значение» по ТАБЛИЦЕ ДИАЛЕКТА секции (`mappers.<kind>.tlv`).
///
/// Кодек не знает ни одного тега и ни одной схемы: номера, имена и типы полей
/// приходят из реестра. Формат отличается от соседнего набором тегов, а это
/// данные; общими остаются только кодировка целого (QUIC, RFC 9000 §16) и
/// DER↔PEM.
///
/// Декодер формы `tlv` ([decodeTlvText]) раскрывает пейлоад ссылки в объект
/// пространства `json`; обратный ход `emit.container: "tlv"`
/// ([encodeTlvObject]) собирает объект обратно в текст пейлоада.
library;

import 'dart:convert' show base64, base64Url, utf8;

import 'decoders.dart' show decodeUtf8Lenient;

/// Имя декодера формы и значение `emit.container`.
const kTlvDecoder = 'tlv';

/// Имена грамматики диалекта.
abstract final class TlvNames {
  static const inQuery = 'query';
  static const typeVarint = 'varint';
  static const typeString = 'string';
  static const typeBool = 'bool';
  static const typeEnum = 'enum';
  static const typeStringList = 'string_list';
  static const typeDerPem = 'der_pem';
  static const typeHostPort = 'hostport';
  static const unknownReject = 'reject';
}

/// Поле таблицы диалекта.
final class TlvField {
  const TlvField({
    required this.tag,
    required this.name,
    this.type = TlvNames.typeString,
    this.max,
    this.defaultValue,
    this.values = const {},
    this.prefix,
    this.host,
    this.port,
    this.rest,
  });

  factory TlvField.fromJson(Map<String, dynamic> j) => TlvField(
        tag: (j['tag'] as num?)?.toInt() ?? -1,
        name: j['name'] as String? ?? '',
        type: j['type'] as String? ?? TlvNames.typeString,
        max: (j['max'] as num?)?.toInt(),
        defaultValue: j['default'],
        values: {
          for (final e in ((j['values'] as Map?) ?? const {}).entries)
            '${e.key}': '${e.value}',
        },
        prefix: j['prefix'] as String?,
        host: j['host'] as String?,
        port: j['port'] as String?,
        rest: j['rest'] as String?,
      );

  final int tag;
  final String name;
  final String type;

  /// `varint`: значение больше — контейнер не прочитан.
  final int? max;

  /// Умолчание формата: равное ему значение в объект не кладётся и на выходе
  /// не пишется.
  final Object? defaultValue;

  /// `enum`: байт (десятичной строкой) → имя.
  final Map<String, String> values;

  /// `string`: обязательное начало значения.
  final String? prefix;

  /// `hostport`: ключи адреса без скобок, порта и списка адресов со второго.
  final String? host;
  final String? port;
  final String? rest;
}

/// Диалект контейнера секции.
final class TlvDialect {
  const TlvDialect({
    this.place = TlvNames.inQuery,
    this.unknownTag = 'skip',
    this.fields = const [],
  });

  factory TlvDialect.fromJson(Map<String, dynamic> j) => TlvDialect(
        place: j['in'] as String? ?? TlvNames.inQuery,
        unknownTag: j['unknown_tag'] as String? ?? 'skip',
        fields: [
          for (final f in (j['fields'] as List?) ?? const [])
            if (f is Map) TlvField.fromJson(f.cast<String, dynamic>()),
        ],
      );

  /// Место пейлоада: `query` — после `?`, `authority` — после `://`.
  final String place;
  final String unknownTag;
  final List<TlvField> fields;

  TlvField? byTag(int tag) {
    for (final f in fields) {
      if (f.tag == tag) return f;
    }
    return null;
  }

  TlvField? byName(String name) {
    for (final f in fields) {
      if (f.name == name) return f;
    }
    return null;
  }
}

/// Контейнер не прочитан (отказ формы).
class TlvFormatError implements Exception {
  const TlvFormatError();
}

/// QUIC-varint с позиции [offset]: значение и позиция за ним.
(int, int) readVarint(List<int> data, int offset) {
  if (offset >= data.length) throw const TlvFormatError();
  final first = data[offset] & 0xFF;
  final len = 1 << (first >> 6);
  if (offset + len > data.length) throw const TlvFormatError();
  var value = first & 0x3F;
  for (var i = 1; i < len; i++) {
    value = (value << 8) | (data[offset + i] & 0xFF);
  }
  return (value, offset + len);
}

/// QUIC-varint значения [value] (0 … 2^62−1) кратчайшей шириной.
List<int> writeVarint(int value) {
  if (value < 0) throw ArgumentError.value(value, 'value');
  if (value <= 0x3F) return [value];
  if (value <= 0x3FFF) return [0x40 | (value >> 8), value & 0xFF];
  if (value <= 0x3FFFFFFF) {
    return [
      0x80 | (value >> 24),
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];
  }
  return [
    0xC0 | ((value >> 56) & 0x3F),
    for (var s = 48; s >= 0; s -= 8) (value >> s) & 0xFF,
  ];
}

/// Одна запись: тег, длина значения, значение.
List<int> encodeTlv(int tag, List<int> value) =>
    [...writeVarint(tag), ...writeVarint(value.length), ...value];

/// Список строк: «длина + UTF-8» подряд.
List<int> encodeStringArray(Iterable<String> items) => [
      for (final s in items) ...[
        ...writeVarint(utf8.encode(s).length),
        ...utf8.encode(s),
      ],
    ];

/// `host:port` / `[v6]:port` / `host` → адрес без скобок и порт (`null` —
/// порта нет или он не число 1…65535; голый IPv6 без скобок порта не несёт).
(String, int?) splitHostPort(String address) {
  final a = address.trim();
  if (a.startsWith('[')) {
    final close = a.indexOf(']');
    if (close > 0) {
      final host = a.substring(1, close);
      final rest = a.substring(close + 1);
      return (host, rest.startsWith(':') ? _port(rest.substring(1)) : null);
    }
  }
  final colon = a.lastIndexOf(':');
  if (colon < 0 || a.indexOf(':') != colon) return (a, null);
  return (a.substring(0, colon), _port(a.substring(colon + 1)));
}

int? _port(String s) {
  final p = int.tryParse(s);
  return p != null && p > 0 && p <= 0xFFFF ? p : null;
}

/// Адрес с портом; IPv6 в скобках.
String joinHostPort(String host, int? port) {
  final h = host.contains(':') && !host.startsWith('[') ? '[$host]' : host;
  return port == null || port <= 0 ? h : '$h:$port';
}

const _pemBegin = '-----BEGIN CERTIFICATE-----';
const _pemEnd = '-----END CERTIFICATE-----';

/// Один DER-элемент → блок PEM `CERTIFICATE`: base64 строками по 64 символа,
/// без хвостового перевода строки.
String derToPem(List<int> der) {
  final b64 = base64.encode(der);
  final lines = <String>[
    for (var i = 0; i < b64.length; i += 64)
      b64.substring(i, i + 64 > b64.length ? b64.length : i + 64),
  ];
  return '$_pemBegin\n${lines.join('\n')}\n$_pemEnd';
}

/// DER-структуры подряд → блоки PEM через перевод строки.
///
/// Разбирается только заголовок ASN.1 (тег SEQUENCE и длина): годность
/// сертификата судит ядро.
String derChainToPem(List<int> der) {
  final blocks = <String>[];
  var off = 0;
  while (off < der.length) {
    final size = _derElementLen(der, off);
    blocks.add(derToPem(der.sublist(off, off + size)));
    off += size;
  }
  return blocks.join('\n');
}

int _derElementLen(List<int> b, int off) {
  final left = b.length - off;
  if (left < 2 || b[off] != 0x30) throw const TlvFormatError();
  final first = b[off + 1];
  var header = 2;
  var size = first;
  if (first & 0x80 != 0) {
    final n = first & 0x7F;
    if (n == 0 || n > 4 || left < 2 + n) throw const TlvFormatError();
    size = 0;
    for (var i = 0; i < n; i++) {
      size = (size << 8) | b[off + 2 + i];
    }
    header = 2 + n;
  }
  if (size <= 0 || header + size > left) throw const TlvFormatError();
  return header + size;
}

/// Все блоки `CERTIFICATE` текста → DER подряд; `null` — блок не закрыт или
/// его тело не base64. Значение тела бывает строкой и списком строк.
List<int>? pemToDerChain(Object? value) {
  final text = switch (value) {
    final String s => s,
    final List l => l.join('\n'),
    _ => null,
  };
  if (text == null) return null;
  final out = <int>[];
  var rest = text;
  while (true) {
    final i = rest.indexOf(_pemBegin);
    if (i < 0) break;
    rest = rest.substring(i + _pemBegin.length);
    final j = rest.indexOf(_pemEnd);
    if (j < 0) return null;
    try {
      out.addAll(base64.decode(
          rest.substring(0, j).replaceAll(RegExp(r'\s+'), '')));
    } on FormatException {
      return null;
    }
    rest = rest.substring(j + _pemEnd.length);
  }
  return out;
}

/// Пейлоад контейнера из текста ссылки по месту диалекта: всё после `?` либо
/// после `://`, до `#`. `null` — схемы, query или самого пейлоада нет.
String? tlvPayloadOf(TlvDialect d, String text) {
  var rest = text.trim();
  final idx = rest.indexOf('://');
  if (idx < 0) return null;
  rest = rest.substring(idx + 3);
  final hash = rest.indexOf('#');
  if (hash >= 0) rest = rest.substring(0, hash);
  if (d.place == TlvNames.inQuery) {
    final q = rest.indexOf('?');
    if (q < 0) return null;
    rest = rest.substring(q + 1);
  }
  rest = rest.trim();
  return rest.isEmpty ? null : rest;
}

/// Текст ссылки → объект контейнера; `null` — контейнер не прочитан.
///
/// [unwrap] снимает текстовую обёртку (base64 в любом из четырёх написаний) и
/// отдаёт байты либо `null`; пустая после снятия паддинга обёртка — пустой
/// контейнер, а не отказ: обязательность полей судят записи.
Map<String, dynamic>? decodeTlvText(
  TlvDialect d,
  String text, {
  required List<int>? Function(String) unwrap,
}) {
  final payload = tlvPayloadOf(d, text);
  if (payload == null) return null;
  final bare = payload.replaceAll(RegExp(r'=+$'), '');
  final bytes = bare.isEmpty ? const <int>[] : unwrap(bare);
  if (bytes == null) return null;
  try {
    return decodeTlvBytes(d, bytes);
  } on TlvFormatError {
    return null;
  }
}

/// Байты контейнера → объект. Бросает [TlvFormatError].
///
/// Повтор тега — побеждает последний (в том числе когда последний равен
/// умолчанию: ключ снимается); исключение — `hostport` со списком `rest`.
Map<String, dynamic> decodeTlvBytes(TlvDialect d, List<int> data) {
  final obj = <String, dynamic>{};
  final hostSeen = <String>{};
  var off = 0;
  while (off < data.length) {
    final (tag, afterTag) = readVarint(data, off);
    final (len, afterLen) = readVarint(data, afterTag);
    if (len > data.length - afterLen) throw const TlvFormatError();
    final v = data.sublist(afterLen, afterLen + len);
    off = afterLen + len;

    final f = d.byTag(tag);
    if (f == null) {
      if (d.unknownTag == TlvNames.unknownReject) throw const TlvFormatError();
      continue;
    }
    if (f.type == TlvNames.typeHostPort) {
      _putHostPort(obj, f, v, hostSeen);
      continue;
    }
    final value = _decodeValue(f, v);
    if (value == null || value == f.defaultValue) {
      obj.remove(f.name);
    } else {
      obj[f.name] = value;
    }
  }
  return obj;
}

void _putHostPort(
    Map<String, dynamic> obj, TlvField f, List<int> v, Set<String> seen) {
  final raw = decodeUtf8Lenient(v).trim();
  if (raw.isEmpty) return;
  if (seen.contains(f.name) && f.rest != null) {
    (obj[f.rest!] ??= <String>[]).add(raw);
    return;
  }
  seen.add(f.name);
  final (host, port) = splitHostPort(raw);
  obj[f.name] = raw;
  if (f.host != null) obj[f.host!] = host;
  if (f.port != null) {
    if (port != null) {
      obj[f.port!] = port;
    } else {
      obj.remove(f.port);
    }
  }
}

/// Значение поля по типу; `null` — поля нет (пустая строка, пустой список).
Object? _decodeValue(TlvField f, List<int> v) {
  switch (f.type) {
    case TlvNames.typeVarint:
      final (n, _) = readVarint(v, 0);
      if (f.max != null && n > f.max!) throw const TlvFormatError();
      return n;
    case TlvNames.typeBool:
      if (v.length != 1 || v[0] > 1) throw const TlvFormatError();
      return v[0] == 1;
    case TlvNames.typeEnum:
      if (v.length != 1) throw const TlvFormatError();
      final name = f.values['${v[0]}'];
      if (name == null) throw const TlvFormatError();
      return name;
    case TlvNames.typeStringList:
      final out = <String>[];
      var off = 0;
      while (off < v.length) {
        final (len, next) = readVarint(v, off);
        if (len > v.length - next) throw const TlvFormatError();
        out.add(decodeUtf8Lenient(v.sublist(next, next + len)));
        off = next + len;
      }
      return out.isEmpty ? null : out;
    case TlvNames.typeDerPem:
      final pem = derChainToPem(v);
      return pem.isEmpty ? null : pem;
    case TlvNames.typeString:
      final s = decodeUtf8Lenient(v);
      if (s.isEmpty) return null;
      if (f.prefix != null && !s.startsWith(f.prefix!)) {
        throw const TlvFormatError();
      }
      return s;
  }
  throw const TlvFormatError();
}

/// Объект контейнера → текст пейлоада (base64url без паддинга).
///
/// Порядок записей — [order] (`emit.param_order`), затем остальные поля в
/// порядке таблицы. Не пишется: значение, равное умолчанию формата, пустая
/// строка, пустой список, имя `enum` вне таблицы. `null` — объект диалектом
/// не выражается (целое не целое, PEM не читается).
String? encodeTlvObject(
    TlvDialect d, Map<String, dynamic> obj, List<String> order) {
  final names = <String>[];
  for (final n in order) {
    if (!names.contains(n) && d.byName(n) != null) names.add(n);
  }
  for (final f in d.fields) {
    if (!names.contains(f.name)) names.add(f.name);
  }
  final out = <int>[];
  for (final name in names) {
    final f = d.byName(name)!;
    final values = _encodeField(f, obj);
    if (values == null) return null;
    for (final v in values) {
      out.addAll(encodeTlv(f.tag, v));
    }
  }
  return base64Url.encode(out).replaceAll('=', '');
}

List<String> _strings(Object? v) => switch (v) {
      final List l => [
          for (final e in l)
            if ('$e'.isNotEmpty) '$e',
        ],
      final String s when s.isNotEmpty => [s],
      _ => const [],
    };

bool _boolOf(Object? v) => switch (v) {
      final bool b => b,
      final num n => n != 0,
      final String s => s == '1' || const {'true', 'yes'}.contains(s.toLowerCase()),
      _ => false,
    };

/// Значения одного поля (несколько — только у адреса со списком `rest`);
/// пустой список — поля нет либо оно равно умолчанию; `null` — отказ.
List<List<int>>? _encodeField(TlvField f, Map<String, dynamic> obj) {
  if (f.type == TlvNames.typeHostPort) {
    var first = '${obj[f.name] ?? ''}';
    if (first.isEmpty && f.host != null) {
      final host = '${obj[f.host] ?? ''}';
      if (host.isNotEmpty) {
        final p = f.port == null ? null : obj[f.port];
        first = joinHostPort(host, p is num ? p.toInt() : int.tryParse('$p'));
      }
    }
    return [
      if (first.isNotEmpty) utf8.encode(first),
      if (f.rest != null)
        for (final s in _strings(obj[f.rest])) utf8.encode(s),
    ];
  }
  final v = obj[f.name];
  if (v == null) return const [];
  switch (f.type) {
    case TlvNames.typeVarint:
      final n = v is num ? v.toInt() : int.tryParse('$v'.trim());
      if (n == null || n < 0) return null;
      return n == f.defaultValue ? const [] : [writeVarint(n)];
    case TlvNames.typeBool:
      final b = _boolOf(v);
      return b == f.defaultValue
          ? const []
          : [
              [b ? 1 : 0]
            ];
    case TlvNames.typeEnum:
      final name = '$v';
      if (name.isEmpty || name == f.defaultValue) return const [];
      for (final e in f.values.entries) {
        if (e.value != name) continue;
        final b = int.tryParse(e.key);
        if (b == null || b < 0 || b > 0xFF) break;
        return [
          [b]
        ];
      }
      return const [];
    case TlvNames.typeStringList:
      final buf = encodeStringArray(_strings(v));
      return buf.isEmpty ? const [] : [buf];
    case TlvNames.typeDerPem:
      final der = pemToDerChain(v);
      if (der == null) return null;
      return der.isEmpty ? const [] : [der];
  }
  final s = '$v';
  return s.isEmpty ? const [] : [utf8.encode(s)];
}
