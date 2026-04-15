import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class SpeedTestScreen extends StatefulWidget {
  const SpeedTestScreen({super.key});

  @override
  State<SpeedTestScreen> createState() => _SpeedTestScreenState();
}

class _SpeedTestScreenState extends State<SpeedTestScreen> {
  bool _running = false;
  String _status = 'Tap Start to begin';
  double _downloadMbps = 0;
  double _uploadMbps = 0;
  double _ping = 0;
  double _progress = 0;

  static const _testUrls = [
    'https://speed.cloudflare.com/__down?bytes=10000000', // 10MB
    'https://speed.hetzner.de/10MB.bin',
  ];
  static const _pingUrl = 'https://www.gstatic.com/generate_204';
  static const _uploadUrl = 'https://speed.cloudflare.com/__up';

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
      // Ping
      final pingStart = DateTime.now();
      await http.get(Uri.parse(_pingUrl)).timeout(const Duration(seconds: 5));
      final pingMs = DateTime.now().difference(pingStart).inMilliseconds;
      if (!mounted) return;
      setState(() {
        _ping = pingMs.toDouble();
        _progress = 0.1;
        _status = 'Testing download...';
      });

      // Download
      final dlSpeed = await _testDownload();
      if (!mounted) return;
      setState(() {
        _downloadMbps = dlSpeed;
        _progress = 0.6;
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
    } catch (e) {
      if (mounted) setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<double> _testDownload() async {
    for (final url in _testUrls) {
      try {
        final start = DateTime.now();
        final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
        final elapsed = DateTime.now().difference(start);
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          final bytes = response.bodyBytes.length;
          final seconds = elapsed.inMilliseconds / 1000.0;
          return (bytes * 8 / 1000000) / seconds; // Mbps
        }
      } catch (_) {
        continue;
      }
    }
    return 0;
  }

  Future<double> _testUpload() async {
    try {
      final data = List.filled(1000000, 0x41); // 1MB of 'A'
      final start = DateTime.now();
      await http.post(
        Uri.parse(_uploadUrl),
        body: data,
        headers: {'Content-Type': 'application/octet-stream'},
      ).timeout(const Duration(seconds: 15));
      final elapsed = DateTime.now().difference(start);
      final seconds = elapsed.inMilliseconds / 1000.0;
      return (data.length * 8 / 1000000) / seconds; // Mbps
    } catch (_) {
      return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Speed Test')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 24),
            // Ping
            _buildGauge('Ping', '${_ping.toStringAsFixed(0)} ms', Icons.network_ping, cs.primary),
            const SizedBox(height: 24),
            // Download
            _buildGauge('Download', '${_downloadMbps.toStringAsFixed(1)} Mbps', Icons.arrow_downward, cs.tertiary),
            const SizedBox(height: 24),
            // Upload
            _buildGauge('Upload', '${_uploadMbps.toStringAsFixed(1)} Mbps', Icons.arrow_upward, cs.secondary),
            const SizedBox(height: 32),
            if (_running) LinearProgressIndicator(value: _progress),
            const SizedBox(height: 8),
            Text(_status, style: Theme.of(context).textTheme.bodyMedium),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _running ? null : _runTest,
                icon: Icon(_running ? Icons.hourglass_top : Icons.speed),
                label: Text(_running ? 'Testing...' : 'Start Test'),
              ),
            ),
          ],
        ),
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
}
