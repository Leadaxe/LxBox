import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../models/custom_rule.dart';
import '../../models/parser_config.dart';
import '../../services/rule_set_downloader.dart';
import '../../widgets/wifi_entry.dart';
import 'normalizers.dart' as norm;
import 'sections/srs_section.dart' show SrsDownloadState;
import 'wifi_zip.dart';

export 'sections/srs_section.dart' show SrsDownloadState;

/// §053 Stage 3 — единая точка истины для editor'а custom-правила.
///
/// До Stage 3 весь state жил в `_CustomRuleEditScreenState` (1330 LOC).
/// Sections принимали controllers + callbacks как props напрямую от
/// editor'а. Stage 3 выделяет state в `ChangeNotifier`, который раздаётся
/// вниз через `CustomRuleEditScope` (InheritedNotifier). Editor scaffold
/// больше ничего о state не знает — только AppBar + Tab + dispose.
///
/// **Что владеет controller:**
/// - 8 `TextEditingController` (name + 6 match-полей + srs URL). При
///   создании read'аются из `initial`, на keystroke forward'ятся в
///   `notifyListeners` чтобы AppBar Save-icon и параметрические tab'ы
///   могли пересчитывать `isDirty`.
/// - All flags / collections (enabled, kind, outbound, protocols, packages,
///   wifiNetworks, varsValues, ipIsPrivate).
/// - Async state: `srsState`, `presetSrsPaths`, `boolVarDownloading`.
/// - `snapshot()` / `isDirty()` — pure read из текущего state.
/// - Pure async actions без BuildContext: `downloadSrs`, `clearSrsCache`,
///   `onBoolVarToggle` (нет UI-side-effect'ов кроме mutate+notify; вызов
///   snackbar/dialog — на caller'е).
///
/// **Что НЕ владеет controller:** ничего что нужно BuildContext —
/// dialog'и save/back/delete, picker'ы, snackbar'ы, navigation.
/// Эти живут на screen State и принимают controller как dependency.
class CustomRuleEditController extends ChangeNotifier {
  CustomRuleEditController({
    required this.initial,
    required this.preset,
    required this.existingNames,
  }) {
    _init();
  }

  /// Исходное правило (до open editor'а). На save сравнивается со
  /// `snapshot()` для dirty-check. Также — источник `id` (rule id не
  /// меняется через editor).
  final CustomRule initial;

  /// Bundle-пресет (§033). Не-null когда `initial.kind == preset` И
  /// пресет ещё существует в шаблоне. Null = broken preset (rule
  /// рендерит fallback UI с Delete).
  final SelectableRule? preset;

  /// Имена существующих правил (для auto-rename при коллизии). Не
  /// включает `initial.name` — собирается RoutingScreen'ом.
  final Set<String> existingNames;

  // ─── Text controllers ────────────────────────────────────────────────

  late final TextEditingController nameCtrl;
  late final TextEditingController domainCtrl;
  late final TextEditingController domainSuffixCtrl;
  late final TextEditingController domainKeywordCtrl;
  late final TextEditingController ipCidrCtrl;
  late final TextEditingController portCtrl;
  late final TextEditingController portRangeCtrl;
  late final TextEditingController srsUrlCtrl;

  // ─── Mutable state ───────────────────────────────────────────────────

  late bool _enabled;
  late bool _ipIsPrivate;
  late CustomRuleKind _kind;
  late String _outbound;
  late Set<String> _protocols;
  late List<String> _packages;
  late List<WifiEntry> _wifiNetworks;
  late Map<String, String> _varsValues;
  Map<String, String> _presetSrsPaths = const {};
  SrsDownloadState _srsState = SrsDownloadState.none;
  final Set<String> _boolVarDownloading = <String>{};

  bool _disposed = false;

  // ─── Getters ─────────────────────────────────────────────────────────

  bool get enabled => _enabled;
  bool get ipIsPrivate => _ipIsPrivate;
  CustomRuleKind get kind => _kind;
  String get outbound => _outbound;
  Set<String> get protocols => _protocols;
  List<String> get packages => _packages;
  List<WifiEntry> get wifiNetworks => _wifiNetworks;
  Map<String, String> get varsValues => _varsValues;
  Map<String, String> get presetSrsPaths => _presetSrsPaths;
  SrsDownloadState get srsState => _srsState;
  Set<String> get boolVarDownloading => _boolVarDownloading;

  // ─── Init / dispose ──────────────────────────────────────────────────

  List<TextEditingController> get _allTextCtrls => [
        nameCtrl,
        domainCtrl,
        domainSuffixCtrl,
        domainKeywordCtrl,
        ipCidrCtrl,
        portCtrl,
        portRangeCtrl,
        srsUrlCtrl,
      ];

  void _init() {
    final r = initial;
    nameCtrl = TextEditingController(text: r.name);
    domainCtrl = TextEditingController(text: r.domains.join('\n'));
    domainSuffixCtrl =
        TextEditingController(text: r.domainSuffixes.join('\n'));
    domainKeywordCtrl =
        TextEditingController(text: r.domainKeywords.join('\n'));
    ipCidrCtrl = TextEditingController(text: r.ipCidrs.join('\n'));
    portCtrl = TextEditingController(text: r.ports.join('\n'));
    portRangeCtrl = TextEditingController(text: r.portRanges.join('\n'));
    srsUrlCtrl = TextEditingController(text: r.srsUrl);
    _enabled = r.enabled;
    _ipIsPrivate = r.ipIsPrivate;
    _kind = r.kind;
    _outbound = r.outbound;
    _protocols = r.protocols.toSet();
    _packages = List.of(r.packages);
    _wifiNetworks = unzipWifiEntries(r.wifiSsids, r.wifiBssids);
    _varsValues = Map<String, String>.from(r.varsValues);

    // Forward text changes — AppBar Save-icon (dirty indicator) и
    // tab'ы re-evaluate isDirty / снимок при каждом keystroke.
    for (final c in _allTextCtrls) {
      c.addListener(_onTextChanged);
    }

    if (_kind == CustomRuleKind.srs) {
      RuleSetDownloader.isCached(r.id).then((cached) {
        if (_disposed) return;
        _srsState =
            cached ? SrsDownloadState.cached : SrsDownloadState.none;
        notifyListeners();
      });
    }
    if (r is CustomRulePreset && preset != null) {
      _resolvePresetSrsPaths(r, preset!);
    }
  }

  void _onTextChanged() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Async-prefetch cached paths для remote rule_set'ов пресета (§011).
  /// Без этого View tab показывал бы warnings «no cached file» для
  /// уже скачанного пресета.
  Future<void> _resolvePresetSrsPaths(
      CustomRulePreset rule, SelectableRule preset) async {
    final paths = <String, String>{};
    for (final rs in preset.ruleSets) {
      if (rs['type'] != 'remote') continue;
      final tag = rs['tag'];
      if (tag is! String || tag.isEmpty) continue;
      final p =
          await RuleSetDownloader.cachedPathForPreset(rule.presetId, tag);
      if (p != null) paths[tag] = p;
    }
    if (_disposed) return;
    _presetSrsPaths = paths;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final c in _allTextCtrls) {
      c.removeListener(_onTextChanged);
      c.dispose();
    }
    super.dispose();
  }

  // ─── Mutators ────────────────────────────────────────────────────────

  void setEnabled(bool v) {
    if (_enabled == v) return;
    _enabled = v;
    notifyListeners();
  }

  void setIpIsPrivate(bool v) {
    if (_ipIsPrivate == v) return;
    _ipIsPrivate = v;
    notifyListeners();
  }

  void setKind(CustomRuleKind v) {
    if (_kind == v) return;
    _kind = v;
    // Переключение на srs без кэша → правило нельзя держать включённым.
    if (_kind == CustomRuleKind.srs &&
        _srsState != SrsDownloadState.cached) {
      _enabled = false;
    }
    notifyListeners();
  }

  void setOutbound(String v) {
    if (_outbound == v) return;
    _outbound = v;
    notifyListeners();
  }

  void toggleProtocol(String p, bool checked) {
    if (checked) {
      if (!_protocols.add(p)) return;
    } else {
      if (!_protocols.remove(p)) return;
    }
    notifyListeners();
  }

  void setPackages(List<String> v) {
    _packages = v;
    notifyListeners();
  }

  void addWifiEntry(WifiEntry e) {
    if (_wifiNetworks.any((x) => x.ssid == e.ssid && x.bssid == e.bssid)) {
      return;
    }
    _wifiNetworks.add(e);
    notifyListeners();
  }

  /// Bulk-add (для Pick saved): возвращает кол-во реально добавленных
  /// (с учётом дедупа).
  int addWifiEntries(Iterable<WifiEntry> entries) {
    var added = 0;
    for (final e in entries) {
      if (_wifiNetworks
          .any((x) => x.ssid == e.ssid && x.bssid == e.bssid)) {
        continue;
      }
      _wifiNetworks.add(e);
      added++;
    }
    if (added > 0) notifyListeners();
    return added;
  }

  void removeWifiAt(int i) {
    _wifiNetworks.removeAt(i);
    notifyListeners();
  }

  void setVarValue(String name, String val) {
    _varsValues[name] = val;
    notifyListeners();
  }

  // ─── SRS download (used by SrsSection cloud-button) ──────────────────

  Future<void> downloadSrs() async {
    final url = srsUrlCtrl.text.trim();
    if (url.isEmpty) return;
    _srsState = SrsDownloadState.loading;
    notifyListeners();
    final path = await RuleSetDownloader.download(initial.id, url);
    if (_disposed) return;
    _srsState =
        path != null ? SrsDownloadState.cached : SrsDownloadState.error;
    notifyListeners();
  }

  /// Cloud-menu «Clear cached file»: удаляет локальный `.srs`, не
  /// трогая правило в storage. _enabled сбрасывается — без cache
  /// правило не может работать.
  Future<void> clearSrsCache() async {
    await RuleSetDownloader.delete(initial.id);
    if (_disposed) return;
    _srsState = SrsDownloadState.none;
    _enabled = false;
    notifyListeners();
  }

  /// На URL-edit: если состояние было `error`, сбрасываем в `none`
  /// (юзер начал править — пусть не висит красная иконка).
  void resetSrsErrorIfAny() {
    if (_srsState != SrsDownloadState.error) return;
    _srsState = SrsDownloadState.none;
    notifyListeners();
  }

  // ─── §045 bool-var toggle (preset rendering) ─────────────────────────

  /// Toggle bool-var. Если var управляет remote rule_set'ом
  /// (`enabled: "@<v.name>"` convention в шаблоне) — toggle-on
  /// auto-downloads .srs; на fail toggle откатывается и метод
  /// возвращает `true` (caller покажет snackbar).
  ///
  /// Toggle-off — без downloads, всегда `false`.
  Future<bool> onBoolVarToggle(WizardVar v, bool val) async {
    final p = preset;
    if (p == null) return false;

    if (!val) {
      _varsValues[v.name] = 'false';
      notifyListeners();
      return false;
    }

    final controlled = p.ruleSets.where((rs) {
      final raw = rs['enabled'];
      return raw is String && raw == '@${v.name}';
    }).toList();

    if (controlled.isEmpty) {
      _varsValues[v.name] = 'true';
      notifyListeners();
      return false;
    }

    final initial = this.initial;
    final presetId =
        initial is CustomRulePreset ? initial.presetId : p.presetId;
    final missing = <_PendingDownload>[];
    for (final rs in controlled) {
      if (rs['type'] != 'remote') continue;
      final tag = rs['tag'];
      final url = rs['url'];
      if (tag is! String || tag.isEmpty) continue;
      if (url is! String || url.isEmpty) continue;
      final cached =
          await RuleSetDownloader.cachedPathForPreset(presetId, tag) != null;
      if (!cached) missing.add(_PendingDownload(tag: tag, url: url));
    }
    if (_disposed) return false;

    if (missing.isEmpty) {
      _varsValues[v.name] = 'true';
      _presetSrsPaths = {..._presetSrsPaths};
      notifyListeners();
      return false;
    }

    _boolVarDownloading.add(v.name);
    notifyListeners();

    final newPaths = <String, String>{};
    var anyFailed = false;
    for (final m in missing) {
      final path = await RuleSetDownloader.downloadForPreset(
          presetId, m.tag, m.url);
      if (path == null) {
        anyFailed = true;
      } else {
        newPaths[m.tag] = path;
      }
    }
    if (_disposed) return false;

    _boolVarDownloading.remove(v.name);
    if (!anyFailed) {
      _varsValues[v.name] = 'true';
      _presetSrsPaths = {..._presetSrsPaths, ...newPaths};
    }
    notifyListeners();
    return anyFailed;
  }

  // ─── Snapshot / dirty ────────────────────────────────────────────────

  /// Текущее состояние формы как `CustomRule`. Не валидирует name-
  /// collision (это делает `save` flow на screen State).
  CustomRule snapshot() {
    final name = nameCtrl.text.trim();
    switch (_kind) {
      case CustomRuleKind.preset:
        final init = initial;
        return CustomRulePreset(
          id: init.id,
          name: name,
          enabled: _enabled,
          presetId: init is CustomRulePreset ? init.presetId : '',
          varsValues: Map<String, String>.from(_varsValues),
        );
      case CustomRuleKind.srs:
        final wifi = zipWifiEntries(_wifiNetworks);
        return CustomRuleSrs(
          id: initial.id,
          name: name,
          enabled: _enabled,
          srsUrl: srsUrlCtrl.text.trim(),
          ports: norm.normalizedPorts(portCtrl.text),
          portRanges: norm.normalizedPortRanges(portRangeCtrl.text),
          packages: List.of(_packages),
          protocols: _protocols.toList()..sort(),
          ipIsPrivate: _ipIsPrivate,
          wifiSsids: wifi.ssids,
          wifiBssids: wifi.bssids,
          outbound: _outbound,
        );
      case CustomRuleKind.inline:
        final wifi = zipWifiEntries(_wifiNetworks);
        return CustomRuleInline(
          id: initial.id,
          name: name,
          enabled: _enabled,
          domains: norm.normalizedDomains(domainCtrl.text),
          domainSuffixes: norm.normalizedDomains(
              domainSuffixCtrl.text,
              stripLeadingDot: true),
          domainKeywords: norm.normalizedKeywords(domainKeywordCtrl.text),
          ipCidrs: norm.normalizedCidrs(ipCidrCtrl.text),
          ports: norm.normalizedPorts(portCtrl.text),
          portRanges: norm.normalizedPortRanges(portRangeCtrl.text),
          packages: List.of(_packages),
          protocols: _protocols.toList()..sort(),
          ipIsPrivate: _ipIsPrivate,
          wifiSsids: wifi.ssids,
          wifiBssids: wifi.bssids,
          outbound: _outbound,
        );
    }
  }

  bool isDirty() =>
      jsonEncode(snapshot().toJson()) != jsonEncode(initial.toJson());
}

/// §045: tag+url пара для batch download'а внутри `onBoolVarToggle`.
class _PendingDownload {
  const _PendingDownload({required this.tag, required this.url});
  final String tag;
  final String url;
}

/// §053 Stage 3 — InheritedNotifier для раздачи controller'а вниз по
/// tree без prop-drilling. Любой widget внутри `body` editor'а делает
/// `CustomRuleEditScope.of(context)` и подписывается на rebuild при
/// `notifyListeners`.
class CustomRuleEditScope extends InheritedNotifier<CustomRuleEditController> {
  const CustomRuleEditScope({
    super.key,
    required CustomRuleEditController super.notifier,
    required super.child,
  });

  static CustomRuleEditController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<CustomRuleEditScope>();
    assert(scope != null, 'CustomRuleEditScope.of: no scope in context');
    return scope!.notifier!;
  }

  /// Non-listening lookup — используй когда нужен только trigger
  /// action (mutator) без подписки на изменения.
  static CustomRuleEditController read(BuildContext context) {
    final scope = context
        .getInheritedWidgetOfExactType<CustomRuleEditScope>();
    assert(scope != null, 'CustomRuleEditScope.read: no scope in context');
    return scope!.notifier!;
  }
}
