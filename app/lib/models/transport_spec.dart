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

/// XHTTP → httpupgrade. sing-box 1.12.x не поддерживает xhttp как transport
/// (см. docs/PROTOCOLS.md §XHTTP). Компилятор проверяет sealed-кейс, поэтому
/// fallback невозможно забыть добавить в новый вариант.
final class XhttpTransport extends TransportSpec {
  final String path;
  final String host;
  const XhttpTransport({this.path = '/', this.host = ''});

  @override
  (Map<String, dynamic>, List<NodeWarning>) toSingbox(TemplateVars vars) {
    final (m, _) = HttpUpgradeTransport(path: path, host: host).toSingbox(vars);
    return (m, const [UnsupportedTransportWarning('xhttp', 'httpupgrade')]);
  }
}
