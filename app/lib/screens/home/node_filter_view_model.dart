import 'dart:async';

import 'package:flutter/widgets.dart';

import 'direction_filters.dart';

/// §085 R3 — view-model для node-filter UI на главном экране.
///
/// Владеет **всем** filter-state, который раньше жил 17 полями + 11 методами
/// прямо в `_HomeScreenState` (God-object). `ChangeNotifier`: home_screen
/// подписывается и делает `setState` на `notifyListeners`.
///
/// Состоит из (см. §048 / §083 / §096):
/// - **pool filter**: detour (§096) — чекбокс [detourEnabled] (выкл = показать
///   всё, старт) + `!` [detourHide]: ON = скрыть detour, OFF = только detour;
/// - **match filters**: regex (+invert), protocols (+invert), variants
///   (transport/security теги, §103, +invert), subscriptions (+invert),
///   ping — помечают ноды matching/non-matching; у каждой категории
///   единый `!`-negate (§096);
/// - **visibility**: [showNonMatching] (dimmed внизу vs скрыты);
/// - **per-direction memory** (§083): снимок match-фильтров на Направление,
///   save/restore при смене Направления через [syncDirection].
///
/// Detour-фильтр / `showNonMatching` — глобальные (не входят в per-direction
/// снимок); match-фильтры (+их invert) — per-direction.
class NodeFilterViewModel extends ChangeNotifier {
  // ─── UI ───────────────────────────────────────────────────────────────
  bool _panelExpanded = false;
  bool get panelExpanded => _panelExpanded;
  void togglePanel() {
    _panelExpanded = !_panelExpanded;
    notifyListeners();
  }

  // ─── Pool: detour (§096, чекбокс-enable + `!`, глобальный) ──────────────
  // Чекбокс [_detourEnabled]: ВЫКЛ (СТАРТ) → показать ВСЁ (фильтр off, `!`
  // неважен); ВКЛ → фильтровать. `!` [_detourHide] (когда enabled): ON →
  // скрыть detour (только non-detour); OFF → показать ТОЛЬКО detour.
  bool _detourEnabled = false;
  bool _detourHide = true;
  bool get detourEnabled => _detourEnabled;
  bool get detourHide => _detourHide;

  void setDetourEnabled(bool v) {
    _detourEnabled = v;
    notifyListeners();
  }

  void toggleDetourHide() {
    _detourHide = !_detourHide;
    notifyListeners();
  }

  /// Pool-предикат: фильтр off → всё проходит; иначе hide → проходят non-detour,
  /// show-only → проходят detour.
  bool detourPoolPasses(bool isDetour) =>
      !_detourEnabled || (_detourHide ? !isDetour : isDetour);

  /// Detour-фильтр включён — зажигает точку на табе/кнопке + чип-сводку.
  /// Дефолт (выкл = показать всё) точку НЕ зажигает.
  bool get detourActive => _detourEnabled;

  /// «Только detour» (`!` off при enabled) — для иконки чипа: только-detour
  /// (⚙) vs скрыть-detour (⊘).
  bool get detourOnly => _detourEnabled && !_detourHide;

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

  // ─── Protocols / variants / subscriptions (multi-select + §096 invert) ──
  final Set<String> enabledProtocols = <String>{};
  final Set<String> enabledVariants = <String>{};
  final Set<String> enabledSubscriptions = <String>{};
  bool _protocolsInvert = false;
  bool _variantsInvert = false;
  bool _subscriptionsInvert = false;
  bool get protocolsInvert => _protocolsInvert;
  bool get variantsInvert => _variantsInvert;
  bool get subscriptionsInvert => _subscriptionsInvert;

  void toggleProtocol(String proto) {
    if (!enabledProtocols.add(proto)) enabledProtocols.remove(proto);
    notifyListeners();
  }

  void toggleProtocolsInvert() {
    _protocolsInvert = !_protocolsInvert;
    notifyListeners();
  }

  /// §103 — transport/security теги (`tcp`/`ws`/`xhttp`/…/`TLS`/`Reality`/
  /// `awg2`) — вторая строка чипов под протоколами, та же §096-семантика.
  void toggleVariant(String v) {
    if (!enabledVariants.add(v)) enabledVariants.remove(v);
    notifyListeners();
  }

  void toggleVariantsInvert() {
    _variantsInvert = !_variantsInvert;
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
  /// при capture, чтобы не плодить orphan-записи per-direction (см. [_capture]).
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
  bool get variantActive => enabledVariants.isNotEmpty;
  bool get subscriptionActive => enabledSubscriptions.isNotEmpty;
  bool get pingActive => _pingEnabled && _maxPingMs != null;

  /// Любой активный match-фильтр.
  bool get isActive =>
      regexActive ||
      protocolActive ||
      variantActive ||
      subscriptionActive ||
      pingActive;

  /// Non-matching скрыты visibility-тоглом (для чипа-сводки + точки Settings).
  bool get nonMatchingHidden => !_showNonMatching;

  /// Settings-таб активен (ping ИЛИ detour-фильтр вкл ИЛИ non-matching скрыты).
  /// Дефолт (detour-фильтр выкл = показать всё) точку НЕ зажигает.
  bool get settingsActive => pingActive || detourActive || nonMatchingHidden;

  /// Любой применённый фильтр (match ИЛИ detour ИЛИ visibility) — точка на
  /// кнопке `Icons.tune` в закрытом режиме.
  bool get hasActiveFilters => isActive || detourActive || nonMatchingHidden;

  // ─── Per-direction memory (§083) ─────────────────────────────────────────
  final Map<String, DirectionFilters> _byDirection = {};
  String? _activeDirection;

  /// Дефолтное «200» при выключенном чекбоксе = «ping-фильтр не настроен».
  bool get _pingIsDefault =>
      !_pingEnabled && pingController.text == defaultPingText;

  DirectionFilters _capture() => DirectionFilters(
        regexPattern: regexController.text,
        regexInvert: _regexInvert,
        protocols: Set.of(enabledProtocols),
        protocolsInvert: _protocolsInvert,
        variants: Set.of(enabledVariants),
        variantsInvert: _variantsInvert,
        subscriptions: Set.of(enabledSubscriptions),
        subscriptionsInvert: _subscriptionsInvert,
        // дефолт «200» (disabled) → '' чтобы Направление считалось пустым (no orphan).
        pingText: _pingIsDefault ? '' : pingController.text,
        pingEnabled: _pingEnabled,
      );

  void _restore(DirectionFilters f) {
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
    enabledVariants
      ..clear()
      ..addAll(f.variants);
    _variantsInvert = f.variantsInvert;
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

  /// §083 — реакция на смену Направления: save фильтров старого, restore нового.
  /// Покрывает все пути (dropdown, connect-time resolve, applyGroup).
  /// `notifyListeners` только если что-то изменилось.
  void syncDirection(String? direction) {
    if (direction == _activeDirection) return;
    final prev = _activeDirection;
    if (prev != null) {
      final snap = _capture();
      if (snap.isEmpty) {
        _byDirection.remove(prev);
      } else {
        _byDirection[prev] = snap;
      }
    }
    if (direction == null) {
      _activeDirection = null;
      return;
    }
    _restore(_byDirection[direction] ?? DirectionFilters.empty);
    _activeDirection = direction;
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
