import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_singbox_vpn/flutter_singbox.dart';

import '../config/clash_endpoint.dart';
import '../services/clash_api_client.dart';

/// Главный экран MVP: Read, Start/Stop, группа, узлы, ping (см. спеки 002/003).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _singbox = FlutterSingbox();
  StreamSubscription<Map<String, dynamic>>? _statusSub;

  String _configRaw = '';
  String _statusText = '—';
  String _lastError = '';
  bool _busy = false;

  ClashApiClient? _clash;
  Map<String, dynamic> _proxiesJson = {};
  List<String> _groups = [];
  String? _selectedGroup;
  List<String> _nodes = [];
  String? _activeInGroup;
  final Map<String, int> _lastDelay = {};
  final Map<String, String> _pingBusy = {};

  @override
  void initState() {
    super.initState();
    _loadSavedConfig();
    _statusSub = _singbox.onStatusChanged.listen((m) {
      final s = m['status']?.toString() ?? '';
      setState(() => _statusText = s);
      if (s == 'Started') {
        unawaited(_refreshClashAfterTunnel());
      }
      if (s == 'Stopped') {
        setState(() {
          _clash = null;
          _proxiesJson = {};
          _groups = [];
          _nodes = [];
        });
      }
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }

  Future<void> _loadSavedConfig() async {
    try {
      final c = await _singbox.getConfig();
      if (c.isNotEmpty) {
        setState(() => _configRaw = c);
        _rebuildClashEndpoint();
      }
    } catch (_) {}
  }

  void _rebuildClashEndpoint() {
    final ep = ClashEndpoint.fromConfigJson(_configRaw);
    setState(() {
      _clash = ep != null ? ClashApiClient(ep) : null;
    });
  }

  Future<void> _refreshClashAfterTunnel() async {
    _rebuildClashEndpoint();
    await _reloadProxies();
  }

  Future<void> _reloadProxies() async {
    final c = _clash;
    if (c == null || _configRaw.isEmpty) return;
    try {
      await c.pingVersion();
      final px = await c.fetchProxies();
      final groups = ClashApiClient.selectorGroupTags(px)
          .where((n) => n != 'GLOBAL')
          .toList();
      final finalTag = ClashEndpoint.routeFinalTag(_configRaw);
      String? initial = _selectedGroup;
      if (initial == null || !groups.contains(initial)) {
        if (finalTag != null && groups.contains(finalTag)) {
          initial = finalTag;
        } else {
          initial = groups.isNotEmpty ? groups.first : null;
        }
      }
      setState(() {
        _proxiesJson = px;
        _groups = groups;
        _selectedGroup = initial;
      });
      await _applyGroup(initial);
    } catch (e) {
      setState(() => _lastError = 'Clash API: $e');
    }
  }

  Future<void> _applyGroup(String? tag) async {
    if (tag == null) {
      setState(() {
        _nodes = [];
        _activeInGroup = null;
      });
      return;
    }
    final entry = ClashApiClient.proxyEntry(_proxiesJson, tag);
    if (entry == null) return;
    final all = entry['all'];
    final now = entry['now']?.toString();
    final nodes = all is List ? all.map((e) => e.toString()).toList() : <String>[];
    setState(() {
      _nodes = nodes;
      _activeInGroup = now;
    });
  }

  Future<void> _readClipboard() async {
    setState(() {
      _busy = true;
      _lastError = '';
    });
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        setState(() => _lastError = 'Буфер пуст');
        return;
      }
      jsonDecode(text);
      final ok = await _singbox.saveConfig(text);
      if (!ok) {
        setState(() => _lastError = 'Не удалось сохранить конфиг');
        return;
      }
      setState(() {
        _configRaw = text;
        _lastError = '';
      });
      _rebuildClashEndpoint();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Конфиг сохранён')),
        );
      }
    } catch (_) {
      setState(() => _lastError = 'Не удалось разобрать JSON');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _lastError = '';
    });
    try {
      await _singbox.setNotificationTitle('BoxVPN');
      final ok = await _singbox.startVPN();
      if (!ok) setState(() => _lastError = 'Не удалось запустить VPN');
    } catch (e) {
      setState(() => _lastError = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    setState(() {
      _busy = true;
      _lastError = '';
    });
    try {
      await _singbox.stopVPN();
    } catch (e) {
      setState(() => _lastError = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _switchNode(String nodeTag) async {
    final g = _selectedGroup;
    final c = _clash;
    if (g == null || c == null) return;
    setState(() => _busy = true);
    try {
      await c.selectInGroup(g, nodeTag);
      await _reloadProxies();
    } catch (e) {
      setState(() => _lastError = 'Переключение: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _pingNode(String nodeTag) async {
    final c = _clash;
    if (c == null) return;
    setState(() => _pingBusy[nodeTag] = '…');
    try {
      final ms = await c.delay(nodeTag);
      setState(() {
        _lastDelay[nodeTag] = ms;
        _pingBusy[nodeTag] = '';
      });
    } catch (e) {
      setState(() {
        _lastDelay[nodeTag] = -1;
        _pingBusy[nodeTag] = '';
        _lastError = 'Ping: $e';
      });
    }
  }

  bool get _tunnelUp => _statusText == 'Started';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BoxVPN'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Вставьте JSON sing-box из буфера — Read, затем Start.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: _busy ? null : _readClipboard,
                  child: const Text('Read'),
                ),
                FilledButton(
                  onPressed: (_busy || _configRaw.isEmpty) ? null : _start,
                  child: const Text('Start'),
                ),
                FilledButton.tonal(
                  onPressed: _busy ? null : _stop,
                  child: const Text('Stop'),
                ),
                Text('VPN: $_statusText', style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            if (_lastError.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _lastError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            const Text('Группа', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            InputDecorator(
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Нет данных (нужен туннель и API)',
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _groups.contains(_selectedGroup) ? _selectedGroup : null,
                  hint: const Text('Выберите группу'),
                  items: _groups
                      .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                      .toList(),
                  onChanged: (!_tunnelUp || _busy || _groups.isEmpty)
                      ? null
                      : (v) async {
                          setState(() => _selectedGroup = v);
                          await _applyGroup(v);
                        },
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Узлы', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Expanded(
              child: _nodes.isEmpty
                  ? Center(
                      child: Text(
                        _tunnelUp
                            ? 'Нет узлов для группы'
                            : 'Запустите VPN для списка',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      itemCount: _nodes.length,
                      itemBuilder: (context, i) {
                        final tag = _nodes[i];
                        final active = tag == _activeInGroup;
                        final d = _lastDelay[tag];
                        final pingLabel = _pingBusy[tag] == '…'
                            ? '…'
                            : (d == null
                                ? 'ping'
                                : (d < 0 ? 'err' : '${d}ms'));
                        return ListTile(
                          title: Text(
                            tag,
                            style: active
                                ? const TextStyle(fontWeight: FontWeight.bold)
                                : null,
                          ),
                          subtitle: active ? const Text('активен') : null,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                onPressed: (!_tunnelUp || _busy || active)
                                    ? null
                                    : () => _switchNode(tag),
                                child: const Text('Вкл'),
                              ),
                              TextButton(
                                onPressed:
                                    (!_tunnelUp || _busy || (_pingBusy[tag] == '…'))
                                        ? null
                                        : () => _pingNode(tag),
                                child: Text(pingLabel),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
