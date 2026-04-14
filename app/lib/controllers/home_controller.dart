import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileSystemException;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_singbox_vpn/flutter_singbox.dart';

import '../config/clash_endpoint.dart';
import '../config/config_parse.dart';
import '../models/home_state.dart';
import '../services/clash_api_client.dart';

class HomeController extends ChangeNotifier {
  final FlutterSingbox _singbox = FlutterSingbox();
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  ClashApiClient? _clash;

  HomeState _state = const HomeState();
  HomeState get state => _state;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> init() async {
    await _loadSavedConfig();
    _statusSub = _singbox.onStatusChanged.listen(_handleStatusEvent);
  }

  @override
  void dispose() {
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
      unawaited(_refreshClashAfterTunnel());
    } else if (tunnel == TunnelStatus.disconnected) {
      final reason = _extractStopReason(event);
      _emit(
        _state.copyWith(
          lastError: reason.isNotEmpty ? reason : _state.lastError,
          proxiesJson: <String, dynamic>{},
          groups: <String>[],
          nodes: <String>[],
          highlightedNode: null,
        ),
      );
      if (reason.isNotEmpty) {
        _addDebug(DebugSource.core, reason);
      }
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
      final config = await _singbox.getConfig();
      if (config.isNotEmpty) {
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
    final ok = await _singbox.saveConfig(canonicalJson);
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
      await _singbox.setNotificationTitle('BoxVPN');
      final ok = await _singbox.startVPN();
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
      await _singbox.stopVPN();
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

  // ---------------------------------------------------------------------------
  // UI selection helpers
  // ---------------------------------------------------------------------------

  void setSelectedGroup(String? group) {
    _emit(_state.copyWith(selectedGroup: group));
  }

  void setHighlightedNode(String nodeTag) {
    _emit(_state.copyWith(highlightedNode: nodeTag));
  }
}
