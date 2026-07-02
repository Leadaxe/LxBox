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
  List<Channel> get _channels; // §125
  void _invalidateOutboundOptions(); // §219 — сброс кэша опций outbound
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
    final storedFinal = await SettingsStorage.getRouteFinal();

    // §125 — каналы из storage. Миграция enabled_groups→channels уже отработала
    // в main() init; на пустом списке (старт без миграции в тестах) синтезируем
    // из template, чтобы экран не был пустым.
    final stored = await SettingsStorage.getChannels();
    if (stored.isEmpty) {
      await SettingsStorage.migrateChannelsIfNeeded(template.presetGroups);
      _channels.addAll(await SettingsStorage.getChannels());
    } else {
      _channels.addAll(stored);
    }
    _invalidateOutboundOptions(); // §219 — сброс кэша после load каналов

    _routeFinal = storedFinal.isNotEmpty ? storedFinal : 'vpn-1';
    _customRules.addAll(await SettingsStorage.getCustomRules());

    // Выставляем `_template` ДО `_refreshSrsCache` — он через `_presetFor`
    // ищет `SelectableRule` в `_template.selectableRules`, иначе получит
    // null и проскочит auto-disable для preset-правил с uncached
    // remote rule_set'ами (task 011).
    _template = template;

    await _seedDefaultPresets(template);
    await _refreshSrsCache();

    setState(() {
      _loading = false;
    });
  }

  /// §107: staging — буфер экрана в `_cache` на каждую мутацию; дисковый
  /// flush — mixin'ом (flushToDisk) на dispose/paused.
  @override
  Future<void> stageChanges() async {
    await SettingsStorage.setChannels(_channels, flush: false); // §125
    await SettingsStorage.saveRouteFinal(_routeFinal, flush: false);
    await SettingsStorage.saveCustomRules(_customRules, flush: false);
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

  /// Fresh-install seed: засеять `_customRules` из `template.selectableRules`
  /// с `default: true`. One-shot — защищаемся флагом `defaultsSeeded` (тот же
  /// storage-ключ `presets_migrated`: §159 удалил legacy-миграцию
  /// `enabled_rules`/`rule_outbounds`, но флаг переиспользуем, чтобы юзеры,
  /// которые ранее уже мигрировали/засеялись, НЕ получили повторный seed).
  Future<void> _seedDefaultPresets(WizardTemplate template) async {
    if (await SettingsStorage.hasDefaultsSeeded()) return;

    for (final sr in template.selectableRules) {
      if (!sr.defaultEnabled) continue;
      _customRules.add(selectableRuleToCustom(sr, template));
    }

    await SettingsStorage.saveCustomRules(_customRules);
    await SettingsStorage.markDefaultsSeeded();
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
