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

  /// Tap по emoji-chip'у — **toggle** в OR-паттерне regex: нет → добавить,
  /// есть → убрать. Подсветка выбранных — через [selectedEmojis].
  void onEmojiChipTap(String emoji) {
    final parts =
        regexController.text.split('|').where((p) => p.isNotEmpty).toList();
    if (!parts.remove(emoji)) parts.add(emoji);
    final next = parts.join('|');
    regexController.text = next;
    regexController.selection = TextSelection.collapsed(offset: next.length);
    notifyListeners(); // мгновенная подсветка чипа (recompile — debounced ниже)
    onRegexChanged(next);
  }

  /// Эмодзи, присутствующие в regex-паттерне (OR-термы) — для подсветки чипов.
  Set<String> get selectedEmojis =>
      regexController.text.split('|').where((p) => p.isNotEmpty).toSet();

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
  /// §095 — поле ping предзаполнено реальным «200» (не placeholder), но чекбокс
  /// выключен: значение видно как настоящее, а не серый hint, при этом фильтр
  /// не активен пока юзер его не включит. Дефолт нормализуется обратно в «пусто»
  /// при capture, чтобы не плодить orphan-записи per-channel (см. [_capture]).
  static const defaultPingText = '200';

  final TextEditingController pingController =
      TextEditingController(text: defaultPingText);
  int? _maxPingMs = int.tryParse(defaultPingText);
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

  // ─── Активность (per-category — для точек на табах + сводки) ────────────
  bool get regexActive => _regexEnabled && _regexCompiled != null;
  bool get protocolActive => enabledProtocols.isNotEmpty;
  bool get subscriptionActive => enabledSubscriptions.isNotEmpty;
  bool get pingActive => _pingEnabled && _maxPingMs != null;

  /// Любой активный match-фильтр.
  bool get isActive =>
      regexActive || protocolActive || subscriptionActive || pingActive;

  /// «Скрыто» visibility-тоглами (для чипов-сводки + точки Settings-таба).
  bool get detourHidden => !_showDetour;
  bool get nonMatchingHidden => !_showNonMatching;

  /// Settings-таб активен (ping ИЛИ что-то скрыто visibility-тоглами).
  bool get settingsActive => pingActive || detourHidden || nonMatchingHidden;

  /// Любой применённый фильтр (match ИЛИ visibility) — точка на кнопке
  /// `Icons.tune` в закрытом режиме.
  bool get hasActiveFilters => isActive || detourHidden || nonMatchingHidden;

  // ─── Per-channel memory (§083) ─────────────────────────────────────────
  final Map<String, ChannelFilters> _byChannel = {};
  String? _activeChannel;

  /// Дефолтное «200» при выключенном чекбоксе = «ping-фильтр не настроен».
  bool get _pingIsDefault =>
      !_pingEnabled && pingController.text == defaultPingText;

  ChannelFilters _capture() => ChannelFilters(
        regexPattern: regexController.text,
        regexEnabled: _regexEnabled,
        regexInvert: _regexInvert,
        protocols: Set.of(enabledProtocols),
        subscriptions: Set.of(enabledSubscriptions),
        // дефолт «200» (disabled) → '' чтобы канал считался пустым (no orphan).
        pingText: _pingIsDefault ? '' : pingController.text,
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
    // пустой снимок → дефолтное «200» (disabled), иначе сохранённое значение.
    final restoredPing = f.pingText.isEmpty ? defaultPingText : f.pingText;
    pingController.text = restoredPing;
    final n = int.tryParse(restoredPing);
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
