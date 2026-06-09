import 'dart:async';

import 'package:flutter/widgets.dart';

import 'channel_filters.dart';

/// §085 R3 — view-model для node-filter UI на главном экране.
///
/// Владеет **всем** filter-state, который раньше жил 17 полями + 11 методами
/// прямо в `_HomeScreenState` (God-object). `ChangeNotifier`: home_screen
/// подписывается и делает `setState` на `notifyListeners`.
///
/// Состоит из (см. §048 / §083 / §096):
/// - **pool filter**: detour ([detourHide], §096 бинарный) — `!` ON (дефолт)
///   = скрыть detour (только non-detour), `!` OFF = показать только detour;
/// - **match filters**: regex (+invert), protocols (+invert), subscriptions
///   (+invert), ping — помечают ноды matching/non-matching; у каждой категории
///   единый `!`-negate (§096);
/// - **visibility**: [showNonMatching] (dimmed внизу vs скрыты);
/// - **per-channel memory** (§083): снимок match-фильтров на канал,
///   save/restore при смене канала через [syncChannel].
///
/// Detour-фильтр / `showNonMatching` — глобальные (не входят в per-channel
/// снимок); match-фильтры (+их invert) — per-channel.
class NodeFilterViewModel extends ChangeNotifier {
  // ─── UI ───────────────────────────────────────────────────────────────
  bool _panelExpanded = false;
  bool get panelExpanded => _panelExpanded;
  void togglePanel() {
    _panelExpanded = !_panelExpanded;
    notifyListeners();
  }

  // ─── Pool: detour (§096, бинарный `!`, глобальный) ──────────────────────
  // `!` ON (дефолт) → скрыть detour (только non-detour, чистый список);
  // `!` OFF → показать ТОЛЬКО detour (диагностика разрыва цепочки).
  // «Show all» состояния нет — detour либо скрыт, либо изолирован.
  bool _detourHide = true;
  bool get detourHide => _detourHide;
  void toggleDetourHide() {
    _detourHide = !_detourHide;
    notifyListeners();
  }

  /// Pool-предикат по detour-флагу ноды: hide → проходят non-detour;
  /// show-only → проходят detour.
  bool detourPoolPasses(bool isDetour) => _detourHide ? !isDetour : isDetour;

  /// «Только detour» — особый диагностический режим (не дефолт): зажигает
  /// точку на табе/кнопке + чип-сводку. Дефолтное скрытие detour — нормальный
  /// режим, точку НЕ зажигает.
  bool get detourOnly => !_detourHide;

  // ─── Visibility (глобальный) ────────────────────────────────────────────
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
  bool _regexInvert = false;
  Timer? _regexTimer;

  bool get regexValid => _regexValid;
  bool get regexInvert => _regexInvert;

  /// §096 — regex активен пока поле непустое и валидно: enable-галку убрали, её
  /// слот занял `!`-negate. `_regexCompiled` уже `null` при пустом/невалидном
  /// паттерне, поэтому отдельный enable-gate не нужен.
  RegExp? get activeRegex => _regexCompiled;

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
        } catch (_) {
          _regexCompiled = null;
          _regexValid = false;
        }
      }
      notifyListeners();
    });
  }

  void toggleRegexInvert() {
    _regexInvert = !_regexInvert;
    notifyListeners();
  }

  void clearRegex() {
    regexController.clear();
    _regexTimer?.cancel();
    _regexCompiled = null;
    _regexValid = true;
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

  // ─── Protocols / subscriptions (multi-select chips + §096 invert) ───────
  final Set<String> enabledProtocols = <String>{};
  final Set<String> enabledSubscriptions = <String>{};
  bool _protocolsInvert = false;
  bool _subscriptionsInvert = false;
  bool get protocolsInvert => _protocolsInvert;
  bool get subscriptionsInvert => _subscriptionsInvert;

  void toggleProtocol(String proto) {
    if (!enabledProtocols.add(proto)) enabledProtocols.remove(proto);
    notifyListeners();
  }

  void toggleProtocolsInvert() {
    _protocolsInvert = !_protocolsInvert;
    notifyListeners();
  }

  void toggleSubscription(String id) {
    if (!enabledSubscriptions.add(id)) enabledSubscriptions.remove(id);
    notifyListeners();
  }

  void toggleSubscriptionsInvert() {
    _subscriptionsInvert = !_subscriptionsInvert;
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
  bool get regexActive => _regexCompiled != null;
  bool get protocolActive => enabledProtocols.isNotEmpty;
  bool get subscriptionActive => enabledSubscriptions.isNotEmpty;
  bool get pingActive => _pingEnabled && _maxPingMs != null;

  /// Любой активный match-фильтр.
  bool get isActive =>
      regexActive || protocolActive || subscriptionActive || pingActive;

  /// Non-matching скрыты visibility-тоглом (для чипа-сводки + точки Settings).
  bool get nonMatchingHidden => !_showNonMatching;

  /// Settings-таб активен (ping ИЛИ «только detour» ИЛИ non-matching скрыты).
  /// Дефолтное скрытие detour точку НЕ зажигает (это нормальный режим).
  bool get settingsActive => pingActive || detourOnly || nonMatchingHidden;

  /// Любой применённый фильтр (match ИЛИ «только detour» ИЛИ visibility) —
  /// точка на кнопке `Icons.tune` в закрытом режиме.
  bool get hasActiveFilters => isActive || detourOnly || nonMatchingHidden;

  // ─── Per-channel memory (§083) ─────────────────────────────────────────
  final Map<String, ChannelFilters> _byChannel = {};
  String? _activeChannel;

  /// Дефолтное «200» при выключенном чекбоксе = «ping-фильтр не настроен».
  bool get _pingIsDefault =>
      !_pingEnabled && pingController.text == defaultPingText;

  ChannelFilters _capture() => ChannelFilters(
        regexPattern: regexController.text,
        regexInvert: _regexInvert,
        protocols: Set.of(enabledProtocols),
        protocolsInvert: _protocolsInvert,
        subscriptions: Set.of(enabledSubscriptions),
        subscriptionsInvert: _subscriptionsInvert,
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
    _regexInvert = f.regexInvert;
    enabledProtocols
      ..clear()
      ..addAll(f.protocols);
    _protocolsInvert = f.protocolsInvert;
    enabledSubscriptions
      ..clear()
      ..addAll(f.subscriptions);
    _subscriptionsInvert = f.subscriptionsInvert;
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
