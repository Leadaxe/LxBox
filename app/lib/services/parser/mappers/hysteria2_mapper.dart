/// §472 шаг 5 — маппер hysteria2: перевод диалекта ссылки в карту sing-box.
///
/// Словарь ссылки — `registry/protocols/hysteria2.json` → `uri`, общие части
/// — `tls.json`. Первая QUIC-схема на конвейере, и главное её отличие от
/// TCP-схем шагов 2–4 записано здесь же:
///
/// **Запрещённые блоки доезжают до судьи.** `tls.utls` и `tls.reality` на
/// QUIC ядро не строит вовсе (`qtls.Dial → STDConfig()` отвечает ошибкой), и
/// до этого шага их срезал ЭМИТТЕР (`TlsSpec.toSingboxForQuic`) — то есть
/// раньше санитайзера, который смотрел на `emit()`. Правило `forbidden_for`
/// реестра до блоков не доезжало, и код `tls_not_applicable_quic` ставил
/// рукописный проход (`forbiddenTlsBlockWarnings`, §469). На конвейере
/// санитайзер видит СЫРУЮ карту маппера: блоки в ней есть, правило реестра
/// снимает их само и само ставит код — по одному на блок, со значением по
/// CANON §6. Поэтому маппер кладёт `utls`/`reality` в карту ОБЫЧНЫМ порядком,
/// как это делают trojan и vless, и ничего о QUIC не знает.
///
/// Что маппер переводит (и не судит):
///
/// - **форма записи тела ссылки** — весь хвост после схемы может быть base64
///   (перекодированные подписки), алиас схемы `hy2://` равен `hysteria2://`;
/// - **multi-port в authority** — `host:443,20000-30000` не читается
///   `Uri.parse` вовсе (запятая и дефис в позиции порта), authority
///   восстанавливается на первом числовом порту, а список портов сливается с
///   `mport`/`ports` (правило `mport_range_spec`: дефис ссылки → двоеточие
///   ядра, одиночный порт → пара `N:N`);
/// - **userinfo = пароль ЦЕЛИКОМ**, вместе с двоеточиями: у hysteria2 нет
///   формы `user:pass`, и `p:1@host` значит пароль `p:1`. Пустой пароль узла
///   не роняет (в отличие от vless/trojan/tuic) — ключ просто не пишется;
/// - **раскладка obfs** — плоские параметры ссылки (`obfs`,
///   `obfs-password`, `obfs-min-packet-size`, `obfs-max-packet-size`)
///   становятся вложенным объектом тела. Годность типа, наличие пароля и
///   осмысленность размеров пакетов судит реестр;
/// - **оба написания полосы** — `upmbps` и `up_mbps` (§464, алиасы реестра);
/// - **эвристика SNI** — у hysteria2 она ЕСТЬ (`uri.query.sni.impl`: имя без
///   точки и двоеточия либо `🔒` уступает адресу сервера), в отличие от
///   trojan и vless, где её нет ни на одном входе.
library;

import 'dart:convert';

import '../../../models/node_warning.dart';
import '../uri_utils.dart';
import 'common_parts.dart';
import 'uri_mapper.dart';

const String _kPrefix = 'hysteria2://';
const String _kAliasPrefix = 'hy2://';

/// Порт по умолчанию — как у прочих share-URI.
const _kDefaultPort = 443;

/// `hysteria2://password@host:port?…#label` → сырая карта sing-box.
///
/// `null` — ссылки нет: без хоста записи не построить. Пустой userinfo узла НЕ
/// роняет (`uri.userinfo.impl`: «пустой/отсутствующий пароль не роняет ноду»,
/// в отличие от vless/trojan/ssh/tuic/anytls).
UriMapping? mapHysteria2Uri(String uri) {
  var normalized =
      uri.startsWith(_kAliasPrefix) ? _kPrefix + uri.substring(_kAliasPrefix.length) : uri;

  // `uri.userinfo.impl` — тело после схемы может быть целиком base64
  // (перекодированные подписки, иногда с хвостовым CRLF из копипаста).
  // Декодируем только если внутри нет `@`: сырой userinfo уже валиден и в
  // декоде не нуждается, а декодированный текст обязан `@` содержать, иначе
  // это не ссылка и мы остаёмся на исходной строке.
  if (normalized.startsWith(_kPrefix)) {
    final payload = normalized.substring(_kPrefix.length);
    if (!payload.contains('@')) {
      final bytes = decodeBase64Safe(payload);
      if (bytes != null) {
        try {
          final decoded = utf8.decode(bytes);
          if (decoded.contains('@')) normalized = _kPrefix + decoded;
        } catch (_) {
          // невалидный UTF-8 — остаёмся на исходной строке.
        }
      }
    }
  }

  // `mport_range_spec` — multi-port может стоять прямо в authority
  // (`host:443,20000-30000`), и `Uri.parse` такую строку не читает вовсе.
  // Восстанавливаем authority на первом числовом порту, остальное сливаем в
  // тот же конвейер, что и `?mport=`.
  String? authorityPortSpec;
  var p = Uri.tryParse(normalized);
  if ((p == null || p.host.isEmpty) && normalized.startsWith(_kPrefix)) {
    final recovered = _recoverMultiPortAuthority(normalized);
    if (recovered != null) {
      p = recovered.uri;
      authorityPortSpec = recovered.portSpec;
    }
  }
  if (p == null || p.host.isEmpty) return null;

  // Пароль — userinfo ЦЕЛИКОМ. Формы `user:pass` у hysteria2 нет: двоеточие
  // это часть пароля, а не разделитель (в отличие от tuic и vmess-cleartext).
  final password = Uri.decodeComponent(p.userInfo);

  final server = p.host;
  final port = p.hasPort ? p.port : _kDefaultPort;
  final q = Map<String, String>.from(p.queryParameters);
  final warnings = <NodeWarning>[];

  var mportSpec = (q['mport'] ?? q['ports'] ?? '').trim();
  if (authorityPortSpec != null && authorityPortSpec.isNotEmpty) {
    // Порядок слияния — authority, потом query (Go: node_parser_core.go).
    mportSpec =
        mportSpec.isEmpty ? authorityPortSpec : '$authorityPortSpec,$mportSpec';
  }
  final serverPorts = _mportSpecToServerPorts(mportSpec);

  final body = <String, dynamic>{
    'type': 'hysteria2',
    'server': server,
    'server_port': port,
    'server_ports': ?serverPorts,
    if (password.isNotEmpty) 'password': password,
  };

  // Раскладка obfs: плоские ключи ссылки → вложенный объект тела. Значения
  // идут КАК ПРИШЛИ — тип вне пары `salamander|gecko` снимет реестр с кодом
  // `obfs_unknown`, отсутствие пароля — с `obfs_password_missing`, а размеры
  // пакетов не у gecko — правилом `requires` с кодом `field_requires`.
  //
  // Пустой `obfs` блока не даёт вовсе: ключ, которого ссылка не просила, в
  // теле выглядел бы настройкой.
  final obfsType = (q['obfs'] ?? '').trim();
  if (obfsType.isNotEmpty) {
    final obfsPassword = q['obfs-password'] ?? '';
    final minSize = int.tryParse(q['obfs-min-packet-size'] ?? '');
    final maxSize = int.tryParse(q['obfs-max-packet-size'] ?? '');
    body['obfs'] = <String, dynamic>{
      'type': obfsType,
      if (obfsPassword.isNotEmpty) 'password': obfsPassword,
      'min_packet_size': ?minSize,
      'max_packet_size': ?maxSize,
    };
  }

  // §464 — на входе читаются ОБА написания (`upmbps` и `up_mbps`, алиасы
  // реестра). Канон ЭМИТА при этом один и не меняется (`upmbps`), иначе
  // round-trip разошёлся бы с лаунчером побайтно.
  final upMbps = int.tryParse(q['upmbps'] ?? q['up_mbps'] ?? '');
  final downMbps = int.tryParse(q['downmbps'] ?? q['down_mbps'] ?? '');
  body.addAll(<String, dynamic>{
    'up_mbps': ?upMbps,
    'down_mbps': ?downMbps,
  });

  final tls = tlsMapFromQuery(
    q,
    server,
    port,
    // `sni_heuristic_falls_back_to_server` — у hysteria2 эвристика ЕСТЬ на
    // обоих проектах (`uri.query.sni.impl`), в отличие от trojan и vless.
    sniHeuristic: true,
    sniAliases: const ['sni'],
    fpAliases: const ['fp', 'fingerprint'],
    // `pbk` ссылки строит блок REALITY ровно так же, как у vless: наличие
    // блока — вопрос структуры, годность ключа судит реестр. На QUIC блок
    // всё равно будет снят правилом `forbidden_for`, но снимет его СУДЬЯ, и
    // код назовёт то, что написал автор ссылки.
    reality: true,
    warnings: warnings,
  );
  // `tls` у hysteria2 `required: true`: ядро строит QUIC поверх TLS всегда, и
  // тело без блока санитайзер снял бы целиком. Ссылка без единого TLS-ключа
  // даёт блок с одним `server_name` — ровно то, что давал прежний парсер.
  body['tls'] = tls ?? <String, dynamic>{'enabled': true, 'server_name': server};

  // §103/D-078 — пиннинг сертификата: `pinSHA256=` → тело. На QUIC он
  // валиден (в отличие от utls/reality), и молча терять его нельзя: это
  // защита от подмены сертификата, а не косметика.
  final pin = (q['pinSHA256'] ?? q['pinsha256'] ?? '').trim();
  if (pin.isNotEmpty) {
    (body['tls'] as Map<String, dynamic>)['certificate_public_key_sha256'] =
        <String>[pin];
  }

  // §453 dial-полей здесь НЕТ намеренно: TCP keep-alive у QUIC-протокола
  // смысла не имеет (транспорт — UDP), `Hysteria2Spec` такого поля не знает
  // вовсе, и прежний парсер его не читал. Заведи мы его здесь, ключи легли бы
  // в тело, а модель молча их потеряла бы — ровно тот класс расхождения,
  // который этот шаг и вычищает.
  return UriMapping(
    body: body,
    label: decodeFragment(p.fragment),
    warnings: warnings,
  );
}

/// `mport_range_spec` — multi-port ссылки (`443,20000-30000`) в форму ядра
/// (`["443:443", "20000:30000"]`). Форма записи, а не суждение: негодные
/// значения уезжают в карту и судятся реестром.
List<String>? _mportSpecToServerPorts(String spec) {
  final s = spec.trim();
  if (s.isEmpty) return null;
  final out = <String>[];
  for (final part in s.split(',')) {
    final seg = part.trim();
    if (seg.isEmpty) continue;
    final ranged = seg.replaceAll('-', ':');
    out.add(ranged.contains(':') ? ranged : '$ranged:$ranged');
  }
  return out.isEmpty ? null : out;
}

/// Результат восстановления authority с multi-port спецификацией.
typedef _RecoveredAuthority = ({Uri uri, String portSpec});

/// `hysteria2://[user@]host:<portspec>[/path][?query][#frag]`, где
/// `<portspec>` — multi-port, непарсимый для `Uri.parse`. Восстанавливаем
/// authority на первом числовом порту (зеркало Go
/// `hysteria2RecoverMultiPortAuthority`) и возвращаем полный список портов
/// отдельно — вызывающий сольёт его с `mport`.
_RecoveredAuthority? _recoverMultiPortAuthority(String raw) {
  if (!raw.startsWith(_kPrefix)) return null;
  var rest = raw.substring(_kPrefix.length);

  String frag = '';
  final hashIdx = rest.indexOf('#');
  if (hashIdx >= 0) {
    frag = rest.substring(hashIdx);
    rest = rest.substring(0, hashIdx);
  }

  String query = '';
  final qIdx = rest.indexOf('?');
  if (qIdx >= 0) {
    query = rest.substring(qIdx);
    rest = rest.substring(0, qIdx);
  }

  String userinfo = '';
  String hostPath = rest;
  final atIdx = rest.indexOf('@');
  if (atIdx >= 0) {
    userinfo = rest.substring(0, atIdx);
    hostPath = rest.substring(atIdx + 1);
  }

  String hostPortPart = hostPath;
  String pathSuffix = '';
  final slashIdx = hostPath.indexOf('/');
  if (slashIdx >= 0) {
    hostPortPart = hostPath.substring(0, slashIdx);
    pathSuffix = hostPath.substring(slashIdx);
  }

  final split = _splitHostAndPort(hostPortPart);
  if (split == null || split.host.isEmpty) return null;
  final host = split.host;
  final portSpec = split.portSpec;
  if (!_authorityNeedsRecovery(portSpec)) return null;

  final firstPort = _firstNumericPortFromSpec(portSpec);
  if (firstPort == null) return null;

  final rebuilt = StringBuffer(_kPrefix);
  if (userinfo.isNotEmpty) rebuilt.write('$userinfo@');
  rebuilt
    ..write(host)
    ..write(':')
    ..write(firstPort)
    ..write(pathSuffix)
    ..write(query)
    ..write(frag);

  final u = Uri.tryParse(rebuilt.toString());
  if (u == null || u.host.isEmpty) return null;
  return (uri: u, portSpec: portSpec);
}

typedef _HostPort = ({String host, String portSpec});

/// Разбор `host[:portspec]` после `@`. IPv6-хост в скобках: portspec следует
/// за `]:`.
_HostPort? _splitHostAndPort(String hostPort) {
  final s = hostPort.trim();
  if (s.isEmpty) return null;
  if (s.startsWith('[')) {
    final close = s.indexOf(']');
    if (close < 0) return null;
    final host = s.substring(0, close + 1);
    if (close + 1 < s.length && s[close + 1] == ':') {
      return (host: host, portSpec: s.substring(close + 2));
    }
    return (host: host, portSpec: '');
  }
  final colon = s.lastIndexOf(':');
  if (colon < 0) return (host: s, portSpec: '');
  return (host: s.substring(0, colon), portSpec: s.substring(colon + 1));
}

/// Нужен ли recovery: portSpec несёт multi-port-синтаксис либо лишнее
/// двоеточие — зеркало Go `hysteria2AuthorityNeedsRecovery`.
bool _authorityNeedsRecovery(String portSpec) {
  final s = portSpec.trim();
  if (s.isEmpty) return false;
  return s.contains(',') || s.contains('-') || s.contains(':');
}

/// Первый числовой порт (1..65535) спецификации — им восстанавливается
/// authority. Зеркало Go `hysteria2FirstNumericPortFromSpec`.
int? _firstNumericPortFromSpec(String portSpec) {
  final s = portSpec.trim();
  if (s.isEmpty) return null;
  var seg = s.split(',').first.trim();
  if (seg.isEmpty) return null;
  for (final sep in ['-', ':']) {
    final i = seg.indexOf(sep);
    if (i > 0) {
      seg = seg.substring(0, i);
      break;
    }
  }
  seg = seg.trim();
  final p = int.tryParse(seg);
  if (p == null || p < 1 || p > 65535) return null;
  return p;
}
