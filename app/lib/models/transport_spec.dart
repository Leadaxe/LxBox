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

  /// §103 D-008 / IDENTITY.md §3 — true, когда [earlyDataHeaderName] не был
  /// задан явно (ни `eh=`, ни JSON-поле), а подставлен нами на эмите как
  /// дефолт v2ray-конвенции для голого `?ed=N` хвоста пути (см.
  /// parseTransport). Нужен, чтобы `toUri()`/round-trip не начал сериализовать
  /// подставленное значение как явное — Go тоже никогда не пишет `eh=` в
  /// share-URI обратно (shareuri_helpers.go).
  final bool earlyDataHeaderImplicit;

  const WsTransport({
    this.path = '',
    this.host = '',
    this.headers = const {},
    this.maxEarlyData,
    this.earlyDataHeaderName,
    this.earlyDataHeaderImplicit = false,
  });

  @override
  (Map<String, dynamic>, List<NodeWarning>) toSingbox(TemplateVars vars) {
    // §103 D-016(в) — пустая строка = путь не задан явно (ни в URI, ни в
    // JSON) → ключ не пишем (option/v2ray_transport.go omitempty). ВАЖНО:
    // явный `path=/` (buyer URI ставит его руками) отличается от отсутствия
    // параметра — Go пишет `path:"/"`, когда параметр БЫЛ в query, поэтому
    // здесь смотрим только на пустоту строки, не на "== '/'" (парсер отвечает
    // за то, чтобы отсутствующий параметр давал '' , а не '/').
    final m = <String, dynamic>{
      'type': 'ws',
      if (path.isNotEmpty) 'path': path,
    };
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
  const HttpUpgradeTransport({this.path = '', this.host = ''});

  @override
  (Map<String, dynamic>, List<NodeWarning>) toSingbox(TemplateVars vars) {
    // §103 D-016(в) — тот же принцип, что и у ws: пустая строка = параметра
    // не было в источнике, явный `path=/` эмитится как есть.
    final m = <String, dynamic>{
      'type': 'httpupgrade',
      if (path.isNotEmpty) 'path': path,
    };
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
/// Расширенные поля плоские (String/bool/int) с omitempty-семантикой: пустое
/// значение → ключ не эмитим, у ядра свои дефолты (см. URL_PARSING §2).
///
/// Единственный вложенный объект, который XHTTP определяет, — `xmux`: его
/// члены живут здесь плоскими полями и собираются в под-объект только на
/// эмиссии, ровно как в Go (`xhttpXmuxFromSource`). Других под-объектов в
/// transport нет.
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
  final String scStreamUpServerSecs;

  // Паритет с Go: ядро декодирует это поле как int, а не как строку
  // (xhttpIntFields, node_parser_transport.go). -1 = не задано.
  final int scMaxBufferedPosts;

  // Паритет с Go: no_sse_header рядом с no_grpc_header (xhttpBoolFields).
  final bool noSseHeader;

  // xmux — плоские поля здесь, под-объект на эмиссии (xhttpXmuxFields).
  // h_keep_alive_period ядро декодирует как int; -1 = не задано.
  final String maxConnections;
  final String maxConcurrency;
  final String cMaxReuseTimes;
  final String hMaxRequestTimes;
  final String hMaxReusableSecs;
  final int hKeepAlivePeriod;

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
    this.scStreamUpServerSecs = '',
    this.scMaxBufferedPosts = -1,
    this.noSseHeader = false,
    this.maxConnections = '',
    this.maxConcurrency = '',
    this.cMaxReuseTimes = '',
    this.hMaxRequestTimes = '',
    this.hMaxReusableSecs = '',
    this.hKeepAlivePeriod = -1,
  });

  @override
  (Map<String, dynamic>, List<NodeWarning>) toSingbox(TemplateVars vars) {
    // SPEC 103 CANON §2.4 — дефолтные поля не пишутся: path='/' в конструкторе
    // ([XhttpTransport.new]) — дефолт для UI/редактора, а не для эмиссии;
    // Go эмитит path только когда он явно задан в источнике (в т.ч. path=%2F
    // → "/"), пустой (не заданный) — опускает целиком.
    final m = <String, dynamic>{'type': 'xhttp'};
    if (path.isNotEmpty) m['path'] = path;
    final warnings = <NodeWarning>[];
    if (host.isNotEmpty) m['host'] = host;
    if (mode.isNotEmpty) m['mode'] = mode;
    if (xPaddingBytes.isNotEmpty) m['x_padding_bytes'] = xPaddingBytes;
    if (noGrpcHeader) m['no_grpc_header'] = true;
    if (noSseHeader) m['no_sse_header'] = true;
    if (headers.isNotEmpty) m['headers'] = Map<String, String>.from(headers);

    // §217 — нормализация против правил ядра normalizeMeta (transport/v2rayxhttp/
    // meta.go) остаётся для x_padding_placement/x_padding_method/seq_placement
    // (не покрыты corpus-кейсами, поведение Go для них ещё не сверено).
    // session_placement/uplink_data_placement/uplink_http_method ниже —
    // pure passthrough (см. комментарии на местах, "go": null в
    // registry/warnings.json xhttp_param_reset).

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

    // SPEC 103 vless/xhttp_placement_bogus_reset — session_placement, ровно
    // как uplink_data_placement/uplink_http_method ниже, идёт напрямую без
    // enum-гейта: registry/warnings.json xhttp_param_reset документирует
    // "go": null — Go пока не нормализует XHTTP-параметры вовсе
    // (xhttpBuildTransport: "normalization is left to the core", SPEC 102 в
    // работе). Канон = поведение Go (pass-through, core сам роняет мусор).
    if (sessionPlacement.isNotEmpty) m['session_placement'] = sessionPlacement;
    if (sessionKey.isNotEmpty) m['session_key'] = sessionKey;
    putEnum('seq_placement', seqPlacement,
        const {'path', 'query', 'header', 'cookie'});
    if (seqKey.isNotEmpty) m['seq_key'] = seqKey;

    // §416 — единственная точка, где uplink_data_placement уходит в конфиг:
    // сюда сходятся ВСЕ ветки источника (URI, sing-box JSON, Xray JSON,
    // ручной редактор), обойти guard нельзя.
    //
    // Ядро (transport/v2rayxhttp/meta.go normalizeMeta) отвергает
    // `header`-placement вне packet-up с fatal на ВЕСЬ конфиг:
    //   create client transport: xhttp: v2ray-xhttp:
    //   uplink_data_placement can be header only in packet-up mode
    // Один узел подписки в такой форме не даёт подняться VPN вовсе.
    //
    // Две разные ситуации, две разные реакции:
    //  * mode не задан — намерения пользователя нет, `header` сам по себе
    //    его и выражает (осмысленен только в packet-up). Дописываем
    //    mode: packet-up — узел собирается ровно так, как ждёт сервер.
    //  * mode задан и это не packet-up — конфликт явный, оба значения
    //    осмысленны и противоречат друг другу. По §169 «отбрасывать, а не
    //    подгонять молча»: чужой явный mode не переписываем (это сменило бы
    //    wire-протокол узла), снимаем placement — ядро возьмёт свой дефолт.
    // Обе ветки — с предупреждением: поведение изменено, пользователь видит.
    if (uplinkDataPlacement.isNotEmpty) {
      final placement = uplinkDataPlacement.trim().toLowerCase();
      final effectiveMode = mode.trim().toLowerCase();
      final needsPacketUp = placement == 'header';
      if (needsPacketUp && effectiveMode.isEmpty) {
        m['mode'] = 'packet-up';
        m['uplink_data_placement'] = uplinkDataPlacement;
        warnings.add(const XhttpModeForcedPacketUpWarning());
      } else if (needsPacketUp && effectiveMode != 'packet-up') {
        warnings.add(XhttpParamResetWarning('uplink_data_placement',
            XhttpResetReason.placementRequiresPacketUp));
      } else {
        m['uplink_data_placement'] = uplinkDataPlacement;
      }
    }
    if (uplinkDataKey.isNotEmpty) m['uplink_data_key'] = uplinkDataKey;
    if (uplinkChunkSize.isNotEmpty) m['uplink_chunk_size'] = uplinkChunkSize;

    // SPEC 103 vless/xhttp_uplink_get_without_packet_up_reset — GET вне
    // packet-up тоже pure passthrough в Go (meta.go:105 валидирует на
    // стороне ядра, не парсера); xhttp_uplink_get_packet_up_kept уже
    // проверяет keep-путь.
    if (uplinkHttpMethod.isNotEmpty) {
      m['uplink_http_method'] = uplinkHttpMethod;
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
    if (scStreamUpServerSecs.isNotEmpty) {
      m['sc_stream_up_server_secs'] = scStreamUpServerSecs;
    }
    // int-поля: 0 — значащее значение, «не задано» кодируется как -1.
    if (scMaxBufferedPosts >= 0) m['sc_max_buffered_posts'] = scMaxBufferedPosts;

    // xmux собирается под-объектом и эмитится только непустым — пустой
    // {"xmux":{}} ядро прочло бы как заданный, но нулевой конфиг.
    final xmux = <String, dynamic>{};
    if (maxConcurrency.isNotEmpty) xmux['max_concurrency'] = maxConcurrency;
    if (maxConnections.isNotEmpty) xmux['max_connections'] = maxConnections;
    if (cMaxReuseTimes.isNotEmpty) xmux['c_max_reuse_times'] = cMaxReuseTimes;
    if (hMaxRequestTimes.isNotEmpty) {
      xmux['h_max_request_times'] = hMaxRequestTimes;
    }
    if (hMaxReusableSecs.isNotEmpty) {
      xmux['h_max_reusable_secs'] = hMaxReusableSecs;
    }
    if (hKeepAlivePeriod >= 0) xmux['h_keep_alive_period'] = hKeepAlivePeriod;
    if (xmux.isNotEmpty) m['xmux'] = xmux;

    return (m, warnings);
  }
}
