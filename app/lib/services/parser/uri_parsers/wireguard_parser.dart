import '../../../models/node_spec.dart';
import '../ini_parser.dart';
import '../mappers/uri_pipeline.dart';
import '../uri_utils.dart';

// ════════════════════════════════════════════════════════════════════════════
// WireGuard (URI form)
// ════════════════════════════════════════════════════════════════════════════

WireguardSpec? parseWireguardUri(String uri) {
  // §450 — вторая форма: после схемы не `key@host:port?…`, а base64 целого
  // wg-quick (панели с AmneziaWG 3.1). Штатный разбор видел бы в base64
  // «хост» без ключа и ронял узел молча. Форма опознаётся ДО конвейера: её
  // payload это .conf, а не URI, и переводит его тот же [parseWireguardIni].
  final fromConf = _parseWgConfBase64Link(uri);
  if (fromConf != null) return fromConf;

  return parseUriViaPipeline(uri, 'wireguard') as WireguardSpec?;
}


// ════════════════════════════════════════════════════════════════════════════
// §450 — awg://<base64 .conf>#label (вторая форма share-link)
// ════════════════════════════════════════════════════════════════════════════

/// Разбор ссылки, в которой после схемы лежит base64 целого wg-quick
/// (`[Interface]`…`[Peer]`), а не `key@host:port?…`. Эталон Go
/// `parseWGConfBase64Link` (контракт §20.1):
///
/// 1. payload — между `://` и `#`; признак формы — в нём нет ни `@`, ни `:`,
///    ни `?` (base64 этих символов не содержит, а `key@host:port?…` несёт);
/// 2. декодирование — те же 4 варианта base64, что везде ([decodeBase64Safe]);
/// 3. текст обязан содержать `[Interface]`, иначе форма не наша — вызывающий
///    идёт штатным путём и отдаёт штатную ошибку;
/// 4. конвертация — ТЕМ ЖЕ [parseWireguardIni], что вставленный `.conf`:
///    валидация ключей, MTU-клэмп и AWG2/3-поля остаются одной точкой;
/// 5. метка = фрагмент; без фрагмента — хост Endpoint (как `ConvertWGConfText`
///    в Go), а не общий фолбэк `WireGuard`.
///
/// `null` = форма не распознана (не ошибка): вызывающий продолжает обычный
/// разбор URI.
WireguardSpec? _parseWgConfBase64Link(String uri) {
  final sep = uri.indexOf('://');
  if (sep < 0) return null;
  var payload = uri.substring(sep + 3);
  var fragment = '';
  final hash = payload.indexOf('#');
  if (hash >= 0) {
    fragment = payload.substring(hash + 1);
    payload = payload.substring(0, hash);
  }
  payload = payload.trim();
  // Форма `key@host:port?…` — не наш случай.
  if (payload.isEmpty || payload.contains(RegExp(r'[@:?]'))) return null;

  final raw = decodeBase64Safe(payload);
  if (raw == null) return null;
  final text = utf8Lossy(raw);
  // Не .conf — пусть падает штатно (parse_error), а не превращается в узел.
  if (!text.contains('[Interface]')) return null;

  // Один share-link = один узел: берём первый [Interface]-блок.
  final conf = _firstWgConfBlock(text);
  if (conf == null) return null;

  final label = decodeFragment(fragment);
  final hint = label.isNotEmpty ? label : _wgEndpointHost(conf);
  final spec = parseWireguardIni(conf, nameHint: hint);
  if (spec == null) return null;
  // Источник узла (вкладка Source, identity-хеш) — исходная ссылка, а не
  // INI-текст из неё: узел пришёл ссылкой, а не вставленным файлом.
  return WireguardSpec(
    id: spec.id,
    tag: spec.tag,
    label: spec.label,
    server: spec.server,
    port: spec.port,
    rawSource: uri,
    privateKey: spec.privateKey,
    localAddresses: spec.localAddresses,
    peers: spec.peers,
    mtu: spec.mtu,
    awg: spec.awg,
    warnings: spec.warnings,
  );
}

/// Первый `[Interface]`-блок текста: от первого `[Interface]` до следующего
/// (второй профиль в том же payload игнорируем — контракт §20.1).
String? _firstWgConfBlock(String text) {
  final start = text.indexOf('[Interface]');
  if (start < 0) return null;
  final next = text.indexOf('[Interface]', start + '[Interface]'.length);
  final block = next < 0 ? text.substring(start) : text.substring(start, next);
  return block.trim().isEmpty ? null : block;
}

/// Хост из `[Peer].Endpoint` — метка узла, когда фрагмента нет (эталон Go
/// `wgEndpointHost`). Голый IPv6 в `[…]` разворачивается; порт снимается
/// только при однозначном `host:port`.
String _wgEndpointHost(String conf) {
  for (final line in conf.split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    final idx = t.indexOf('=');
    if (idx < 0) continue;
    if (t.substring(0, idx).trim().toLowerCase() != 'endpoint') continue;
    final v = t.substring(idx + 1).trim();
    if (v.isEmpty) return '';
    if (v.startsWith('[')) {
      final close = v.indexOf(']');
      return close > 0 ? v.substring(1, close) : v;
    }
    final lastColon = v.lastIndexOf(':');
    // Несколько ':' без скобок — голый IPv6, порт неотличим (§219).
    if (lastColon > 0 && v.indexOf(':') == lastColon) {
      return v.substring(0, lastColon);
    }
    return v;
  }
  return '';
}
