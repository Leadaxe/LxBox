part of '../routing_screen.dart';

/// SRS-cache / download оркестрация экрана Routing. Вынесено `part`'ом из
/// `routing_screen.dart` — это та же библиотека и тот же `_RoutingScreenState`,
/// так что поведение (setState/mounted/context/private-поля) идентично.
mixin _RoutingSrsCacheMixin on State<RoutingScreen>, LazyPersistMixin<RoutingScreen> {
  // Поля и хелперы предоставляет `_RoutingScreenState`; объявляем требуемую
  // поверхность абстрактно.
  Set<String> get _srsCached;
  Set<String> get _srsDownloading;
  List<CustomRule> get _customRules;
  Set<String> get _enabledGroups;
  Map<String, String> get _routingVarValues;
  set _template(WizardTemplate? value);
  String get _routeFinal;
  set _routeFinal(String value);
  set _loading(bool value);
  void _markDirty();
  SelectableRule? _presetFor(String presetId);
  List<PresetRemoteRuleSet> _remoteRuleSetsOf(
    SelectableRule preset, [
    CustomRulePreset? rule,
  ]);
  String _presetSrsKey(CustomRulePreset rule, String tag);
  bool _presetNeedsDownload(CustomRulePreset rule, SelectableRule preset);

  Future<void> _load() async {
    final template = await TemplateLoader.load();
    final storedGroups = await SettingsStorage.getEnabledGroups();
    final storedFinal = await SettingsStorage.getRouteFinal();
    final storedVars = await SettingsStorage.getAllVars();

    if (storedGroups.isEmpty) {
      for (final g in template.presetGroups) {
        if (g.defaultEnabled) _enabledGroups.add(g.tag);
      }
    } else {
      _enabledGroups.addAll(storedGroups);
    }
    _enabledGroups.add('vpn-1'); // required

    _routeFinal = storedFinal.isNotEmpty ? storedFinal : 'vpn-1';
    _customRules.addAll(await SettingsStorage.getCustomRules());

    // Routing vars (Auto Proxy tuning) — берём stored или template default.
    for (final v in template.varsFor('routing')) {
      _routingVarValues[v.name] = storedVars[v.name] ?? v.defaultValue;
    }

    // Выставляем `_template` ДО `_refreshSrsCache` — он через `_presetFor`
    // ищет `SelectableRule` в `_template.selectableRules`, иначе получит
    // null и проскочит auto-disable для preset-правил с uncached
    // remote rule_set'ами (task 011).
    _template = template;

    await _migrateLegacyPresets(template);
    await _refreshSrsCache();

    setState(() {
      _loading = false;
    });
  }

  /// Обработчик изменения переменной `chapter: routing` — сохраняем в
  /// SettingsStorage и через debounce триггерим rebuild конфига.
  void _onRoutingVarChanged(String name, String value) {
    _routingVarValues[name] = value;
    unawaited(SettingsStorage.setVar(name, value));
    _markDirty();
  }

  /// §076/§085 R4: atomic storage flush (вызывается mixin'ом на dispose/
  /// paused). Inline rebuild + snackbars удалены — lazy на возврате home.
  @override
  Future<void> persistChanges() async {
    await SettingsStorage.saveEnabledGroups(_enabledGroups);
    await SettingsStorage.saveRouteFinal(_routeFinal);
    await SettingsStorage.saveCustomRules(_customRules);
    // §076: configDirty уже true (set синхронно в markDirty). НЕ
    // переставляем тут — race с home return observer (banner blink).
  }

  /// Обновить `_srsCached` + принудительно **отключить** правила у которых
  /// нет нужного кэша (task 011): без локального `.srs` правило не может
  /// работать, sing-box просто пропустит соответствующий rule_set при
  /// expansion (см. preset_expand.dart), а enabled-switch visually обманывал
  /// бы — «вкл.», но ничего не матчит. Выключаем явно → юзер видит OFF и
  /// понимает, что надо тапнуть ☁ для download'а.
  ///
  /// Проверяется:
  /// - `CustomRuleSrs` — один файл по `id`.
  /// - `CustomRulePreset` — все remote rule_set'ы пресета (`preset__<presetId>__<tag>`).
  Future<void> _refreshSrsCache() async {
    _srsCached.clear();
    var changed = false;
    // Set известных disk-cache ID'шников. Нужен для `pruneOrphans`
    // ниже — disk-ID отличается от `_srsCached` композитного ключа
    // (`_presetSrsKey` использует `rule.id|tag`, а файл лежит под
    // `preset__<presetId>__<tag>`).
    final activeDiskIds = <String>{};
    for (var i = 0; i < _customRules.length; i++) {
      final r = _customRules[i];
      if (r is CustomRuleSrs) {
        // Srs-правило резервирует свой id в disk-namespace'е независимо от
        // того, скачан файл или нет — чтобы prune не удалил ещё-не-скачанный.
        activeDiskIds.add(r.id);
        final cached = await RuleSetDownloader.isCached(r.id);
        if (cached) _srsCached.add(r.id);
        if (!cached && r.enabled) {
          _customRules[i] = r.withEnabled(false);
          changed = true;
        }
      } else if (r is CustomRulePreset) {
        final preset = _presetFor(r.presetId);
        if (preset == null) continue;
        var allCached = true;
        final remotes = _remoteRuleSetsOf(preset, r); // §045: enabled-gating
        for (final rs in remotes) {
          activeDiskIds.add(
              RuleSetDownloader.presetCacheId(r.presetId, rs.tag));
          final cached = await RuleSetDownloader.cachedPathForPreset(
                  r.presetId, rs.tag) !=
              null;
          if (cached) {
            _srsCached.add(_presetSrsKey(r, rs.tag));
          } else {
            allCached = false;
          }
        }
        if (remotes.isNotEmpty && !allCached && r.enabled) {
          _customRules[i] = r.withEnabled(false);
          changed = true;
        }
      }
    }
    // Fire-and-forget: удалить orphan'ов (файлы без соответствующего правила).
    // Не критично по времени, не влияет на UI — unawaited'им.
    unawaited(RuleSetDownloader.pruneOrphans(activeDiskIds));
    if (changed) _markDirty();
  }

  /// One-shot переход на единую модель: legacy `enabled_rules` +
  /// `rule_outbounds` → `custom_rules`. Для fresh-install'а (legacy ключей
  /// нет) seed'им `template.selectableRules` с `default: true`.
  /// Повторно не запускается — защищаемся флагом `presets_migrated`.
  Future<void> _migrateLegacyPresets(WizardTemplate template) async {
    if (await SettingsStorage.hasPresetsMigrated()) return;

    final legacyEnabled = await SettingsStorage.getEnabledRules();
    final legacyOutbounds = await SettingsStorage.getRuleOutbounds();

    final labels = legacyEnabled.isNotEmpty
        ? legacyEnabled
        : <String>{
            for (final r in template.selectableRules)
              if (r.defaultEnabled) r.label,
          };

    for (final label in labels) {
      final sr = template.selectableRules
          .firstWhere((r) => r.label == label, orElse: () => kEmptySelectable);
      if (sr.label.isEmpty) continue;
      final cr = selectableRuleToCustom(
        sr,
        template,
        overrideOutbound: legacyOutbounds[label],
      );
      _customRules.add(cr);
    }

    await SettingsStorage.saveCustomRules(_customRules);
    await SettingsStorage.saveEnabledRules(<String>{});
    await SettingsStorage.saveRuleOutbounds(<String, String>{});
    await SettingsStorage.markPresetsMigrated();
  }

  /// Качает SRS и при успехе включает правило. Вызывается из Switch'а
  /// "включить" по правилу с не-закэшеным SRS — раньше Switch был disabled
  /// и юзеру приходилось сначала тапать ☁ вручную, потом сам Switch.
  Future<void> _enableAfterDownload(CustomRule rule) async {
    await _downloadSrs(rule);
    if (!mounted) return;
    // Проверка "всё ли закачалось" — per-kind.
    bool ok;
    if (rule is CustomRuleSrs) {
      ok = _srsCached.contains(rule.id);
    } else if (rule is CustomRulePreset) {
      final preset = _presetFor(rule.presetId);
      ok = preset != null && !_presetNeedsDownload(rule, preset);
    } else {
      ok = true;
    }
    if (!ok) return;
    final i = _customRules.indexWhere((r) => r.id == rule.id);
    if (i < 0) return;
    setState(() {
      _customRules[i] = _customRules[i].withEnabled(true);
      _markDirty();
    });
  }

  Future<void> _downloadSrs(CustomRule rule) async {
    if (rule is CustomRuleSrs) {
      await _downloadSrsForSrsRule(rule);
      return;
    }
    if (rule is CustomRulePreset) {
      await _downloadSrsForPresetRule(rule);
      return;
    }
  }

  Future<void> _downloadSrsForSrsRule(CustomRuleSrs rule) async {
    if (rule.srsUrl.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('SRS URL is empty')),
      );
      return;
    }
    setState(() => _srsDownloading.add(rule.id));
    final path = await RuleSetDownloader.download(rule.id, rule.srsUrl.trim());
    if (!mounted) return;
    setState(() {
      _srsDownloading.remove(rule.id);
      if (path != null) _srsCached.add(rule.id);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(path != null
            ? 'Downloaded "${rule.name}"'
            : 'Failed to download "${rule.name}" — check URL/network'),
      ),
    );
    if (path != null) _markDirty();
  }

  /// Скачивает все remote rule_set'ы пресета в локальный кэш
  /// (`$docs/rule_sets/preset__<presetId>__<tag>.srs`, spec §011). Успех =
  /// **все** скачались. Частичный успех отображается snackbar'ом.
  Future<void> _downloadSrsForPresetRule(CustomRulePreset rule) async {
    final preset = _presetFor(rule.presetId);
    if (preset == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Preset "${rule.presetId}" not found')),
      );
      return;
    }
    final remotes = _remoteRuleSetsOf(preset, rule); // §045: enabled-gating
    if (remotes.isEmpty) return; // inline-only preset — нечего качать
    setState(() => _srsDownloading.add(rule.id));
    var ok = 0;
    var failed = 0;
    for (final rs in remotes) {
      final path = await RuleSetDownloader.downloadForPreset(
          rule.presetId, rs.tag, rs.url);
      if (!mounted) return;
      if (path != null) {
        _srsCached.add(_presetSrsKey(rule, rs.tag));
        ok++;
      } else {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() => _srsDownloading.remove(rule.id));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(failed == 0
            ? 'Downloaded "${rule.name}" ($ok rule-set${ok == 1 ? "" : "s"})'
            : 'Partial: $ok ok, $failed failed for "${rule.name}"'),
      ),
    );
    if (ok > 0) _markDirty();
  }
}
