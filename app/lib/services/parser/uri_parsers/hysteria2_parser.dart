import 'dart:convert';

import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
import '../../../models/tls_spec.dart';
import '../../contract/parse_warnings.dart';
import '../hysteria2_obfs.dart';
import '../transport.dart' show realityKeyShareFromQuery;
import '../uri_utils.dart';
import '../utls_fingerprint.dart';

// ════════════════════════════════════════════════════════════════════════════
// Hysteria2
// ════════════════════════════════════════════════════════════════════════════

const String _hysteria2Prefix = 'hysteria2://';

Hysteria2Spec? parseHysteria2(String uri) {
  var normalized = uri.startsWith('hy2://')
      ? uri.replaceFirst('hy2://', 'hysteria2://')
      : uri;

  // Go node_parser_core.go:227-242 — тело после схемы может быть целиком
  // base64 (перекодированные подписки, иногда с хвостовым CRLF/whitespace
  // из копипаста). Пробуем декод только если внутри нет '@' (сырой userinfo
  // уже валиден и не нуждается в декоде); декодированный текст должен
  // содержать '@', иначе остаёмся на исходной строке.
  if (normalized.startsWith(_hysteria2Prefix)) {
    final body = normalized.substring(_hysteria2Prefix.length);
    if (!body.contains('@')) {
      final bytes = decodeBase64Safe(body);
      if (bytes != null) {
        try {
          final decoded = utf8.decode(bytes);
          if (decoded.contains('@')) {
            normalized = _hysteria2Prefix + decoded;
          }
        } catch (_) {
          // невалидный UTF-8 — остаёмся на исходной строке.
        }
      }
    }
  }

  // §103 §9.B2 — multi-port может стоять прямо в authority
  // (host:443,20000-30000 / host:20000-30000), что net/url-подобный
  // Uri.parse в Dart не переваривает (','/'-' в позиции порта). Восстанавливаем
  // authority на первом числовом порту спецификации, остальное сливаем в
  // тот же mport-конвейер, что и query ?mport=/?ports= (Go: hysteria2_ports.go).
  String? authorityPortSpec;
  var p = Uri.tryParse(normalized);
  if ((p == null || p.host.isEmpty) && normalized.startsWith(_hysteria2Prefix)) {
    final recovered = _recoverMultiPortAuthority(normalized);
    if (recovered != null) {
      p = recovered.uri;
      authorityPortSpec = recovered.portSpec;
    }
  }
  if (p == null || p.host.isEmpty) return null;

  final password = Uri.decodeComponent(p.userInfo);
  // §103 §9.B2/empty_password_warn — Go: пустой/отсутствующий пароль не
  // роняет ноду (debuglog.WarnLog + пропуск ключа password), только vless/
  // trojan/ssh/tuic/anytls требуют непустой userinfo. Приводим к Go: нода
  // живёт, password просто не эмитится дальше по конвейеру, если пуст.

  final server = p.host;
  final port = p.hasPort ? p.port : 443;
  final q = Map<String, String>.from(p.queryParameters);
  final label = decodeFragment(p.fragment);
  final tag = tagFromLabel(label, 'hysteria2', server, port);

  // §103 §9.B2 — mport/ports (алиас) query + authority-восстановленный
  // список портов слиты (Go: node_parser_core.go:342-348 сначала authority,
  // потом query через запятую) → sing-box server_ports.
  var mportSpec = (q['mport'] ?? q['ports'] ?? '').trim();
  if (authorityPortSpec != null && authorityPortSpec.isNotEmpty) {
    mportSpec = mportSpec.isEmpty
        ? authorityPortSpec
        : '$authorityPortSpec,$mportSpec';
  }
  final serverPorts = _mportSpecToServerPorts(mportSpec);

  var sni = q['sni'] ?? '';
  if (sni.isEmpty || sni == '🔒' || (!sni.contains('.') && !sni.contains(':'))) {
    sni = server;
  }
  final fp = (q['fp'] ?? q['fingerprint'] ?? '').toLowerCase().trim();
  final alpn = (q['alpn'] ?? '').isEmpty
      ? const <String>[]
      : q['alpn']!.split(',').map((e) => e.trim()).toList();

  final warnings = <NodeWarning>[];
  // §103/D-078 — пиннинг сертификата: `pinSHA256=` → tls.
  // certificate_public_key_sha256 (паритет с лаунчером,
  // node_parser_hysteria2.go:120). Молча терять параметр = поднимать
  // соединение слабее, чем обещала подписка: пиннинг это защита от подмены
  // сертификата, а не косметика. На QUIC валиден (в отличие от utls/reality).
  final pin = (q['pinSHA256'] ?? q['pinsha256'] ?? '').trim();
  // §281 — fp вне словаря ядра = fatal всего конфига (hysteria2 идёт через
  // тот же tls.NewClient ядра); канонизируем на входе.
  final tls = normalizeTlsFingerprint(
    TlsSpec(
      enabled: true,
      serverName: sni,
      fingerprint: fp.isEmpty ? null : fp,
      insecure: isTlsInsecure(q),
      alpn: alpn,
      certificatePublicKeySha256: pin.isEmpty ? const [] : [pin],
    ),
    warnings,
  );

  if (tls.insecure) warnings.add(const InsecureTlsWarning());

  // §469 (контракт 1.1.4) — uTLS и REALITY поверх QUIC ядро не строит вовсе
  // (`STDConfig()` у обоих возвращает ошибку), и блоки срезаются на эмите
  // (`toSingboxForQuic`). Раньше срез был МОЛЧАЛИВЫМ: подписка выдала `fp=`,
  // параметр не действовал, и узел об этом не сообщал.
  //
  // Правило — из реестра (`tls.json` → `forbidden_for`/`forbidden_codes`), а
  // не список схем в Dart. Ставит его здесь парсер, а не санитайзер, ровно
  // потому, что до санитайзера блок не доезжает: он смотрит на `emit()`, где
  // среза уже нет (граница W2a, `parse_warnings.dart`).
  //
  // `pbk`/`sid` читаются ТОЛЬКО ради кода и в модель не кладутся: REALITY на
  // hysteria2 неприменим, а в `TlsSpec` он потянул бы за собой равенство,
  // identity-хеш и правила `normalizeTlsFingerprint` (там REALITY заводит
  // свои коды — `reality_fp_not_chrome` на узле, где REALITY не работает).
  //
  // Неопознанный отпечаток печатается КАК ПРИШЁЛ: `tls.fingerprint` к этому
  // месту уже подменён на `chrome` (§281), а `value` кода — «исходное
  // значение до деградации» (CANON §6). Сама подмена объявлена своим кодом
  // `utls_fp_unknown` выше.
  warnings.addAll(forbiddenTlsBlockWarnings('hysteria2', {
    ...utlsBlockOf(
        normalizeUtlsFingerprintValue(fp).junk ? fp : tls.fingerprint),
    ...?_realityBlockOf(q),
  }));

  // §358 — тип вне enum ядра или obfs без пароля = fatal всего конфига;
  // нормализуем здесь, чтобы в спеку попало только принимаемое ядром.
  final obfs = normalizeHysteria2Obfs(
    q['obfs'] ?? '',
    q['obfs-password'] ?? '',
    warnings,
  );

  // §084 H3 / SPEC 103 — bandwidth hint'ы для round-trip с toUriHysteria2.
  //
  // §464 (контракт W2d, DRIFT §2(l)) — НА ВХОДЕ ЧИТАЮТСЯ ОБА НАПИСАНИЯ.
  // Раньше здесь был канон «только `upmbps`, без подчёркивания»: Go читал
  // ровно его. В W2d лаунчер завёл `up_mbps`/`down_mbps` алиасами реестра
  // (`hysteria2.json uri.query.upmbps.aliases`) и стал принимать оба — а
  // подписки пишут и то, и другое написание. Ссылка с `up_mbps=` теряла
  // полосу молча.
  //
  // ЭМИТ не меняется (`node_spec_emit.dart` пишет `upmbps`): канон share-URI
  // один, иначе round-trip перестал бы совпадать побайтно с лаунчером.
  final upMbps = int.tryParse(q['upmbps'] ?? q['up_mbps'] ?? '');
  final downMbps = int.tryParse(q['downmbps'] ?? q['down_mbps'] ?? '');

  // §464 (контракт W2d) — размеры пакетов осмыслены ТОЛЬКО у gecko
  // (реестр `hysteria2.json`: `requires` с `equals: gecko`). Эмиттер и
  // раньше не писал их для salamander, но делал это молча — тот же узел,
  // пришедший телом, санитайзер чистил с кодом. Теперь код на обоих входах.
  var obfsMin = int.tryParse(q['obfs-min-packet-size'] ?? '');
  var obfsMax = int.tryParse(q['obfs-max-packet-size'] ?? '');
  if (obfs.type != 'gecko') {
    if (obfsMin != null) {
      warnings.add(const RegistryWarning(
        code: 'field_requires',
        path: 'obfs.min_packet_size',
        params: {'requires': 'obfs.type'},
      ));
      obfsMin = null;
    }
    if (obfsMax != null) {
      warnings.add(const RegistryWarning(
        code: 'field_requires',
        path: 'obfs.max_packet_size',
        params: {'requires': 'obfs.type'},
      ));
      obfsMax = null;
    }
  }

  return Hysteria2Spec(
    id: newUuidV4(),
    tag: tag,
    label: label,
    server: server,
    port: port,
    rawSource: uri,
    password: password,
    obfs: obfs.type,
    obfsPassword: obfs.password,
    obfsMinPacketSize: obfsMin,
    obfsMaxPacketSize: obfsMax,
    tls: tls,
    upMbps: upMbps,
    downMbps: downMbps,
    serverPorts: serverPorts,
    warnings: warnings,
  );
}

/// §103 §9.B2 — hysteria2 multi-port spec (comma-separated ports/ranges,
/// hyphen for ranges) → sing-box `server_ports` (`"low:high"`, одиночный
/// порт → `"N:N"`). Порт Go: hysteria2_ports.go
/// hysteria2MportSpecToSingBoxServerPorts.
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

/// §103 §9.B2 — `hysteria2://[user@]host:<portspec>[/path][?query][#frag]`,
/// где `<portspec>` — Hysteria2 multi-port (список портов и диапазонов
/// через запятую, диапазон через дефис: `443,20000-30000`), непарсимый для
/// `Uri.parse` (запятая/дефис в позиции порта). Восстанавливаем authority на
/// первом числовом порту спецификации — как net/url-обёртка Go
/// (hysteria2_ports.go: hysteria2RecoverMultiPortAuthority) — и возвращаем
/// полный список портов отдельно для слияния с mport (см. вызывающий код).
_RecoveredAuthority? _recoverMultiPortAuthority(String raw) {
  if (!raw.startsWith(_hysteria2Prefix)) return null;
  var rest = raw.substring(_hysteria2Prefix.length);

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

  final rebuilt = StringBuffer(_hysteria2Prefix);
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

/// Разбор `host[:portspec]` после `@` (или после схемы, если userinfo нет).
/// IPv6-хост в скобках: portspec следует за `]:`.
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

/// Нужен ли recovery: portSpec содержит multi-port-синтаксис (','/'-'), либо
/// лишнее двоеточие (IPv6-подобный мусор) — зеркало Go
/// hysteria2AuthorityNeedsRecovery.
bool _authorityNeedsRecovery(String portSpec) {
  final s = portSpec.trim();
  if (s.isEmpty) return false;
  return s.contains(',') || s.contains('-') || s.contains(':');
}

/// Первый числовой порт (1..65535) в multi-port спецификации — используется
/// для восстановления authority. Зеркало Go
/// hysteria2FirstNumericPortFromSpec.
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

/// §469 — блок `tls.reality` из `pbk`/`sid` ссылки, в форме sing-box; `null`
/// — REALITY в ссылке нет либо ключ негоден.
///
/// Нужен ТОЛЬКО для `value` предупреждения `tls_not_applicable_quic`: на
/// hysteria2 REALITY неприменим, в модель и в тело узла он не попадает.
/// Требование к ключу то же, что у vless (§169, [isValidRealityPublicKey]):
/// на мусорном `pbk=true` подписка REALITY не просила, и кода такой узел не
/// заслуживает.
Map<String, Map<String, dynamic>>? _realityBlockOf(Map<String, String> q) {
  final pbk = (q['pbk'] ?? '').trim();
  if (!isValidRealityPublicKey(pbk)) return null;
  return {
    'reality': RealitySpec(
      publicKey: pbk,
      shortId: normalizeRealityShortId(q['sid'] ?? ''),
      keyShare: realityKeyShareFromQuery((q['key_share'] ?? '').trim()),
    ).toSingbox(),
  };
}
