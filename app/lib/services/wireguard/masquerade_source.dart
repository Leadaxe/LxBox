/// §623 — маскировка WireGuard/AmneziaWG (`ip`/`id`/`ib`, ядро строит `i1`)
/// в тексте источника узла.
///
/// Чистые функции без ввода-вывода: секция Masquerade экрана узла пишет
/// ключи в источник, дальше текст идёт тем же путём, что Save вкладки Source.
/// Вид источника — `originKindOf`/`sourceKindOf` (§480/§482), своего
/// сниффера здесь нет.
library;

import 'dart:convert';

import '../../models/codec/source_record.dart';
import '../contract/registry.dart';
import '../parser/body_decoder.dart' show SourceKind;
import '../tailscale_network.dart' show withBodyFields;

/// Маскировка узла: `null`-поле = ключа нет.
class Masquerade {
  const Masquerade({this.ip, this.id, this.ib});

  /// Протокол приманки: `quic` · `dns` · `stun` · `sip`.
  final String? ip;

  /// Домен приманки (SNI у `quic`, QNAME у `dns`, host у `sip`).
  final String? id;

  /// Профиль клиента у `quic`: `chrome` · `firefox` · `curl`.
  final String? ib;

  static const off = Masquerade();

  /// Значения формы → ключи, которые уйдут в тело. Ключи, которых форма при
  /// этом [ip] не показывает, убираются: в теле не остаётся сочетания,
  /// которое ядро или разбор отвергнут (`ib` без `quic`).
  ///
  /// | [ip] | `ip` | `id` | `ib` |
  /// |---|---|---|---|
  /// | пусто (Off) | — | — | — |
  /// | `quic` | `quic` | [domain] или — | [ib] или — |
  /// | `dns` / `sip` | [ip] | [domain] или — | — |
  /// | `stun` | `stun` | — | — |
  factory Masquerade.fromForm(String ip, String domain, String ib) {
    final p = ip.trim().toLowerCase();
    final d = domain.trim();
    final b = ib.trim().toLowerCase();
    switch (p) {
      case '':
        return off;
      case 'quic':
        return Masquerade(
          ip: p,
          id: d.isEmpty ? null : d,
          ib: b.isEmpty ? null : b,
        );
      case 'dns':
      case 'sip':
        return Masquerade(ip: p, id: d.isEmpty ? null : d);
      default:
        return Masquerade(ip: p);
    }
  }

  /// Из полей модели узла (`awg.fields`).
  factory Masquerade.fromFields(Map<String, Object>? fields) {
    String? s(String k) {
      final v = fields?[k];
      return v is String && v.isNotEmpty ? v : null;
    }

    return Masquerade(ip: s('ip'), id: s('id'), ib: s('ib'));
  }

  bool get isOff => ip == null && id == null && ib == null;

  /// Смена протокола на [protocol] (`''` = Off) — ревизия 1 §623:
  ///
  /// - `Off` снимает всё;
  /// - `quic`: домен прежний, пустой — [randomDomain] (пул визарда; пустая
  ///   строка — домена нет, запись ещё невалидна); `ib` прежний;
  /// - `dns` / `sip`: домен прежний, `ib` снят (уход с `quic`);
  /// - `stun`: сняты `id` и `ib`.
  Masquerade withProtocol(String protocol, {String Function()? randomDomain}) {
    final p = protocol.trim().toLowerCase();
    var domain = id ?? '';
    if (p == 'quic' && domain.isEmpty) domain = randomDomain?.call() ?? '';
    return Masquerade.fromForm(p, domain, p == 'quic' ? ib ?? '' : '');
  }

  @override
  bool operator ==(Object other) =>
      other is Masquerade && other.ip == ip && other.id == id && other.ib == ib;

  @override
  int get hashCode => Object.hash(ip, id, ib);

  @override
  String toString() => 'Masquerade(ip: $ip, id: $id, ib: $ib)';
}

/// Можно ли писать маскировку в источник.
enum MasqueradeWritability {
  /// Ссылка с query, INI `[Interface]`, голое тело sing-box.
  writable,

  /// `awg://` с base64 `.conf` (§450), Amnezia `vpn://`.
  packedLink,

  /// Xray-конфиг, документ, несколько строк и прочее.
  unsupportedFormat,
}

/// Схемы ссылки WireGuard/AmneziaWG (`scheme_in` реестра).
const _kWgSchemes = {'wireguard', 'wg', 'awg', 'amneziawg'};

/// Ключи маскировки.
const _kKeys = ['ip', 'id', 'ib'];

/// Признак `conf_b64` из реестра (форма `<схема>://<base64 .conf>`): нет «@»
/// и весь текст из алфавита base64.
final _kPackedBody = RegExp(r'^[A-Za-z0-9+/=_-]+\s*$');

/// Можно ли писать маскировку в источник [raw].
MasqueradeWritability masqueradeWritability(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return MasqueradeWritability.unsupportedFormat;
  switch (originKindOf(t)) {
    case 'json':
      return sourceKindOf(t) == SourceKind.singboxOutbound
          ? MasqueradeWritability.writable
          : MasqueradeWritability.unsupportedFormat;
    case 'wg_ini':
      return _interfaceRange(t.split('\n')) != null
          ? MasqueradeWritability.writable
          : MasqueradeWritability.unsupportedFormat;
  }
  if (sourceKindOf(t) == 'amnezia_link') {
    return MasqueradeWritability.packedLink;
  }
  if (t.contains('\n')) return MasqueradeWritability.unsupportedFormat;
  final sep = t.indexOf('://');
  if (sep <= 0) return MasqueradeWritability.unsupportedFormat;
  final scheme = t.substring(0, sep).toLowerCase();
  if (scheme == 'vpn') return MasqueradeWritability.packedLink;
  if (!_kWgSchemes.contains(scheme)) {
    return MasqueradeWritability.unsupportedFormat;
  }
  var body = t.substring(sep + 3);
  final hash = body.indexOf('#');
  if (hash >= 0) body = body.substring(0, hash);
  if (!body.contains('@') && _kPackedBody.hasMatch(body)) {
    return MasqueradeWritability.packedLink;
  }
  return MasqueradeWritability.writable;
}

/// Есть ли в источнике [raw] хоть один ключ `ip`/`id`/`ib` (в любом
/// регистре у ссылки и INI). Нужен секции при явном `i1`: разбор такие ключи
/// снимает, и в модели их не видно.
bool masqueradeKeysPresent(String raw) {
  final t = raw.trim();
  switch (masqueradeWritability(t)) {
    case MasqueradeWritability.writable:
      break;
    default:
      return false;
  }
  switch (originKindOf(t)) {
    case 'json':
      final m = jsonDecode(t) as Map;
      return _kKeys.any(m.containsKey);
    case 'wg_ini':
      final lines = t.split('\n');
      final r = _interfaceRange(lines)!;
      for (var i = r.$1 + 1; i < r.$2; i++) {
        if (_isMasqueradeKeyLine(lines[i])) return true;
      }
      return false;
    default:
      final q = _splitLink(t).query;
      return q != null && q.split('&').any((p) => _masqueradeKeyOf(p) != null);
  }
}

/// Текст источника [raw] с ключами [m]: `null`-поле убирает ключ. Прочие
/// байты источника не трогаются (у JSON — переформатирование с отступом 2,
/// как у Save Source). Источник, в который писать нельзя
/// ([masqueradeWritability]), — [raw] без изменений.
String withMasquerade(String raw, Masquerade m) {
  if (masqueradeWritability(raw) != MasqueradeWritability.writable) {
    return raw;
  }
  final t = raw.trim();
  return switch (originKindOf(t)) {
    'json' => withBodyFields(t, {'ip': m.ip, 'id': m.id, 'ib': m.ib}),
    'wg_ini' => _withIni(raw, m),
    _ => _withLink(t, m),
  };
}

/// Ошибка домена для формы или `null`.
///
/// - `quic` без домена — обязателен (`requires` у `ip`, контракт 1.1.58),
///   кроме [emptyAllowed] (визард WARP подставляет случайный домен сам);
/// - домен не проходит шаблон реестра `id.pattern` или длиннее `id.max`.
MasqueradeDomainError? masqueradeDomainError(
  String ip,
  String domain, {
  bool emptyAllowed = false,
}) {
  final d = domain.trim();
  if (d.isEmpty) {
    return ip == 'quic' && !emptyAllowed
        ? MasqueradeDomainError.required
        : null;
  }
  if (ip == 'stun' || ip.isEmpty) return null; // поле скрыто, не пишется
  final field = ContractRegistry.I.schemaFor('wireguard')?.fields['id'];
  final pattern = field?.pattern ?? _kIdPatternFallback;
  final max = field?.max?.toInt() ?? 253;
  RegExp re;
  try {
    re = RegExp(pattern);
  } catch (_) {
    re = RegExp(_kIdPatternFallback);
  }
  if (utf8.encode(d).length > max || !re.hasMatch(d)) {
    return MasqueradeDomainError.invalid;
  }
  return null;
}

enum MasqueradeDomainError { required, invalid }

/// Шаблон `body/fields/id.pattern` на случай незагруженного реестра.
const _kIdPatternFallback =
    r'^[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?(?:\.[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?)*\.?$';

// --- INI ---

/// Канонические имена ключей в INI (ридер регистронезависим:
/// `ini_dialect.key_case: lower`).
const _kIniNames = {'ip': 'Ip', 'id': 'Id', 'ib': 'Ib'};

/// `[Interface]`: (индекс заголовка, индекс конца секции — следующий
/// заголовок или длина). `null` — секции нет.
(int, int)? _interfaceRange(List<String> lines) {
  int? start;
  for (var i = 0; i < lines.length; i++) {
    final s = lines[i].trim();
    if (!s.startsWith('[')) continue;
    if (start != null) return (start, i);
    if (s.toLowerCase() == '[interface]') start = i;
  }
  return start == null ? null : (start, lines.length);
}

bool _isComment(String line) {
  final s = line.trimLeft();
  return s.startsWith('#') || s.startsWith(';');
}

bool _isMasqueradeKeyLine(String line) {
  if (_isComment(line)) return false;
  final eq = line.indexOf('=');
  if (eq < 0) return false;
  return _kKeys.contains(line.substring(0, eq).trim().toLowerCase());
}

String _withIni(String raw, Masquerade m) {
  final crlf = raw.contains('\r\n');
  final lines = raw.split('\n');
  final r = _interfaceRange(lines);
  if (r == null) return raw;
  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    if (i > r.$1 && i < r.$2 && _isMasqueradeKeyLine(lines[i])) continue;
    out.add(lines[i]);
  }
  final end = r.$2 - (lines.length - out.length);
  // После последней строки-ключа секции: комментарий перед `[Peer]` остаётся
  // при `[Peer]` (у ссылки на конфиг из него берётся имя узла).
  var at = r.$1;
  for (var i = r.$1 + 1; i < end; i++) {
    if (out[i].trim().isNotEmpty && !_isComment(out[i])) at = i;
  }
  final eol = crlf ? '\r' : '';
  final add = [
    for (final k in _kKeys)
      if (_value(m, k) case final v?) '${_kIniNames[k]} = $v$eol',
  ];
  // Последняя строка файла без перевода строки: новые строки встают за ней,
  // у неё самой `\r` не было.
  if (add.isNotEmpty &&
      at == out.length - 1 &&
      crlf &&
      !out[at].endsWith('\r')) {
    out[at] = '${out[at]}\r';
    add[add.length - 1] = add.last.substring(0, add.last.length - 1);
  }
  out.insertAll(at + 1, add);
  return out.join('\n');
}

String? _value(Masquerade m, String k) => switch (k) {
  'ip' => m.ip,
  'id' => m.id,
  _ => m.ib,
};

// --- ссылка ---

/// Ссылка на части: до `?`, query (`null` — `?` нет), фрагмент с `#`.
({String head, String? query, String fragment}) _splitLink(String t) {
  final hash = t.indexOf('#');
  final main = hash < 0 ? t : t.substring(0, hash);
  final fragment = hash < 0 ? '' : t.substring(hash);
  final q = main.indexOf('?');
  return q < 0
      ? (head: main, query: null, fragment: fragment)
      : (
          head: main.substring(0, q),
          query: main.substring(q + 1),
          fragment: fragment,
        );
}

/// Имя ключа маскировки пары `k=v` в нижнем регистре или `null`.
String? _masqueradeKeyOf(String pair) {
  final eq = pair.indexOf('=');
  final k = (eq < 0 ? pair : pair.substring(0, eq)).toLowerCase();
  return _kKeys.contains(k) ? k : null;
}

/// Правка query на уровне строки: `Uri.queryParameters` и пересборка `Uri`
/// перекодируют прочие параметры и съедают сырой `+` (§421).
String _withLink(String t, Masquerade m) {
  final parts = _splitLink(t);
  final pairs = parts.query == null || parts.query!.isEmpty
      ? <String>[]
      : parts.query!.split('&');
  final written = <String>{};
  final out = <String>[];
  for (final p in pairs) {
    final k = _masqueradeKeyOf(p);
    if (k == null) {
      out.add(p);
      continue;
    }
    final v = _value(m, k);
    if (v == null || !written.add(k)) continue; // убрать / повтор
    out.add('$k=${Uri.encodeQueryComponent(v)}');
  }
  for (final k in _kKeys) {
    final v = _value(m, k);
    if (v != null && written.add(k)) {
      out.add('$k=${Uri.encodeQueryComponent(v)}');
    }
  }
  final query = out.isEmpty ? '' : '?${out.join('&')}';
  return '${parts.head}$query${parts.fragment}';
}
