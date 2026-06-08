import 'dart:async';

import 'package:flutter/widgets.dart';

import 'channel_filters.dart';

/// §085 R3 — view-model для node-filter UI на главном экране.
///
/// Владеет **всем** filter-state, который раньше жил 17 полями + 11 методами
/// прямо в `_HomeScreenState` (God-object). `ChangeNotifier`: home_screen
/// подписывается и делает `setState` на `notifyListeners`.
///
/// Состоит из (см. §048 / §083):
/// - **pool filter**: [showDetour] (показывать ли detour-сервера вообще);
/// - **match filters**: regex (+enabled/invert), protocols, subscriptions,
///   ping — помечают ноды matching/non-matching;
/// - **visibility**: [showNonMatching] (dimmed внизу vs скрыты);
/// - **per-channel memory** (§083): снимок match-фильтров на канал,
///   save/restore при смене канала через [syncChannel].
///
/// `showDetour` / `showNonMatching` — глобальные (не входят в per-channel
/// снимок); match-фильтры — per-channel.
class NodeFilterViewModel extends ChangeNotifier {
  // ─── UI ───────────────────────────────────────────────────────────────
  bool _panelExpanded = false;
  bool get panelExpanded => _panelExpanded;
  void togglePanel() {
    _panelExpanded = !_panelExpanded;
    notifyListeners();
  }

  // ─── Pool / visibility (глобальные) ─────────────────────────────────────
  bool _showDetour = true;
  bool get showDetour => _showDetour;
  void setShowDetour(bool v) {
    _showDetour = v;
    notifyListeners();
  }

  bool _showNonMatching = true;
  bool get showNonMatching => _showNonMatching;
  void setShowNonMatching(bool v) {
    _showNonMatching = v;
    notifyListeners();
  }

  // ─── Regex (debounced 300ms) ───────────────────────────────────────────
  final TextEditingController regexController = TextEditingController();
  RegExp? _regexCompiled;
  bool _regexValid = true;
  bool _regexEnabled = false;
  bool _regexInvert = false;
  Timer? _regexTimer;

  bool get regexValid => _regexValid;
  bool get regexEnabled => _regexEnabled;
  bool get regexInvert => _regexInvert;

  /// Скомпилированный regex для predicate'а — `null` если filter выключен /
  /// пустой / invalid.
  RegExp? get activeRegex => _regexEnabled ? _regexCompiled : null;

  void onRegexChanged(String text) {
    _regexTimer?.cancel();
    _regexTimer = Timer(const Duration(milliseconds: 300), () {
      if (_disposed) return;
      if (text.isEmpty) {
        _regexCompiled = null;
        _regexValid = true;
      } else {
        try {
          _regexCompiled = RegExp(text, caseSensitive: false);
          _regexValid = true;
          _regexEnabled = true;
        } catch (_) {
          _regexCompiled = null;
          _regexValid = false;
        }
      }
      notifyListeners();
    });
  }

  void setRegexEnabled(bool v) {
    _regexEnabled = v;
    notifyListeners();
  }

  void setRegexInvert(bool v) {
    _regexInvert = v;
    notifyListeners();
  }

  void clearRegex() {
    regexController.clear();
    _regexTimer?.cancel();
    _regexCompiled = null;
    _regexValid = true;
    _regexEnabled = false;
    _regexInvert = false;
    notifyListeners();
  }

  /// Tap по emoji-chip'у — append OR-pattern (`|emoji`) к regex field.
  void onEmojiChipTap(String emoji) {
    final current = regexController.text;
    final next = current.isEmpty ? emoji : '$current|$emoji';
    regexController.text = next;
    regexController.selection =
        TextSelection.collapsed(offset: regexController.text.length);
    onRegexChanged(next);
  }

  // ─── Protocols / subscriptions (multi-select chips) ─────────────────────
  final Set<String> enabledProtocols = <String>{};
  final Set<String> enabledSubscriptions = <String>{};

  void toggleProtocol(String proto) {
    if (!enabledProtocols.add(proto)) enabledProtocols.remove(proto);
    notifyListeners();
  }

  void toggleSubscription(String id) {
    if (!enabledSubscriptions.add(id)) enabledSubscriptions.remove(id);
    notifyListeners();
  }

  // ─── Ping / Test (debounced 300ms) ─────────────────────────────────────
  final TextEditingController pingController = TextEditingController();
  int? _maxPingMs;
  bool _pingEnabled = false;
  Timer? _pingTimer;

  bool get pingEnabled => _pingEnabled;

  /// Порог ping для predicate'а — `null` если filter выключен / не задан.
  int? get activeMaxPingMs => _pingEnabled ? _maxPingMs : null;

  void onPingChanged(String text) {
    _pingTimer?.cancel();
    _pingTimer = Timer(const Duration(milliseconds: 300), () {
      if (_disposed) return;
      final n = int.tryParse(text);
      _maxPingMs = (n != null && n > 0) ? n : null;
      if (_maxPingMs != null) _pingEnabled = true;
      notifyListeners();
    });
  }

  void setPingEnabled(bool v) {
    _pingEnabled = v;
    notifyListeners();
  }

  void clearPing() {
    pingController.clear();
    _pingTimer?.cancel();
    _maxPingMs = null;
    _pingEnabled = false;
    notifyListeners();
  }

  // ─── Активность (для visual hint на `Icons.tune`) ──────────────────────
  bool get isActive =>
      (_regexEnabled && _regexCompiled != null) ||
      enabledProtocols.isNotEmpty ||
      enabledSubscriptions.isNotEmpty ||
      (_pingEnabled && _maxPingMs != null);

  // ─── Per-channel memory (§083) ─────────────────────────────────────────
  final Map<String, ChannelFilters> _byChannel = {};
  String? _activeChannel;

  ChannelFilters _capture() => ChannelFilters(
        regexPattern: regexController.text,
        regexEnabled: _regexEnabled,
        regexInvert: _regexInvert,
        protocols: Set.of(enabledProtocols),
        subscriptions: Set.of(enabledSubscriptions),
        pingText: pingController.text,
        pingEnabled: _pingEnabled,
      );

  void _restore(ChannelFilters f) {
    _regexTimer?.cancel();
    _pingTimer?.cancel();
    regexController.text = f.regexPattern;
    if (f.regexPattern.isEmpty) {
      _regexCompiled = null;
      _regexValid = true;
    } else {
      try {
        _regexCompiled = RegExp(f.regexPattern, caseSensitive: false);
        _regexValid = true;
      } catch (_) {
        _regexCompiled = null;
        _regexValid = false;
      }
    }
    _regexEnabled = f.regexEnabled;
    _regexInvert = f.regexInvert;
    enabledProtocols
      ..clear()
      ..addAll(f.protocols);
    enabledSubscriptions
      ..clear()
      ..addAll(f.subscriptions);
    pingController.text = f.pingText;
    final n = int.tryParse(f.pingText);
    _maxPingMs = (n != null && n > 0) ? n : null;
    _pingEnabled = f.pingEnabled;
  }

  /// §083 — реакция на смену канала: save фильтров старого, restore нового.
  /// Покрывает все пути (dropdown, connect-time resolve, applyGroup).
  /// `notifyListeners` только если что-то изменилось.
  void syncChannel(String? channel) {
    if (channel == _activeChannel) return;
    final prev = _activeChannel;
    if (prev != null) {
      final snap = _capture();
      if (snap.isEmpty) {
        _byChannel.remove(prev);
      } else {
        _byChannel[prev] = snap;
      }
    }
    if (channel == null) {
      _activeChannel = null;
      return;
    }
    _restore(_byChannel[channel] ?? ChannelFilters.empty);
    _activeChannel = channel;
    notifyListeners();
  }

  // ─── Lifecycle ─────────────────────────────────────────────────────────
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _regexTimer?.cancel();
    _pingTimer?.cancel();
    regexController.dispose();
    pingController.dispose();
    super.dispose();
  }
}
