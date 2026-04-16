import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/proxy_source.dart';
import '../services/config_builder.dart';
import '../services/get_free_loader.dart';
import '../services/node_parser.dart';
import '../services/settings_storage.dart';
import '../services/source_loader.dart';

/// Manages subscriptions: add/remove/update, generates config.
class SubscriptionController extends ChangeNotifier {
  List<SubscriptionEntry> _entries = [];
  List<SubscriptionEntry> get entries => _entries;

  bool _busy = false;
  bool get busy => _busy;

  String _lastError = '';
  String get lastError => _lastError;

  String _progressMessage = '';
  String get progressMessage => _progressMessage;

  String? _lastGeneratedConfig;
  String? get lastGeneratedConfig => _lastGeneratedConfig;

  Future<void> init() async {
    final sources = await SettingsStorage.getProxySources();
    _entries = sources.map((s) => SubscriptionEntry(source: s)).toList();
    notifyListeners();
  }

  /// Adds a subscription URL or direct link from user input.
  Future<void> addFromInput(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return;

    _busy = true;
    _lastError = '';
    notifyListeners();

    try {
      if (NodeParser.isSubscriptionURL(trimmed)) {
        final entry = SubscriptionEntry(
          source: ProxySource(source: trimmed),
        );
        _entries.add(entry);
        await _persistSources();
        // Fetch immediately to show node count
        await _fetchEntry(_entries.length - 1);
      } else if (NodeParser.isDirectLink(trimmed)) {
        final entry = SubscriptionEntry(
          source: ProxySource(connections: [trimmed]),
          nodeCount: 1,
          status: 'Direct link',
        );
        _entries.add(entry);
        await _persistSources();
      } else {
        _lastError = 'Input is not a subscription URL or proxy link';
      }
    } catch (e) {
      _lastError = e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _entries.length) return;
    _entries.removeAt(index);
    await _persistSources();
    notifyListeners();
  }

  Future<void> renameAt(int index, String name) async {
    if (index < 0 || index >= _entries.length) return;
    _entries[index].source.name = name;
    await _persistSources();
    notifyListeners();
  }

  Future<void> updateAt(int index) async {
    if (index < 0 || index >= _entries.length) return;
    await _fetchEntry(index);
  }

  Future<void> moveEntry(int from, int to) async {
    if (from < 0 || from >= _entries.length) return;
    if (to < 0 || to >= _entries.length) return;
    final entry = _entries.removeAt(from);
    _entries.insert(to, entry);
    await _persistSources();
    notifyListeners();
  }

  /// Fetches all subscriptions and regenerates config.
  Future<String?> updateAllAndGenerate() async {
    _busy = true;
    _lastError = '';
    _progressMessage = 'Updating subscriptions...';
    notifyListeners();

    try {
      for (var i = 0; i < _entries.length; i++) {
        if (_entries[i].source.source.isNotEmpty &&
            NodeParser.isSubscriptionURL(_entries[i].source.source)) {
          await _fetchEntry(i);
        }
      }

      _progressMessage = 'Generating config...';
      notifyListeners();

      final config = await ConfigBuilder.generateConfig(
        onProgress: (p, msg) {
          _progressMessage = msg;
          notifyListeners();
        },
      );

      _lastGeneratedConfig = config;
      _progressMessage = '';
      await SettingsStorage.setLastGlobalUpdate(DateTime.now());
      return config;
    } catch (e) {
      _lastError = e.toString();
      return null;
    } finally {
      _busy = false;
      _progressMessage = '';
      notifyListeners();
    }
  }

  /// Generates config without re-fetching subscriptions.
  Future<String?> generateConfig() async {
    _busy = true;
    _lastError = '';
    notifyListeners();

    try {
      final config = await ConfigBuilder.generateConfig(
        onProgress: (p, msg) {
          _progressMessage = msg;
          notifyListeners();
        },
      );
      _lastGeneratedConfig = config;
      return config;
    } catch (e) {
      _lastError = e.toString();
      return null;
    } finally {
      _busy = false;
      _progressMessage = '';
      notifyListeners();
    }
  }

  Future<void> _fetchEntry(int index) async {
    final entry = _entries[index];
    try {
      entry.status = 'Fetching...';
      notifyListeners();

      final tagCounts = <String, int>{};
      final result = await SourceLoader.loadNodesWithMeta(
        entry.source,
        tagCounts,
        sourceIndex: index,
        totalSources: _entries.length,
      );
      entry.nodeCount = result.nodes.length;
      entry.source.lastUpdated = DateTime.now();
      entry.source.lastNodeCount = result.nodes.length;
      entry.status = '${result.nodes.length} nodes';
      // Use profile-title from HTTP headers as default name if not set
      if (entry.source.name.isEmpty && result.profileTitle != null) {
        entry.source.name = result.profileTitle!;
      }
      // Store subscription metadata from HTTP headers
      if (result.userInfo != null) {
        entry.source.uploadBytes = result.userInfo!.upload;
        entry.source.downloadBytes = result.userInfo!.download;
        entry.source.totalBytes = result.userInfo!.total;
        entry.source.expireTimestamp = result.userInfo!.expire;
      }
      if (result.supportUrl != null) entry.source.supportUrl = result.supportUrl!;
      if (result.webPageUrl != null) entry.source.webPageUrl = result.webPageUrl!;
      await _persistSources();
    } catch (e) {
      // Keep cached data — only update status to show the error
      entry.status = entry.nodeCount > 0
          ? '${entry.nodeCount} nodes (update failed)'
          : 'Error: $e';
    }
    notifyListeners();
  }

  /// Applies the built-in "Get Free VPN" preset: adds sources, sets rules, generates config.
  Future<String?> applyGetFreePreset() async {
    _busy = true;
    _lastError = '';
    _progressMessage = 'Loading preset...';
    notifyListeners();

    try {
      final preset = await GetFreeLoader.load();

      _entries = preset.proxySources
          .map((s) => SubscriptionEntry(source: s))
          .toList();
      await _persistSources();

      await SettingsStorage.saveEnabledRules(preset.enabledRules.toSet());

      _progressMessage = 'Fetching subscriptions...';
      notifyListeners();

      for (var i = 0; i < _entries.length; i++) {
        if (_entries[i].source.source.isNotEmpty) {
          await _fetchEntry(i);
        }
      }

      _progressMessage = 'Generating config...';
      notifyListeners();

      final config = await ConfigBuilder.generateConfig(
        onProgress: (p, msg) {
          _progressMessage = msg;
          notifyListeners();
        },
      );
      _lastGeneratedConfig = config;
      return config;
    } catch (e) {
      _lastError = e.toString();
      return null;
    } finally {
      _busy = false;
      _progressMessage = '';
      notifyListeners();
    }
  }

  Future<void> _persistSources() async {
    await SettingsStorage.saveProxySources(
      _entries.map((e) => e.source).toList(),
    );
  }
}

/// UI-visible entry for a subscription.
class SubscriptionEntry {
  SubscriptionEntry({
    required this.source,
    int? nodeCount,
    this.status = '',
  }) : nodeCount = nodeCount ?? source.lastNodeCount;

  final ProxySource source;
  int nodeCount;
  String status;

  String get displayName => source.displayName;

  String get subtitle {
    final parts = <String>[];
    if (status.isNotEmpty) parts.add(status);
    if (source.lastUpdated != null) {
      parts.add(formatAgo(source.lastUpdated!));
    }
    return parts.join(' · ');
  }

  static String formatAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
