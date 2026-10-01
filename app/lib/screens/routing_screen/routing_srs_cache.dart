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
  List<Direction> get _directions; // §125
  void _invalidateOutboundOptions(); // §219 — сброс кэша опций outbound
  set _template(WizardTemplate? value);
  Map<String, String> get _userVars; // §534 — userVars для гейта наборов
  set _userVars(Map<String, String> value);
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

    // §125 — Направления из storage. Миграция enabled_groups→directions уже отработала
    // в main() init; на пустом списке (старт без миграции в тестах) синтезируем
    // из template, чтобы экран не был пустым.
    final stored = await SettingsStorage.getDirections();
    if (stored.isEmpty) {
      await SettingsStorage.migrateDirectionsIfNeeded(
        template.groupTemplates,
        varDefaults: {
          for (final v in template.vars) v.name: v.defaultValue,
        },
      );
      _directions.addAll(await SettingsStorage.getDirections());
    } else {
      _directions.addAll(stored);
    }
    _invalidateOutboundOptions(); // §219 — сброс кэша после load Направлений

    _routeFinal = storedFinal.isNotEmpty ? storedFinal : 'vpn-1';
    // §578 — разовый шаг до чтения правил: поздний дефолтный пресет.
    await SettingsStorage.seedLateDefaultPresets(template);
    _customRules.addAll(await SettingsStorage.getCustomRules());

    // Выставляем `_template` ДО `_refreshSrsCache` — он через `_presetFor`
    // ищет `SelectableRule` в `_template.selectableRules`, иначе получит
    // null и не увидит кэш preset-правил с remote rule_set'ами (task 011).
    _template = template;

    await _seedDefaultPresets(template);

    // §265/§266 — вычистить осиротевшие ref-var значения из varsValues пресетов
    // (напр. resolve_enabled застряла в varsValues с тех пор, как была обычной
    // preset-var — теперь ref, значение в userVars). Иначе subtitle/Debug API
    // показывают неверное значение из varsValues.
    final stripped =
        stripRefVarsFromVarsValues(_customRules, template.selectableRules);
    final strippedChanged = !identical(stripped, _customRules);

    // §370 — нормализация порядка по оси `num` на UI/storage-уровне.
    // `_seedDefaultPresets` сидит дефолты только при первой установке
    // (`hasDefaultsSeeded` guard); у существующих юзеров обязательный пресет
    // (traffic-processing) НЕ засеется и не появится в списке правил, хотя
    // билдер добавляет его правила в route.rules на лету. Здесь же случается
    // разметка storage, записанного до §370 (`num` отсутствует) — отдельного
    // версионированного шага миграции нет. Если список изменился — персистим,
    // чтобы номера видели все потребители: Routing UI, Debug API /rules,
    // DNS-экран.
    // Неразмеченные правила ловим ДО нормализации: `markRuleOrder` мутирует
    // `orderNum` на месте, после неё разницы «было/стало» уже не видно.
    // D-117 — сдвинутая голова тоже: её номер меняется, а порядок может и
    // не поменяться.
    final needsMarking = stripped.any((r) => r.orderNum == null) ||
        requiredRuleNumsShifted(stripped, template.selectableRules);
    final normalized =
        normalizeRuleOrder(stripped, template.selectableRules, template);
    final orderChanged =
        needsMarking || !_sameRuleOrder(normalized, _customRules);
    if (strippedChanged || orderChanged) {
      _customRules
        ..clear()
        ..addAll(normalized);
      await SettingsStorage.saveCustomRules(_customRules);
    }

    await _refreshSrsCache();

    setState(() {
      _loading = false;
    });
  }

  /// §107: staging — буфер экрана в `_cache` на каждую мутацию; дисковый
  /// flush — mixin'ом (flushToDisk) на dispose/paused.
  @override
  Future<void> stageChanges() async {
    await DirectionMutations.bulkReplace(_directions, flush: false); // §125/§292
    await SettingsStorage.saveRouteFinal(_routeFinal, flush: false);
    await SettingsStorage.saveCustomRules(_customRules, flush: false);
    // §076: configDirty уже true (set синхронно в markDirty). НЕ
    // переставляем тут — race с home return observer (banner blink).
  }

  /// Обновить `_srsCached` по дисковому кэшу ([RoutingHelpers.scanSrsCache]).
  ///
  /// §601 — правила НЕ переписываются: `enabled` — только намерение
  /// пользователя. Включённое правило без файла показывается «ждёт
  /// скачивания» (приглушённый свич + ☁), набора без файла в конфиге нет,
  /// файл скачивает автообновление. Раньше (task 011) здесь писалось
  /// `enabled=false`, и автообновление такое правило больше не качало —
  /// дефолтный пресет гас навсегда.
  Future<void> _refreshSrsCache() async {
    // §534 — свежий снимок userVars до пересчёта: гейт набора на
    // ref-переменной (§265) читает значение из глобального словаря.
    _userVars = await SettingsStorage.getAllVars();
    final scan = await RoutingHelpers.scanSrsCache(_customRules,
        presetFor: _presetFor, globalVars: _userVars);
    _srsCached
      ..clear()
      ..addAll(scan.cached);
    // Fire-and-forget: удалить orphan'ов (файлы без соответствующего правила).
    // Не критично по времени, не влияет на UI — unawaited'им.
    unawaited(RuleSetDownloader.pruneOrphans(scan.activeDiskIds));
  }

  /// §264 — совпадают ли два списка правил по порядку и составу (по `id`).
  /// Чтобы не персистить, когда нормализация ничего не изменила (pinned уже
  /// на месте) — избегаем лишней записи в storage на каждом открытии экрана.
  bool _sameRuleOrder(List<CustomRule> a, List<CustomRule> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
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
        SnackBar(content: Text(getLocalText.s("SRS URL is empty"))),
      );
      return;
    }
    setState(() => _srsDownloading.add(rule.id));
    // ## 12 — все наборы по порядку; первый провал = провал правила.
    String? path;
    for (var i = 0; i < rule.srsUrls.length; i++) {
      path = await RuleSetDownloader.download(
          CustomRuleSrs.cacheIdAt(rule.id, i), rule.srsUrls[i]);
      if (path == null) break;
    }
    if (!mounted) return;
    setState(() {
      _srsDownloading.remove(rule.id);
      if (path != null) _srsCached.add(rule.id);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(path != null
            ? getLocalText.s("Downloaded \"%s\"", rule.name)
            : getLocalText.s("Failed to download \"%s\" — check URL/network", rule.name)),
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
        SnackBar(content: Text(getLocalText.s("Preset \"%s\" not found", rule.presetId))),
      );
      return;
    }
    // §045/§107/§534: качаем только наборы, включённые гейтом.
    final remotes = _remoteRuleSetsOf(preset, rule);
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
            ? getLocalText.plural("Downloaded \"%2\$s\" (%1\$d rule-sets)", ok, rule.name)
            : getLocalText.s("Partial: %1\$d ok, %2\$d failed for \"%3\$s\"", ok, failed, rule.name)),
      ),
    );
    if (ok > 0) _markDirty();
  }
}
