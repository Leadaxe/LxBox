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

  /// Returns tags of Selector groups only (excludes URLTest from dropdown).
  static List<String> selectorGroupTags(Map<String, dynamic> proxiesResponse) {
    final proxies = proxiesResponse['proxies'];
    if (proxies is! Map<String, dynamic>) return [];
    final names = <String>[];
    for (final e in proxies.entries) {
      final v = e.value;
      if (v is! Map<String, dynamic>) continue;
      final t = v['type']?.toString() ?? '';
      if (t == 'Selector' && v['all'] is List) {
        names.add(e.key);
      }
    }
    return names;
  }

  /// For a given node tag, if it's a URLTest group, returns its `now` (auto-selected node).
  static String? urltestNow(Map<String, dynamic> proxiesResponse, String tag) {
    final proxies = proxiesResponse['proxies'];
    if (proxies is! Map<String, dynamic>) return null;
    final v = proxies[tag];
    if (v is! Map<String, dynamic>) return null;
    final type = v['type']?.toString() ?? '';
    // Clash API may return "URLTest" or "urltest" depending on sing-box version
    if (!type.toLowerCase().contains('urltest')) return null;
    return v['now']?.toString();
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

  /// Triggers a URLTest on all members of a group. For URLTest groups, sing-box
  /// runs latency tests on each member and updates the group's `now` field to
  /// the fastest one. Returns map of member tag → delay ms (failed members have
  /// delay=0 or missing from map).
  Future<Map<String, int>> groupDelay(
    String groupTag, {
    int timeoutMs = 5000,
    String url = '',
  }) async {
    final q = <String, String>{
      'timeout': '$timeoutMs',
      if (url.isNotEmpty) 'url': url,
    };
    final uri = _u('/group/${Uri.encodeComponent(groupTag)}/delay')
        .replace(queryParameters: q);
    final r = await _http.get(uri, headers: _headers).timeout(
          // Timeout на клиенте чуть больше чем на сервере — sing-box сам
          // подождёт все свои таймауты (timeoutMs ms) и только потом ответит.
          Duration(milliseconds: timeoutMs + 5000),
        );
    if (r.statusCode != 200) throw ClashHttpException(r.statusCode, r.body);
    final j = jsonDecode(r.body);
    if (j is! Map) return const {};
    final out = <String, int>{};
    for (final e in j.entries) {
      final v = e.value;
      if (v is num) out[e.key.toString()] = v.toInt();
    }
    return out;
  }

  Future<void> pingVersion() async {
    final r = await _http.get(_u('/version'), headers: _headers).timeout(_timeout);
    if (r.statusCode != 200) throw ClashHttpException(r.statusCode, r.body);
  }

  /// Fetches full connections list.
  Future<Map<String, dynamic>> fetchConnections() async {
    final r = await _http.get(_u('/connections'), headers: _headers).timeout(_timeout);
    if (r.statusCode != 200) throw ClashHttpException(r.statusCode, r.body);
    final j = jsonDecode(r.body);
    if (j is! Map<String, dynamic>) throw const FormatException('connections: not an object');
    return j;
  }

  /// Close a single connection by ID.
  Future<void> closeConnection(String id) async {
    final r = await _http.delete(_u('/connections/$id'), headers: _headers).timeout(_timeout);
    if (r.statusCode != 204 && r.statusCode != 200) {
      throw ClashHttpException(r.statusCode, r.body);
    }
  }

  /// Close all connections.
  Future<void> closeAllConnections() async {
    final r = await _http.delete(_u('/connections'), headers: _headers).timeout(_timeout);
    if (r.statusCode != 204 && r.statusCode != 200) {
      throw ClashHttpException(r.statusCode, r.body);
    }
  }

  /// Fetches aggregate traffic + breakdowns from /connections.
  /// Parses в один проход: totals (с fallback на суммирование), memory,
  /// byRule/byDnsMode/byApp агрегации для Statistics-screen.
  Future<TrafficSnapshot> fetchTraffic() async {
    final r = await _http.get(_u('/connections'), headers: _headers).timeout(_timeout);
    if (r.statusCode != 200) throw ClashHttpException(r.statusCode, r.body);
    final j = jsonDecode(r.body);
    if (j is! Map<String, dynamic>) throw const FormatException('connections: not an object');
    return TrafficSnapshot.fromConnectionsJson(j);
  }
}

class TrafficSnapshot {
  const TrafficSnapshot({
    this.uploadTotal = 0,
    this.downloadTotal = 0,
    this.activeConnections = 0,
    this.memory = 0,
    this.byRule = const {},
    this.byApp = const {},
  });

  final int uploadTotal;
  final int downloadTotal;
  final int activeConnections;

  /// sing-box process RAM (bytes). Из `/connections.memory`.
  final int memory;

  /// Distribution of connections по `rule (+rulePayload)` — сколько conn'ов
  /// попало в каждое правило. Ключ: `rule` или `rule: payload` если payload
  /// не пустой. Значение: count.
  final Map<String, int> byRule;

  /// Per-app статистика: package-name (без UID-суффикса) → count + bytes.
  final Map<String, AppStat> byApp;

  static const zero = TrafficSnapshot();

  String get uploadFormatted => _formatBytes(uploadTotal);
  String get downloadFormatted => _formatBytes(downloadTotal);
  String get memoryFormatted => _formatBytes(memory);

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  /// Парсит `/connections` JSON — вынесено из fetchTraffic для тестов с
  /// fixture'ами без сетевого вызова.
  factory TrafficSnapshot.fromConnectionsJson(Map<String, dynamic> j) {
    var up = (j['uploadTotal'] as num?)?.toInt() ?? 0;
    var down = (j['downloadTotal'] as num?)?.toInt() ?? 0;
    final memory = (j['memory'] as num?)?.toInt() ?? 0;
    final conns = j['connections'] as List<dynamic>? ?? const [];

    // Fallback: если sing-box не заполнил top-level totals, суммируем
    // per-connection значения. Решение принимается до цикла — иначе
    // на первой ненулевой записи условие "up==0" уже false и остаток
    // conns пропустится.
    final needsSumFallback = up == 0 && down == 0;

    final byRule = <String, int>{};
    final byApp = <String, AppStat>{};

    for (final c in conns) {
      if (c is! Map<String, dynamic>) continue;
      final cu = (c['upload'] as num?)?.toInt() ?? 0;
      final cd = (c['download'] as num?)?.toInt() ?? 0;

      if (needsSumFallback) {
        up += cu;
        down += cd;
      }

      final rule = (c['rule']?.toString() ?? '').trim();
      final payload = (c['rulePayload']?.toString() ?? '').trim();
      if (rule.isNotEmpty) {
        final key = payload.isEmpty ? rule : '$rule: $payload';
        byRule[key] = (byRule[key] ?? 0) + 1;
      }

      final meta = c['metadata'];
      if (meta is Map<String, dynamic>) {
        final pkg = _extractPackage(meta['processPath']?.toString() ?? '');
        if (pkg.isNotEmpty) {
          final prev = byApp[pkg] ?? AppStat.zero;
          byApp[pkg] = AppStat(
            count: prev.count + 1,
            upload: prev.upload + cu,
            download: prev.download + cd,
          );
        }
      }
    }

    return TrafficSnapshot(
      uploadTotal: up,
      downloadTotal: down,
      activeConnections: conns.length,
      memory: memory,
      byRule: byRule,
      byApp: byApp,
    );
  }

  /// `"com.google.android.gms (10111)"` → `"com.google.android.gms"`.
  /// Пустое processPath → пустая строка (caller скипает).
  static String _extractPackage(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    final paren = s.indexOf(' (');
    return paren < 0 ? s : s.substring(0, paren);
  }
}

class AppStat {
  const AppStat({this.count = 0, this.upload = 0, this.download = 0});
  final int count;
  final int upload;
  final int download;

  static const zero = AppStat();

  int get totalBytes => upload + download;
}

class ClashHttpException implements Exception {
  ClashHttpException(this.status, this.body);
  final int status;
  final String body;

  @override
  String toString() => 'HTTP $status';
}
