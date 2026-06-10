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
  final int? earlyDataHeaderMaxLen;
  final String? earlyDataHeaderName;

  const WsTransport({
    this.path = '/',
    this.host = '',
    this.headers = const {},
    this.earlyDataHeaderMaxLen,
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
    if (earlyDataHeaderMaxLen != null) {
      m['early_data_header_max_len'] = earlyDataHeaderMaxLen;
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

/// §097 — XHTTP (Xray-совместимый `splithttp`). Форк `sing-box-lx` (`with_xhttp`)
/// умеет нативный `type: "xhttp"` — по образцу singbox-launcher SPEC 071: режимы
/// `auto|packet-up|stream-up|stream-one`, `x_padding_bytes`-обфускация,
/// `no_grpc_header`, extra-headers. Раньше деградировал в httpupgrade (стоковое
/// ядро без xhttp) — теперь **нативный** emit, без подмены wire-протокола.
///
/// NB: на СТОКОВОМ ядре (CI без `with_xhttp`) конфиг с `type=xhttp` отвергается
/// на load — фича «спит» до релиза fork-ядра (как AWG, §097).
final class XhttpTransport extends TransportSpec {
  final String path;
  final String host;
  final String mode; // '' = ядро решает (auto)
  final String xPaddingBytes; // '' = none, напр. '100-1000'
  final bool noGrpcHeader;
  final Map<String, String> headers;

  const XhttpTransport({
    this.path = '/',
    this.host = '',
    this.mode = '',
    this.xPaddingBytes = '',
    this.noGrpcHeader = false,
    this.headers = const {},
  });

  @override
  (Map<String, dynamic>, List<NodeWarning>) toSingbox(TemplateVars vars) {
    final m = <String, dynamic>{'type': 'xhttp', 'path': path};
    if (host.isNotEmpty) m['host'] = host;
    if (mode.isNotEmpty) m['mode'] = mode;
    if (xPaddingBytes.isNotEmpty) m['x_padding_bytes'] = xPaddingBytes;
    if (noGrpcHeader) m['no_grpc_header'] = true;
    if (headers.isNotEmpty) m['headers'] = Map<String, String>.from(headers);
    return (m, const []);
  }
}
