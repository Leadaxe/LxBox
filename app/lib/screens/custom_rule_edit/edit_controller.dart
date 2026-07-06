import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../models/custom_rule.dart';
import '../../models/parser_config.dart';
import '../../services/builder/post_steps.dart' show templateDnsServersByTag;
import '../../services/rule_set_downloader.dart';
import '../../services/settings_storage.dart';
import '../../services/template_loader.dart';
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
  late final TextEditingController sourceIpCidrCtrl;
  late final TextEditingController portCtrl;
  late final TextEditingController portRangeCtrl;
  late final TextEditingController srsUrlCtrl;

  /// §225 — тело raw-JSON правила (kind == json).
  late final TextEditingController jsonCtrl;

  // ─── Mutable state ───────────────────────────────────────────────────

  late bool _enabled;
  late bool _ipIsPrivate;
  late bool _sourceIpIsPrivate;
  late Set<String> _inbounds;
  late CustomRuleKind _kind;
  late String _outbound;
  late Set<String> _protocols;
  late List<String> _packages;
  late List<WifiEntry> _wifiNetworks;
  late Map<String, String> _varsValues;
  late RuleDns? _dns;
  late RuleResolve? _resolve;
  List<String> _dnsServerTags = const [];

  /// §030/new_fields — есть ли в текущем vpn_mode `mixed-in` inbound (режимы
  /// proxy/vpn_proxy, §119). Гейтит чекбокс `Proxy interface` в INBOUND-секции.
  /// Читается async в `_init` через [SettingsStorage.getVpnMode].
  bool _hasMixedInbound = false;
  Map<String, String> _presetSrsPaths = const {};
  SrsDownloadState _srsState = SrsDownloadState.none;
  final Set<String> _boolVarDownloading = <String>{};

  bool _disposed = false;

  // ─── Getters ─────────────────────────────────────────────────────────

  bool get enabled => _enabled;
  bool get ipIsPrivate => _ipIsPrivate;
  bool get sourceIpIsPrivate => _sourceIpIsPrivate;

  /// §030/new_fields — выбранные inbound-теги (`tun-in`/`mixed-in`).
  Set<String> get inbounds => _inbounds;

  /// §030/new_fields — доступные inbound-варианты для INBOUND-секции. Лейбл
  /// человекочитаемый, значение = тег билдера (§119). `mixed-in` гейтится по
  /// текущему vpn_mode ([_hasMixedInbound]) — в tun-only его нет.
  List<({String tag, String label})> get inboundChoices => [
        (tag: 'tun-in', label: 'TUN — system interface'),
        if (_hasMixedInbound) (tag: 'mixed-in', label: 'Proxy interface'),
      ];

  CustomRuleKind get kind => _kind;
  String get outbound => _outbound;
  Set<String> get protocols => _protocols;
  List<String> get packages => _packages;
  List<WifiEntry> get wifiNetworks => _wifiNetworks;
  Map<String, String> get varsValues => _varsValues;
  Map<String, String> get presetSrsPaths => _presetSrsPaths;
  SrsDownloadState get srsState => _srsState;
  Set<String> get boolVarDownloading => _boolVarDownloading;

  /// §117 задача 3 — DNS-опция правила (null = не настраивалась).
  RuleDns? get dns => _dns;

  /// §247 — resolve-опция правила (null = обычный outbound).
  RuleResolve? get resolve => _resolve;

  /// §247: live-гейт применимости resolve — по ТЕКУЩЕМУ состоянию формы
  /// (не по initial). inline: domain-группа непуста (чистый ip/port/proto
  /// резолвить нечего → ⚙ скрыта); srs: всегда true (домены в `.srs`
  /// возможны, содержимое не парсим).
  bool get resolveEligible => switch (_kind) {
        CustomRuleKind.srs => true,
        CustomRuleKind.inline =>
          norm.normalizedDomains(domainCtrl.text).isNotEmpty ||
              norm
                  .normalizedDomains(domainSuffixCtrl.text,
                      stripLeadingDot: true)
                  .isNotEmpty ||
              norm.normalizedKeywords(domainKeywordCtrl.text).isNotEmpty,
        _ => false,
      };

  /// §117: теги существующих DNS-серверов для дропдауна (storage-refs ∪
  /// template; правило ссылается по tag, не вводит адрес — решение №2).
  List<String> get dnsServerTags => _dnsServerTags;

  /// §117 гейт: headless rule_set не выражает port/protocol (и они неизвестны
  /// в момент DNS-запроса) → DNS-чекбокс серый при непустых ports/protocols.
  /// Live по текущему состоянию формы.
  bool get dnsGateBlocked =>
      norm.normalizedPorts(portCtrl.text).isNotEmpty ||
      norm.normalizedPortRanges(portRangeCtrl.text).isNotEmpty ||
      _protocols.isNotEmpty;

  // ─── Init / dispose ──────────────────────────────────────────────────

  List<TextEditingController> get _allTextCtrls => [
        nameCtrl,
        domainCtrl,
        domainSuffixCtrl,
        domainKeywordCtrl,
        ipCidrCtrl,
        sourceIpCidrCtrl,
        portCtrl,
        portRangeCtrl,
        srsUrlCtrl,
        jsonCtrl,
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
    sourceIpCidrCtrl = TextEditingController(text: r.sourceIpCidrs.join('\n'));
    portCtrl = TextEditingController(text: r.ports.join('\n'));
    portRangeCtrl = TextEditingController(text: r.portRanges.join('\n'));
    srsUrlCtrl = TextEditingController(text: r.srsUrl);
    jsonCtrl = TextEditingController(text: r.json);
    _enabled = r.enabled;
    _ipIsPrivate = r.ipIsPrivate;
    _sourceIpIsPrivate = r.sourceIpIsPrivate;
    _inbounds = r.inbounds.toSet();
    _kind = r.kind;
    _outbound = r.outbound;
    _protocols = r.protocols.toSet();
    _packages = List.of(r.packages);
    _wifiNetworks = unzipWifiEntries(r.wifiSsids, r.wifiBssids);
    _varsValues = Map<String, String>.from(r.varsValues);
    _dns = r.dns;
    _resolve = r.resolve;
    unawaited(_loadDnsServerTags());
    unawaited(_loadVpnMode());

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
    // §247: сброс resolve при опустении доменных полей НЕ здесь — keystroke
    // транзиентен (юзер стирает домен, чтобы вписать новый; live-сброс терял
    // бы настройку безвозвратно). Гейт живёт в snapshot() (Save без доменов
    // → resolve отпадает) и в билдере (resolveActive); UI прячет ⚙/статус
    // через resolveEligible.
    notifyListeners();
  }

  /// §117: теги DNS-серверов для дропдауна — storage-refs (kind-ref'ы §043,
  /// синхронизируются на каждом build/DNS-screen open) ∪ template-серверы
  /// (fallback для свежей установки, где storage ещё пуст).
  Future<void> _loadDnsServerTags() async {
    final stored = await SettingsStorage.getDnsServers();
    final template = await TemplateLoader.load();
    final templateServers =
        (template.dnsOptions['servers'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((s) => Map<String, dynamic>.from(s))
            .toList();
    final tags = <String>{};
    for (final s in stored) {
      final tag = s['tag']?.toString();
      if (tag != null && tag.isNotEmpty) tags.add(tag);
    }
    tags.addAll(templateDnsServersByTag(templateServers).keys);
    if (_disposed) return;
    _dnsServerTags = tags.toList();
    notifyListeners();
  }

  /// §030/new_fields — читает текущий vpn_mode для гейта `mixed-in`-чекбокса
  /// в INBOUND-секции. `mixed-in` существует только в proxy/vpn_proxy (§119).
  Future<void> _loadVpnMode() async {
    final cfg = await SettingsStorage.getVpnMode();
    if (_disposed) return;
    _hasMixedInbound = cfg.hasMixed;
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

  void setSourceIpIsPrivate(bool v) {
    if (_sourceIpIsPrivate == v) return;
    _sourceIpIsPrivate = v;
    notifyListeners();
  }

  /// §030/new_fields — тоггл inbound-тега (`tun-in`/`mixed-in`).
  void toggleInbound(String tag, bool checked) {
    if (checked) {
      if (!_inbounds.add(tag)) return;
    } else {
      if (!_inbounds.remove(tag)) return;
    }
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
    // §247: resolve при смене kind НЕ сбрасываем — snapshot()-гейт не даст
    // ему попасть в неприменимый snapshot (json/preset его вообще не несут),
    // а round-trip inline→json→inline не теряет настройку.
    notifyListeners();
  }

  void setOutbound(String v) {
    if (_outbound == v) return;
    _outbound = v;
    notifyListeners();
  }

  /// §247 — установка resolve-опции из окна «Action & Resolve». null = снять
  /// (вернуться к простому outbound).
  void setResolve(RuleResolve? v) {
    _resolve = v;
    notifyListeners();
  }

  /// §225 — тело json-правила изменилось (jsonCtrl уже в _allTextCtrls, но
  /// нужен явный notify для live-пересчёта jsonError → helper/Save-гейт).
  void notifyJsonChanged() => notifyListeners();

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

  /// §117: тоггл DNS-опции. Выбранный serverTag сохраняется при выключении
  /// (повторное включение не теряет выбор). Первое включение без выбора —
  /// преселект `google_udp` (дефолтный резолвер) или первый доступный tag.
  void setDnsEnabled(bool v) {
    var tag = _dns?.serverTag ?? '';
    if (v && tag.isEmpty) {
      tag = _dnsServerTags.contains('google_udp')
          ? 'google_udp'
          : (_dnsServerTags.isNotEmpty ? _dnsServerTags.first : '');
    }
    _dns = RuleDns(enabled: v, serverTag: tag);
    notifyListeners();
  }

  /// §117: выбор DNS-сервера для mirror'а (по tag из существующих).
  void setDnsServerTag(String tag) {
    _dns = RuleDns(enabled: _dns?.enabled ?? false, serverTag: tag);
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
      case CustomRuleKind.json:
        return CustomRuleJson(
          id: initial.id,
          name: name,
          enabled: _enabled,
          json: jsonCtrl.text,
        );
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
          sourceIpCidrs: norm.normalizedCidrs(sourceIpCidrCtrl.text),
          sourceIpIsPrivate: _sourceIpIsPrivate,
          inbounds: _inbounds.toList()..sort(),
          wifiSsids: wifi.ssids,
          wifiBssids: wifi.bssids,
          outbound: _outbound,
          dns: _dns,
          // §247: гейт на случай snapshot до notify (сброс live в
          // _onTextChanged, но подстраховка дешёвая).
          resolve: resolveEligible ? _resolve : null,
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
          sourceIpCidrs: norm.normalizedCidrs(sourceIpCidrCtrl.text),
          sourceIpIsPrivate: _sourceIpIsPrivate,
          inbounds: _inbounds.toList()..sort(),
          wifiSsids: wifi.ssids,
          wifiBssids: wifi.bssids,
          outbound: _outbound,
          dns: _dns,
          resolve: resolveEligible ? _resolve : null, // §247
        );
    }
  }

  bool isDirty() =>
      jsonEncode(snapshot().toJson()) != jsonEncode(initial.toJson());

  /// §225 — валиден ли текущий текст json-правила (для inline-хелпера в
  /// JsonSection и гейта Save). `null` = ок (нет ошибки), иначе краткое
  /// описание. Пустой ввод считается «ещё не заполнено» (ошибка), т.к.
  /// сохранять пустое json-правило смысла нет.
  String? get jsonError {
    if (_kind != CustomRuleKind.json) return null;
    final text = jsonCtrl.text.trim();
    if (text.isEmpty) return 'Enter a JSON object or array of objects.';
    final dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return 'Invalid JSON.';
    }
    if (decoded is Map) return null;
    if (decoded is List) {
      if (decoded.isEmpty) return 'Array is empty.';
      if (decoded.every((e) => e is Map)) return null;
      return 'Array must contain only rule objects.';
    }
    return 'Expected an object or array of objects.';
  }
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
  // §141 P2.3i — `read()` (non-listening lookup) удалён: 0 call-sites.
}
