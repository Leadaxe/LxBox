import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/clash_endpoint.dart';

class ClashApiClient {
  ClashApiClient(this.endpoint, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final ClashEndpoint endpoint;
  final http.Client _http;

  static const _timeout = Duration(seconds: 10);

  Map<String, String> get _headers => {
        if (endpoint.secret.isNotEmpty) 'Authorization': 'Bearer ${endpoint.secret}',
      };

  String get _origin {
    final s = endpoint.baseUri.toString();
    return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
  }

  Uri _u(String absolutePath) => Uri.parse('$_origin$absolutePath');

  Future<Map<String, dynamic>> fetchProxies() async {
    final r = await _http.get(_u('/proxies'), headers: _headers).timeout(_timeout);
    if (r.statusCode != 200) throw ClashHttpException(r.statusCode, r.body);
    final j = jsonDecode(r.body);
    if (j is! Map<String, dynamic>) throw const FormatException('proxies: not an object');
    return j;
  }

  static List<String> selectorGroupTags(Map<String, dynamic> proxiesResponse) {
    final proxies = proxiesResponse['proxies'];
    if (proxies is! Map<String, dynamic>) return [];
    final names = <String>[];
    for (final e in proxies.entries) {
      final v = e.value;
      if (v is! Map<String, dynamic>) continue;
      final t = v['type']?.toString() ?? '';
      if ((t == 'Selector' || t == 'URLTest') && v['all'] is List) {
        names.add(e.key);
      }
    }
    return names;
  }

  static Map<String, dynamic>? proxyEntry(Map<String, dynamic> proxiesResponse, String tag) {
    final proxies = proxiesResponse['proxies'];
    if (proxies is! Map<String, dynamic>) return null;
    final v = proxies[tag];
    return v is Map<String, dynamic> ? v : null;
  }

  Future<void> selectInGroup(String groupTag, String outboundTag) async {
    final uri = _u('/proxies/${Uri.encodeComponent(groupTag)}');
    final r = await _http
        .put(uri, headers: {..._headers, 'Content-Type': 'application/json'}, body: jsonEncode({'name': outboundTag}))
        .timeout(_timeout);
    if (r.statusCode != 204 && r.statusCode != 200) {
      throw ClashHttpException(r.statusCode, r.body);
    }
  }

  Future<int> delay(String proxyTag, {int timeoutMs = 5000, String url = ''}) async {
    final q = <String, String>{
      'timeout': '$timeoutMs',
      if (url.isNotEmpty) 'url': url,
    };
    final uri = _u('/proxies/${Uri.encodeComponent(proxyTag)}/delay')
        .replace(queryParameters: q);
    final r = await _http.get(uri, headers: _headers).timeout(_timeout);
    if (r.statusCode != 200) throw ClashHttpException(r.statusCode, r.body);
    final j = jsonDecode(r.body);
    if (j is Map<String, dynamic> && j['delay'] is num) {
      return (j['delay'] as num).toInt();
    }
    throw const FormatException('delay: bad response');
  }

  Future<void> pingVersion() async {
    final r = await _http.get(_u('/version'), headers: _headers).timeout(_timeout);
    if (r.statusCode != 200) throw ClashHttpException(r.statusCode, r.body);
  }
}

class ClashHttpException implements Exception {
  ClashHttpException(this.status, this.body);
  final int status;
  final String body;

  @override
  String toString() => 'HTTP $status';
}
