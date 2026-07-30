import 'node_warning.dart';
import 'template_vars.dart';

/// Sealed-иерархия транспортов. XHTTP — вариант sealed'а, компилятор не даст
/// забыть fallback (§2.3 спеки 026). `toSingbox` возвращает `(map, warnings)`
/// — warnings добавляются caller'ом в `NodeSpec.warnings`.
sealed class TransportSpec {
  const TransportSpec();

  (Map<String, dynamic> map, List<NodeWarning> warnings) toSingbox(
      TemplateVars vars);
}

final class WsTransport extends TransportSpec {
  final String path;
  final String host;
  final Map<String, String> headers;

  /// §303 — WebSocket early data. Xray задаёт его хвостом пути (`/x?ed=2560`),
  /// у sing-box это отдельное поле `max_early_data` (option/v2ray_transport.go).
  /// Пустой [earlyDataHeaderName] = early data уходит в путь (режим Xray `ed`);
  /// заданный — в одноимённый HTTP-заголовок.
  final int? maxEarlyData;
  final String? earlyDataHeaderName;

  const WsTransport({
    this.path = '/',
    this.host = '',
    this.headers = const {},
    this.maxEarlyData,
    this.earlyDataHeaderName,
  });

  @override
  (Map<String, dynamic>, List<NodeWarning>) toSingbox(TemplateVars vars) {
    final m = <String, dynamic>{'type': 'ws', 'path': path};
    if (host.isNotEmpty) {
      m['headers'] = {'Host': host, ...headers};
    } else if (headers.isNotEmpty) {
      m['headers'] = Map<String, String>.from(headers);
    }
    if (maxEarlyData != null) {
      m['max_early_data'] = maxEarlyData;
    }
    if (earlyDataHeaderName != null) {
      m['early_data_header_name'] = earlyDataHeaderName;
    }
    return (m, const []);
  }
}

final class GrpcTransport extends TransportSpec {
  final String serviceName;
  const GrpcTransport({required this.serviceName});

  @override
  (Map<String, dynamic>, List<NodeWarning>) toSingbox(TemplateVars vars) => (
        {'type': 'grpc', 'service_name': serviceName},
        const [],
      );
}

final class HttpTransport extends TransportSpec {
  final String path;
  final List<String> hosts;
  final Map<String, String> headers;

  const HttpTransport({
    this.path = '/',
    this.hosts = const [],
    this.headers = const {},
  });

  @override
  (Map<String, dynamic>, List<NodeWarning>) toSingbox(TemplateVars vars) {
    final m = <String, dynamic>{'type': 'http', 'path': path};
    if (hosts.isNotEmpty) m['host'] = List<String>.from(hosts);
    if (headers.isNotEmpty) m['headers'] = Map<String, String>.from(headers);
    return (m, const []);
  }
}

final class HttpUpgradeTransport extends TransportSpec {
  final String path;
  final String host;
  const HttpUpgradeTransport({this.path = '/', this.host = ''});

  @override
  (Map<String, dynamic>, List<NodeWarning>) toSingbox(TemplateVars vars) {
    final m = <String, dynamic>{'type': 'httpupgrade', 'path': path};
    if (host.isNotEmpty) m['host'] = host;
    return (m, const []);
  }
}

/// §097 / §127 — XHTTP (Xray-совместимый `splithttp`). Форк `sing-box-lx`
/// (`with_xhttp`) умеет нативный `type: "xhttp"`: режимы
/// `auto|packet-up|stream-up|stream-one`, `x_padding_bytes`-обфускация,
/// `no_grpc_header`, extra-headers. §127 расширил до полной клиентской
/// поддержки SPEC 002 v2 — настраиваемые placement'ы session/seq/uplink,
/// ключи, метод upload, X-Padding obfs-режим и packet-up tuning. Раньше
/// деградировал в httpupgrade (стоковое ядро без xhttp) — теперь **нативный**
/// emit, без подмены wire-протокола.
///
/// Все расширенные поля плоские (String/bool) с omitempty-семантикой: пустое
/// значение → ключ не эмитим, у ядра свои дефолты (см. URL_PARSING §2). НЕ
/// вкладывать под-объекты — Go-конфиг тоже плоский в пределах transport.
///
/// NB: на СТОКОВОМ ядре (CI без `with_xhttp`) конфиг с `type=xhttp` отвергается
/// на load — фича «спит» до релиза fork-ядра (как AWG, §097).
final class XhttpTransport extends TransportSpec {
  // v1 (§097)
  final String path;
  final String host;
  final String mode; // '' = ядро решает (auto)
  final String xPaddingBytes; // '' = none, напр. '100-1000'
  final bool noGrpcHeader;
  final Map<String, String> headers;

  // §127 — session / seq placement
  final String sessionPlacement; // path|query|header|cookie (дефолт path)
  final String sessionKey;
  final String seqPlacement; // path|query|header|cookie (дефолт path)
  final String seqKey;

  // §127 — uplink data
  final String uplinkDataPlacement; // body|auto|header|cookie (дефолт auto)
  final String uplinkDataKey;
  final String uplinkChunkSize; // '"min-max"'
  final String uplinkHttpMethod; // дефолт POST

  // §127 — X-Padding obfs
  final bool xPaddingObfsMode; // дефолт false
  final String xPaddingKey;
  final String xPaddingHeader;
  final String xPaddingPlacement; // cookie|header|query|queryInHeader
  final String xPaddingMethod; // repeat-x|tokenish

  // §127 — packet-up tuning (строка '"N"' или '"N-N"')
  final String scMaxEachPostBytes;
  final String scMinPostsIntervalMs;

  const XhttpTransport({
    this.path = '/',
    this.host = '',
    this.mode = '',
    this.xPaddingBytes = '',
    this.noGrpcHeader = false,
    this.headers = const {},
    this.sessionPlacement = '',
    this.sessionKey = '',
    this.seqPlacement = '',
    this.seqKey = '',
    this.uplinkDataPlacement = '',
    this.uplinkDataKey = '',
    this.uplinkChunkSize = '',
    this.uplinkHttpMethod = '',
    this.xPaddingObfsMode = false,
    this.xPaddingKey = '',
    this.xPaddingHeader = '',
    this.xPaddingPlacement = '',
    this.xPaddingMethod = '',
    this.scMaxEachPostBytes = '',
    this.scMinPostsIntervalMs = '',
  });

  @override
  (Map<String, dynamic>, List<NodeWarning>) toSingbox(TemplateVars vars) {
    final m = <String, dynamic>{'type': 'xhttp', 'path': path};
    final warnings = <NodeWarning>[];
    if (host.isNotEmpty) m['host'] = host;
    if (mode.isNotEmpty) m['mode'] = mode;
    if (xPaddingBytes.isNotEmpty) m['x_padding_bytes'] = xPaddingBytes;
    if (noGrpcHeader) m['no_grpc_header'] = true;
    if (headers.isNotEmpty) m['headers'] = Map<String, String>.from(headers);

    // §217 — нормализация против правил ядра normalizeMeta (transport/v2rayxhttp/
    // meta.go). Комбинации, которые ядро отвергает fatal, чиним на дефолт —
    // иначе одна битая xhttp-нода роняет ВЕСЬ конфиг на старте. Каждый сброс →
    // NodeWarning (⚠️ в подписке + строка в AppLog). mode дефолтится ядром
    // "" → auto (client.go:79), поэтому packet-up только при явном значении.
    final isPacketUp = mode.toLowerCase() == 'packet-up';

    // --- placement/method enums: значение вне множества ядро роняет fatal ---
    void putEnum(String key, String value, Set<String> allowed) {
      if (value.isEmpty) return;
      if (allowed.contains(value)) {
        m[key] = value;
      } else {
        warnings.add(XhttpParamResetWarning(
            key, XhttpResetReason.invalidEnumValue, value: value));
      }
    }

    putEnum('session_placement', sessionPlacement,
        const {'path', 'query', 'header', 'cookie'});
    if (sessionKey.isNotEmpty) m['session_key'] = sessionKey;
    putEnum('seq_placement', seqPlacement,
        const {'path', 'query', 'header', 'cookie'});
    if (seqKey.isNotEmpty) m['seq_key'] = seqKey;

    // --- uplink_data_placement: enum + header/cookie только в packet-up ---
    final up = uplinkDataPlacement.toLowerCase();
    if (uplinkDataPlacement.isNotEmpty) {
      if (!const {'body', 'auto', 'header', 'cookie'}
          .contains(uplinkDataPlacement)) {
        warnings.add(XhttpParamResetWarning('uplink_data_placement',
            XhttpResetReason.invalidPlacementValue,
            value: uplinkDataPlacement));
      } else if ((up == 'header' || up == 'cookie') && !isPacketUp) {
        warnings.add(const XhttpParamResetWarning('uplink_data_placement',
            XhttpResetReason.placementRequiresPacketUp));
      } else {
        m['uplink_data_placement'] = uplinkDataPlacement;
      }
    }
    if (uplinkDataKey.isNotEmpty) m['uplink_data_key'] = uplinkDataKey;
    if (uplinkChunkSize.isNotEmpty) m['uplink_chunk_size'] = uplinkChunkSize;

    // --- uplink_http_method: GET валиден только в packet-up (meta.go:105) ---
    if (uplinkHttpMethod.isNotEmpty) {
      if (uplinkHttpMethod.toUpperCase() == 'GET' && !isPacketUp) {
        warnings.add(const XhttpParamResetWarning(
            'uplink_http_method', XhttpResetReason.getRequiresPacketUp));
      } else {
        m['uplink_http_method'] = uplinkHttpMethod;
      }
    }

    if (xPaddingObfsMode) m['x_padding_obfs_mode'] = true;
    if (xPaddingKey.isNotEmpty) m['x_padding_key'] = xPaddingKey;
    if (xPaddingHeader.isNotEmpty) m['x_padding_header'] = xPaddingHeader;
    putEnum('x_padding_placement', xPaddingPlacement,
        const {'cookie', 'header', 'query', 'queryInHeader'});
    putEnum('x_padding_method', xPaddingMethod,
        const {'repeat-x', 'tokenish'});
    if (scMaxEachPostBytes.isNotEmpty) {
      m['sc_max_each_post_bytes'] = scMaxEachPostBytes;
    }
    if (scMinPostsIntervalMs.isNotEmpty) {
      m['sc_min_posts_interval_ms'] = scMinPostsIntervalMs;
    }
    return (m, warnings);
  }
}
