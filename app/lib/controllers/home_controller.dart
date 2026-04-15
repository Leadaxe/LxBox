import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileSystemException;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../config/clash_endpoint.dart';
import '../vpn/box_vpn_client.dart';
import '../config/config_parse.dart';
import '../models/home_state.dart';
import '../services/clash_api_client.dart';

class HomeController extends ChangeNotifier {
  final BoxVpnClient _vpn = BoxVpnClient();
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  ClashApiClient? _clash;
  ClashApiClient? get clashClient => _clash;
  Timer? _heartbeat;
  int _heartbeatFailures = 0;

  static const _heartbeatInterval = Duration(seconds: 20);
  static const _heartbeatTimeout = Duration(seconds: 4);
  static const _maxHeartbeatFailures = 2;

  HomeState _state = const HomeState();
  HomeState get state => _state;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> init() async {
    await _loadSavedConfig();
    _statusSub = _vpn.onStatusChanged.listen(_handleStatusEvent);
  }

  @override
  void dispose() {
    _stopHeartbeat();
    _statusSub?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // State helpers
  // ---------------------------------------------------------------------------

  void _emit(HomeState next) {
    _state = next;
    notifyListeners();
  }

  void _addDebug(DebugSource source, String message) {
    final line = message.trim();
    if (line.isEmpty) return;
    final next = <DebugEntry>[
      DebugEntry(time: DateTime.now(), source: source, message: line),
      ..._state.debugEvents,
    ];
    if (next.length > 100) {
      next.removeRange(100, next.length);
    }
    _emit(_state.copyWith(debugEvents: next));
  }

  // ---------------------------------------------------------------------------
  // Native VPN events
  // ---------------------------------------------------------------------------

  void _handleStatusEvent(Map<String, dynamic> event) {
    final raw = event['status']?.toString() ?? '';
    final tunnel = TunnelStatus.fromNative(raw);
    _addDebug(DebugSource.core, event.toString());
    _emit(_state.copyWith(tunnel: tunnel));

    if (tunnel == TunnelStatus.connected) {
      _emit(_state.copyWith(connectedSince: DateTime.now()));
      unawaited(_refreshClashAfterTunnel());
      _startHeartbeat();
    } else if (tunnel == TunnelStatus.disconnected ||
        tunnel == TunnelStatus.revoked) {
      _stopHeartbeat();
      final reason = tunnel == TunnelStatus.revoked
          ? 'VPN revoked by another app'
          : _extractStopReason(event);
      _emit(
        _state.copyWith(
          lastError: reason.isNotEmpty ? reason : _state.lastError,
          proxiesJson: <String, dynamic>{},
          groups: <String>[],
          nodes: <String>[],
          highlightedNode: null,
          traffic: TrafficSnapshot.zero,
          connectedSince: null,
        ),
      );
      if (reason.isNotEmpty) {
        _addDebug(DebugSource.core, reason);
      }
    } else {
      _stopHeartbeat();
    }
  }

  // ---------------------------------------------------------------------------
  // Tunnel heartbeat — detects when another VPN app takes over
  // ---------------------------------------------------------------------------

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatFailures = 0;
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) => _checkHeartbeat());
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _heartbeatFailures = 0;
  }

  Future<void> _checkHeartbeat() async {
    if (!_state.tunnelUp) {
      _stopHeartbeat();
      return;
    }
    final clash = _clash;
    if (clash == null) return;

    try {
      final traffic = await clash.fetchTraffic().timeout(_heartbeatTimeout);
      _heartbeatFailures = 0;
      _emit(_state.copyWith(traffic: traffic));
    } catch (_) {
      _heartbeatFailures++;
      _addDebug(
        DebugSource.app,
        'Heartbeat failed ($_heartbeatFailures/$_maxHeartbeatFailures)',
      );
      if (_heartbeatFailures >= _maxHeartbeatFailures) {
        _stopHeartbeat();
        _onTunnelDead();
      }
    }
  }

  void _onTunnelDead() {
    _addDebug(DebugSource.app, 'Tunnel appears dead (heartbeat lost)');
    cancelMassPing();
    _emit(
      _state.copyWith(
        tunnel: TunnelStatus.revoked,
        lastError: 'VPN tunnel lost — another VPN may have taken over',
        proxiesJson: <String, dynamic>{},
        groups: <String>[],
        nodes: <String>[],
        highlightedNode: null,
      ),
    );
    unawaited(_tryCleanStop());
  }

  Future<void> _tryCleanStop() async {
    try {
      await _vpn.stopVPN();
    } catch (_) {
      // Best-effort: the native VPN is likely already dead
    }
  }

  String _extractStopReason(Map<String, dynamic> event) {
    const keys = <String>['error', 'message', 'reason', 'details', 'description'];
    for (final key in keys) {
      final value = event[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return 'Stopped: $text';
    }
    return '';
  }

  // ---------------------------------------------------------------------------
  // Config persistence
  // ---------------------------------------------------------------------------

  Future<void> _loadSavedConfig() async {
    try {
      final config = await _vpn.getConfig();
      if (config.isNotEmpty && config != '{}') {
        _emit(_state.copyWith(configRaw: config));
        _rebuildClashEndpoint();
      }
    } catch (e) {
      _addDebug(DebugSource.app, 'Load config: $e');
    }
  }

  void _rebuildClashEndpoint() {
    final endpoint = ClashEndpoint.fromConfigJson(_state.configRaw);
    _clash = endpoint != null ? ClashApiClient(endpoint) : null;
  }

  Future<bool> saveParsedConfig(String canonicalJson, {String? displayRaw}) async {
    final ok = await _vpn.saveConfig(canonicalJson);
    if (!ok) {
      _emit(_state.copyWith(lastError: 'Failed to save config'));
      _addDebug(DebugSource.app, 'Save config failed');
      return false;
    }
    final raw = displayRaw ?? canonicalJson;
    _emit(_state.copyWith(configRaw: raw, lastError: ''));
    _rebuildClashEndpoint();
    _addDebug(DebugSource.app, 'Config saved (${canonicalJson.length} bytes)');
    return true;
  }

  Future<bool> saveConfigRaw(String raw) async {
    if (raw.trim().isEmpty) {
      _emit(_state.copyWith(lastError: 'Config is empty'));
      _addDebug(DebugSource.app, 'Save rejected: empty config');
      return false;
    }
    try {
      final canonical = canonicalJsonForSingbox(raw);
      return saveParsedConfig(canonical, displayRaw: raw);
    } on FormatException catch (e) {
      _emit(_state.copyWith(lastError: 'Failed to parse config: ${e.message}'));
      _addDebug(DebugSource.app, 'Config parse error: ${e.message}');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Config import (clipboard / file)
  // ---------------------------------------------------------------------------

  Future<bool> readFromClipboard() async {
    _emit(_state.copyWith(busy: true, lastError: ''));
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (text.trim().isEmpty) {
        _emit(_state.copyWith(lastError: 'Clipboard is empty', busy: false));
        _addDebug(DebugSource.app, 'Clipboard is empty');
        return false;
      }
      final canonical = canonicalJsonForSingbox(text);
      final ok = await saveParsedConfig(canonical, displayRaw: text);
      _emit(_state.copyWith(busy: false));
      return ok;
    } on FormatException catch (e) {
      _emit(_state.copyWith(lastError: 'Failed to parse config: ${e.message}', busy: false));
      _addDebug(DebugSource.app, 'Clipboard parse error: ${e.message}');
      return false;
    } catch (_) {
      _emit(_state.copyWith(lastError: 'Failed to parse config', busy: false));
      _addDebug(DebugSource.app, 'Clipboard parse failed');
      return false;
    }
  }

  Future<bool> readFromFile() async {
    _emit(_state.copyWith(busy: true, lastError: ''));
    try {
      final result = await FilePicker.pickFiles(withData: true, allowMultiple: false);
      if (result == null || result.files.isEmpty) {
        _emit(_state.copyWith(busy: false));
        return false;
      }
      final file = result.files.single;
      final bytes = file.bytes;
      final path = file.path;
      late final String text;

      if (bytes != null && bytes.isNotEmpty) {
        text = utf8.decode(bytes, allowMalformed: true);
      } else if (path != null) {
        try {
          text = await File(path).readAsString();
        } on FileSystemException catch (e) {
          _emit(_state.copyWith(lastError: 'Failed to read file: $e', busy: false));
          _addDebug(DebugSource.app, 'File read error: $e');
          return false;
        }
      } else {
        _emit(_state.copyWith(lastError: 'Failed to read file', busy: false));
        _addDebug(DebugSource.app, 'File pick failed: no bytes and no path');
        return false;
      }

      if (text.trim().isEmpty) {
        _emit(_state.copyWith(lastError: 'File is empty', busy: false));
        _addDebug(DebugSource.app, 'Selected file is empty');
        return false;
      }

      final canonical = canonicalJsonForSingbox(text);
      final ok = await saveParsedConfig(canonical, displayRaw: text);
      _emit(_state.copyWith(busy: false));
      return ok;
    } on FormatException catch (e) {
      _emit(_state.copyWith(lastError: 'Failed to parse config: ${e.message}', busy: false));
      _addDebug(DebugSource.app, 'File parse error: ${e.message}');
      return false;
    } catch (e) {
      _emit(_state.copyWith(lastError: 'File error: $e', busy: false));
      _addDebug(DebugSource.app, 'File read error: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // VPN tunnel control
  // ---------------------------------------------------------------------------

  Future<void> start() async {
    _emit(_state.copyWith(busy: true, lastError: ''));
    try {
      await _vpn.setNotificationTitle('BoxVPN');
      final ok = await _vpn.startVPN();
      if (!ok) {
        _emit(_state.copyWith(lastError: 'Failed to start VPN'));
        _addDebug(DebugSource.app, 'startVPN returned false');
      } else {
        _addDebug(DebugSource.app, 'startVPN requested');
      }
    } catch (e) {
      _emit(_state.copyWith(lastError: '$e'));
      _addDebug(DebugSource.app, 'startVPN exception: $e');
    } finally {
      _emit(_state.copyWith(busy: false));
    }
  }

  Future<void> stop() async {
    _emit(_state.copyWith(busy: true, lastError: ''));
    try {
      await _vpn.stopVPN();
      _addDebug(DebugSource.app, 'stopVPN requested');
    } catch (e) {
      _emit(_state.copyWith(lastError: '$e'));
      _addDebug(DebugSource.app, 'stopVPN exception: $e');
    } finally {
      _emit(_state.copyWith(busy: false));
    }
  }

  // ---------------------------------------------------------------------------
  // Clash API — proxies & groups
  // ---------------------------------------------------------------------------

  Future<void> _refreshClashAfterTunnel() async {
    _rebuildClashEndpoint();
    await reloadProxies();
  }

  Future<void> reloadProxies() async {
    final clash = _clash;
    if (clash == null || _state.configRaw.isEmpty) return;
    try {
      await clash.pingVersion();
      final proxies = await clash.fetchProxies();
      final groups = ClashApiClient.selectorGroupTags(proxies)
          .where((name) => name != 'GLOBAL')
          .toList();

      String? initial = _state.selectedGroup;
      if (initial == null || !groups.contains(initial)) {
        final finalTag = ClashEndpoint.routeFinalTag(_state.configRaw);
        if (finalTag != null && groups.contains(finalTag)) {
          initial = finalTag;
        } else {
          initial = groups.isNotEmpty ? groups.first : null;
        }
      }

      _emit(
        _state.copyWith(
          proxiesJson: proxies,
          groups: groups,
          selectedGroup: initial,
        ),
      );
      await applyGroup(initial);
    } catch (e) {
      _emit(_state.copyWith(lastError: 'Clash API: $e'));
      _addDebug(DebugSource.app, 'Clash API error: $e');
    }
  }

  Future<void> applyGroup(String? tag) async {
    if (tag == null) {
      _emit(
        _state.copyWith(
          nodes: <String>[],
          activeInGroup: null,
          highlightedNode: null,
        ),
      );
      return;
    }
    final entry = ClashApiClient.proxyEntry(_state.proxiesJson, tag);
    if (entry == null) return;
    final all = entry['all'];
    final now = entry['now']?.toString();
    final nodes = all is List ? all.map((e) => e.toString()).toList() : <String>[];
    _emit(
      _state.copyWith(
        nodes: nodes,
        activeInGroup: now,
        highlightedNode: now,
      ),
    );
  }

  Future<void> switchNode(String nodeTag) async {
    final group = _state.selectedGroup;
    final clash = _clash;
    if (group == null || clash == null) return;
    _emit(_state.copyWith(busy: true, highlightedNode: nodeTag));
    try {
      await clash.selectInGroup(group, nodeTag);
      await reloadProxies();
      _addDebug(DebugSource.app, 'Node selected: $nodeTag');
    } catch (e) {
      _emit(_state.copyWith(lastError: 'Switch failed: $e'));
      _addDebug(DebugSource.app, 'Node switch error: $e');
    } finally {
      _emit(_state.copyWith(busy: false));
    }
  }

  Future<void> pingNode(String nodeTag) async {
    final clash = _clash;
    if (clash == null) return;
    final pingBusy = Map<String, String>.from(_state.pingBusy)..[nodeTag] = '…';
    _emit(_state.copyWith(pingBusy: pingBusy));
    try {
      final ms = await clash.delay(nodeTag);
      final nextDelay = Map<String, int>.from(_state.lastDelay)..[nodeTag] = ms;
      final nextBusy = Map<String, String>.from(_state.pingBusy)..[nodeTag] = '';
      _emit(_state.copyWith(lastDelay: nextDelay, pingBusy: nextBusy));
      _addDebug(DebugSource.app, 'Ping $nodeTag: ${ms}ms');
    } catch (e) {
      final nextDelay = Map<String, int>.from(_state.lastDelay)..[nodeTag] = -1;
      final nextBusy = Map<String, String>.from(_state.pingBusy)..[nodeTag] = '';
      _emit(_state.copyWith(lastDelay: nextDelay, pingBusy: nextBusy, lastError: 'Ping: $e'));
      _addDebug(DebugSource.app, 'Ping error for $nodeTag: $e');
    }
  }

  bool _massPingRunning = false;
  bool get massPingRunning => _massPingRunning;
  int _massPingEpoch = 0;

  static const _pingConcurrency = 20;

  Future<void> pingAllNodes() async {
    final clash = _clash;
    if (clash == null || _state.nodes.isEmpty) return;

    if (_massPingRunning) {
      cancelMassPing();
      return;
    }

    _massPingRunning = true;
    _massPingEpoch++;
    final epoch = _massPingEpoch;

    // Reset all delays and mark all nodes as busy
    final nodes = List<String>.from(_state.nodes);
    final busyMap = {for (final tag in nodes) tag: '…'};
    _emit(_state.copyWith(lastDelay: <String, int>{}, pingBusy: busyMap));
    _addDebug(DebugSource.app, 'Mass ping started (${nodes.length} nodes, concurrency=$_pingConcurrency)');

    // Parallel ping with limited concurrency
    var index = 0;
    Future<void> worker() async {
      while (true) {
        final i = index++;
        if (i >= nodes.length) break;
        if (!_massPingRunning || _massPingEpoch != epoch || !_state.tunnelUp) break;
        final tag = nodes[i];
        try {
          final ms = await clash.delay(tag);
          if (_massPingEpoch != epoch) break;
          final nextDelay = Map<String, int>.from(_state.lastDelay)..[tag] = ms;
          final nextBusy = Map<String, String>.from(_state.pingBusy)..[tag] = '';
          _emit(_state.copyWith(lastDelay: nextDelay, pingBusy: nextBusy));
        } catch (_) {
          if (_massPingEpoch != epoch) break;
          final nextDelay = Map<String, int>.from(_state.lastDelay)..[tag] = -1;
          final nextBusy = Map<String, String>.from(_state.pingBusy)..[tag] = '';
          _emit(_state.copyWith(lastDelay: nextDelay, pingBusy: nextBusy));
        }
      }
    }

    final workers = List.generate(
      _pingConcurrency.clamp(1, nodes.length),
      (_) => worker(),
    );
    await Future.wait(workers);

    if (_massPingEpoch == epoch) {
      _massPingRunning = false;
      _addDebug(DebugSource.app, 'Mass ping finished');
      notifyListeners();
    }
  }

  void cancelMassPing() {
    if (!_massPingRunning) return;
    _massPingRunning = false;
    _massPingEpoch++;
    _addDebug(DebugSource.app, 'Mass ping cancelled');
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // UI selection helpers
  // ---------------------------------------------------------------------------

  void setSelectedGroup(String? group) {
    _emit(_state.copyWith(selectedGroup: group));
  }

  void setHighlightedNode(String nodeTag) {
    _emit(_state.copyWith(highlightedNode: nodeTag));
  }

  void cycleSortMode() {
    _emit(_state.copyWith(sortMode: _state.sortMode.next));
  }

  /// Called when the app returns from background. Verifies tunnel health.
  void onAppResumed() {
    if (_state.tunnelUp) {
      unawaited(_checkHeartbeat());
    }
  }
}
