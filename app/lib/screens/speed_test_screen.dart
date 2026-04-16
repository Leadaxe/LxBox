import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../controllers/home_controller.dart';
import '../services/config_builder.dart';

class SpeedTestScreen extends StatefulWidget {
  const SpeedTestScreen({super.key, required this.homeController});

  final HomeController homeController;

  @override
  State<SpeedTestScreen> createState() => _SpeedTestScreenState();
}

class _SpeedTestResult {
  _SpeedTestResult({
    required this.timestamp,
    required this.ping,
    required this.download,
    required this.upload,
    required this.proxy,
    required this.vpnEnabled,
    required this.server,
  });

  final DateTime timestamp;
  final double ping;
  final double download;
  final double upload;
  final String proxy;
  final bool vpnEnabled;
  final String server;
}

/// Session-scoped history — survives screen close, cleared on app restart.
final _sessionHistory = <_SpeedTestResult>[];

class _SpeedTestScreenState extends State<SpeedTestScreen> {
  bool _running = false;
  String _status = 'Tap Start to begin';
  double _downloadMbps = 0;
  double _uploadMbps = 0;
  double _ping = 0;
  double _progress = 0;
  List<_SpeedTestResult> get _history => _sessionHistory;
  int _streams = 4;
  int _selectedServer = 0;

  // Loaded from wizard_template
  var _servers = <Map<String, dynamic>>[];
  var _streamOptions = <int>[1, 4, 10];
  var _pingUrls = <String>['https://www.gstatic.com/generate_204'];

  @override
  void initState() {
    super.initState();
    unawaited(_loadConfig());
  }

  Future<void> _loadConfig() async {
    final template = await ConfigBuilder.loadTemplate();
    final opts = template.speedTestOptions;
    final servers = (opts['servers'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final streams = (opts['stream_options'] as List<dynamic>?)
        ?.whereType<num>()
        .map((n) => n.toInt())
        .toList();
    final pings = (opts['ping_urls'] as List<dynamic>?)
        ?.whereType<String>()
        .toList();
    final defaultStreams = (opts['default_streams'] as num?)?.toInt();

    if (mounted) {
      setState(() {
        if (servers.isNotEmpty) _servers = servers;
        if (streams != null && streams.isNotEmpty) _streamOptions = streams;
        if (pings != null && pings.isNotEmpty) _pingUrls = pings;
        if (defaultStreams != null) _streams = defaultStreams;
      });
    }
  }

  String get _currentProxy {
    final state = widget.homeController.state;
    if (!state.tunnelUp) return 'Direct';
    return state.activeInGroup ?? state.selectedGroup ?? 'VPN';
  }

  bool get _vpnEnabled => widget.homeController.state.tunnelUp;

  Future<void> _runTest() async {
    if (_running) return;
    setState(() {
      _running = true;
      _status = 'Testing ping...';
      _downloadMbps = 0;
      _uploadMbps = 0;
      _ping = 0;
      _progress = 0;
    });

    try {
      // Ping — 5 attempts, trimmed mean
      final pingResult = await _testPing();
      if (!mounted) return;
      setState(() {
        _ping = pingResult;
        _progress = 0.15;
        _status = 'Testing download...';
      });

      // Download — 4 parallel streams
      final dlSpeed = await _testDownload();
      if (!mounted) return;
      setState(() {
        _downloadMbps = dlSpeed;
        _progress = 0.65;
        _status = 'Testing upload...';
      });

      // Upload
      final ulSpeed = await _testUpload();
      if (!mounted) return;
      setState(() {
        _uploadMbps = ulSpeed;
        _progress = 1.0;
        _status = 'Complete';
      });

      // Save to session history
      _history.insert(
        0,
        _SpeedTestResult(
          timestamp: DateTime.now(),
          ping: _ping,
          download: _downloadMbps,
          upload: _uploadMbps,
          proxy: _currentProxy,
          vpnEnabled: _vpnEnabled,
          server: _serverName(_selectedServer),
        ),
      );
      if (_history.length > 10) _history.removeLast();
    } catch (e) {
      if (mounted) setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<double> _testPing() async {
    final times = <int>[];
    for (final url in _pingUrls) {
      for (var i = 0; i < 2; i++) {
        try {
          final sw = Stopwatch()..start();
          final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
          sw.stop();
          if (response.statusCode < 400) {
            times.add(sw.elapsedMilliseconds);
          }
        } catch (_) {}
        if (times.length >= 5) break;
      }
      if (times.length >= 5) break;
    }

    if (times.isEmpty) return -1;
    times.sort();
    // Trimmed mean: drop min and max if we have 3+
    if (times.length >= 3) {
      final trimmed = times.sublist(1, times.length - 1);
      return trimmed.reduce((a, b) => a + b) / trimmed.length;
    }
    return times.reduce((a, b) => a + b) / times.length;
  }

  String _serverName(int i) => _servers[i]['name']?.toString() ?? 'Server $i';
  String _serverDownloadUrl(int i) => _servers[i]['download_url']?.toString() ?? '';
  String? _serverUploadUrl(int i) => _servers[i]['upload_url']?.toString();
  String _serverUploadMethod(int i) => _servers[i]['upload_method']?.toString() ?? 'PUT';

  /// Download test: parallel streams with real-time speed updates.
  Future<double> _testDownload() async {
    final url = _serverDownloadUrl(_selectedServer);
    if (url.isNotEmpty) {
      try {
        final result = await _multiStreamDownload(url, _streams);
        if (result > 0) return result;
      } catch (_) {}
    }
    // Fallback to other servers
    for (var i = 0; i < _servers.length; i++) {
      if (i == _selectedServer) continue;
      final fallbackUrl = _serverDownloadUrl(i);
      if (fallbackUrl.isEmpty) continue;
      try {
        final result = await _multiStreamDownload(fallbackUrl, _streams);
        if (result > 0) return result;
      } catch (_) {}
    }
    return 0;
  }

  var _dlBytesTotal = 0;

  Future<double> _multiStreamDownload(String url, int streams) async {
    final client = http.Client();
    _dlBytesTotal = 0;
    final sw = Stopwatch()..start();

    // Real-time UI update timer
    final uiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || !_running) return;
      final seconds = sw.elapsedMilliseconds / 1000.0;
      if (seconds > 0.5) {
        setState(() {
          _downloadMbps = (_dlBytesTotal * 8 / 1000000) / seconds;
        });
      }
    });

    try {
      final futures = <Future<void>>[];
      for (var i = 0; i < streams; i++) {
        futures.add(_downloadStream(client, url));
      }
      await Future.wait(futures).timeout(const Duration(seconds: 15));
      sw.stop();
      uiTimer.cancel();

      if (_dlBytesTotal == 0) return 0;
      final seconds = sw.elapsedMilliseconds / 1000.0;
      return (_dlBytesTotal * 8 / 1000000) / seconds;
    } catch (_) {
      sw.stop();
      uiTimer.cancel();
      if (_dlBytesTotal == 0) return 0;
      final seconds = sw.elapsedMilliseconds / 1000.0;
      return (_dlBytesTotal * 8 / 1000000) / seconds;
    } finally {
      client.close();
    }
  }

  Future<void> _downloadStream(http.Client client, String url) async {
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request).timeout(const Duration(seconds: 15));
      await for (final chunk in response.stream) {
        _dlBytesTotal += chunk.length;
      }
    } catch (_) {}
  }

  Future<double> _testUpload() async {
    // 2 parallel upload streams, 2MB each
    final client = http.Client();
    try {
      final data = Uint8List(5 * 1024 * 1024);
      var totalBytes = 0;
      final sw = Stopwatch()..start();

      final futures = <Future<int>>[];
      for (var i = 0; i < 2; i++) {
        futures.add(_uploadStream(client, data));
      }

      final results = await Future.wait(futures).timeout(const Duration(seconds: 30));
      sw.stop();

      for (final bytes in results) {
        totalBytes += bytes;
      }

      if (totalBytes == 0) return 0;
      final seconds = sw.elapsedMilliseconds / 1000.0;
      return (totalBytes * 8 / 1000000) / seconds;
    } finally {
      client.close();
    }
  }

  Future<int> _uploadStream(http.Client client, Uint8List data) async {
    try {
      final uploadUrl = _serverUploadUrl(_selectedServer) ?? _serverDownloadUrl(_selectedServer);
      final uri = Uri.parse(uploadUrl);
      final headers = {'Content-Type': 'application/octet-stream'};
      final method = _serverUploadMethod(_selectedServer);
      if (method == 'POST') {
        await http.post(uri, body: data, headers: headers).timeout(const Duration(seconds: 30));
      } else {
        await http.put(uri, body: data, headers: headers).timeout(const Duration(seconds: 30));
      }
      return data.length;
    } catch (_) {
      return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Speed Test')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // Proxy indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  _vpnEnabled ? Icons.vpn_key : Icons.public,
                  size: 16,
                  color: _vpnEnabled ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  _vpnEnabled ? 'Via: $_currentProxy' : 'Direct (no VPN)',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Ping
          _buildGauge(
            'Ping',
            _ping < 0 ? 'Failed' : '${_ping.toStringAsFixed(0)} ms',
            Icons.network_ping,
            cs.primary,
          ),
          const SizedBox(height: 24),

          // Download
          _buildGauge(
            'Download',
            '${_downloadMbps.toStringAsFixed(1)} Mbps',
            Icons.arrow_downward,
            cs.tertiary,
          ),
          const SizedBox(height: 24),

          // Upload
          _buildGauge(
            'Upload',
            '${_uploadMbps.toStringAsFixed(1)} Mbps',
            Icons.arrow_upward,
            cs.secondary,
          ),
          const SizedBox(height: 32),

          if (_running) LinearProgressIndicator(value: _progress),
          const SizedBox(height: 8),
          Text(_status, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
          const SizedBox(height: 24),

          // Settings
          if (!_running) ...[
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _selectedServer,
                    decoration: const InputDecoration(
                      labelText: 'Server',
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    style: TextStyle(fontSize: 13, color: cs.onSurface),
                    items: List.generate(_servers.length, (i) =>
                      DropdownMenuItem(value: i, child: Text(_serverName(i))),
                    ),
                    onChanged: (v) { if (v != null) setState(() => _selectedServer = v); },
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 100,
                  child: DropdownButtonFormField<int>(
                    initialValue: _streams,
                    decoration: const InputDecoration(
                      labelText: 'Streams',
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    style: TextStyle(fontSize: 13, color: cs.onSurface),
                    items: _streamOptions.map((n) =>
                      DropdownMenuItem(value: n, child: Text('$n')),
                    ).toList(),
                    onChanged: (v) { if (v != null) setState(() => _streams = v); },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],

          // Start button
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _running ? null : _runTest,
              icon: Icon(_running ? Icons.hourglass_top : Icons.speed),
              label: Text(_running ? 'Testing...' : 'Start Test'),
            ),
          ),

          // History
          if (_history.isNotEmpty) ...[
            const SizedBox(height: 32),
            Text('Session History', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            ..._history.map((r) => _buildHistoryTile(r, theme, cs)),
          ],
        ],
      ),
    );
  }

  Widget _buildGauge(String label, String value, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, size: 32, color: color),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ],
    );
  }

  Widget _buildHistoryTile(_SpeedTestResult r, ThemeData theme, ColorScheme cs) {
    final time = '${r.timestamp.hour.toString().padLeft(2, '0')}:${r.timestamp.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(time, style: theme.textTheme.bodySmall),
          ),
          Icon(
            r.vpnEnabled ? Icons.vpn_key : Icons.public,
            size: 12,
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.proxy,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  r.server,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 10,
                    color: cs.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Text(
            '${r.ping.toStringAsFixed(0)}ms',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.primary),
          ),
          const SizedBox(width: 12),
          Text(
            '↓${r.download.toStringAsFixed(1)}',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.tertiary),
          ),
          const SizedBox(width: 8),
          Text(
            '↑${r.upload.toStringAsFixed(1)}',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.secondary),
          ),
        ],
      ),
    );
  }
}
