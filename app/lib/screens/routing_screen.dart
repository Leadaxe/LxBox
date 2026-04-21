import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../config/consts.dart';
import '../controllers/subscription_controller.dart';
import '../models/custom_rule.dart';
import '../models/parser_config.dart';
import '../services/rule_set_downloader.dart';
import '../services/selectable_to_custom.dart';
import '../services/settings_storage.dart';
import '../services/template_loader.dart';
import '../widgets/outbound_picker.dart';
import '../widgets/template_var_list.dart';
import 'custom_rule_edit_screen.dart';

class RoutingScreen extends StatefulWidget {
  const RoutingScreen({
    super.key,
    required this.subController,
    required this.homeController,
  });

  final SubscriptionController subController;
  final HomeController homeController;

  @override
  State<RoutingScreen> createState() => _RoutingScreenState();
}

class _RoutingScreenState extends State<RoutingScreen> {
  WizardTemplate? _template;
  final _enabledGroups = <String>{};
  String _routeFinal = '';
  final _customRules = <CustomRule>[];
  final _srsCached = <String>{};      // rule.id → файл есть в кэше
  final _srsDownloading = <String>{}; // rule.id → идёт загрузка
  bool _loading = true;
  Timer? _saveTimer;

  /// chapter==routing vars (Auto Proxy tuning — urltest_url/interval/tolerance).
  /// Значения держим отдельно от custom_rules: apply'ит их через SettingsStorage.setVar.
  final Map<String, String> _routingVarValues = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () => unawaited(_apply()));
  }

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
    _scheduleSave();
  }

  /// Рендерит все секции с `chapter: routing` из template (сейчас — только
  /// "Auto Proxy"). Пустой список если в template нет routing-секций.
  List<Widget> _buildRoutingVarSections(WizardTemplate template) {
    final sections = template.sectionsFor('routing');
    if (sections.isEmpty) return const [];
    final vars =
        template.varsFor('routing').where((v) => v.isEditable).toList();
    if (vars.isEmpty) return const [];
    return [
      const Divider(height: 24),
      TemplateVarListView(
        vars: vars,
        initialValues: _routingVarValues,
        sectionDescriptions: {
          for (final s in sections) s.title: s.description,
        },
        onChanged: _onRoutingVarChanged,
      ),
    ];
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
        final remotes = _remoteRuleSetsOf(preset);
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
    if (changed) _scheduleSave();
  }

  /// Список remote `rule_set` пресета (type=remote + url). Пустой если
  /// пресет только inline или без rule_set'ов.
  List<_PresetRemoteRuleSet> _remoteRuleSetsOf(SelectableRule preset) {
    final out = <_PresetRemoteRuleSet>[];
    for (final rs in preset.ruleSets) {
      if (rs['type'] != 'remote') continue;
      final tag = rs['tag'];
      final url = rs['url'];
      if (tag is! String || tag.isEmpty) continue;
      if (url is! String || url.isEmpty) continue;
      out.add(_PresetRemoteRuleSet(tag: tag, url: url));
    }
    return out;
  }

  /// Composite ключ для `_srsCached` / `_srsDownloading` у preset-rule_set'ов.
  /// У `CustomRuleSrs` там просто `rule.id`; у preset'ов — `<id>|<tag>`,
  /// чтобы не путаться между несколькими rule_set'ами одного пресета.
  String _presetSrsKey(CustomRulePreset rule, String tag) =>
      '${rule.id}|$tag';

  /// `true` если у preset-правила есть remote rule_set'ы и хотя бы один из
  /// них НЕ закэширован. Используется для disabled-switch (switch auto-
  /// download'ит при toggle-on) и для выбора иконки ☁/✅.
  bool _presetNeedsDownload(CustomRulePreset rule, SelectableRule preset) {
    final remotes = _remoteRuleSetsOf(preset);
    if (remotes.isEmpty) return false;
    for (final rs in remotes) {
      if (!_srsCached.contains(_presetSrsKey(rule, rs.tag))) return true;
    }
    return false;
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
      _scheduleSave();
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
    if (path != null) _scheduleSave();
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
    final remotes = _remoteRuleSetsOf(preset);
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
    if (ok > 0) _scheduleSave();
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
          .firstWhere((r) => r.label == label, orElse: () => _emptySelectable);
      if (sr.label.isEmpty) continue;
      final cr = selectableRuleToCustom(
        sr,
        template,
        overrideOutbound: legacyOutbounds[label],
      );
      if (cr != null) _customRules.add(cr);
    }

    await SettingsStorage.saveCustomRules(_customRules);
    await SettingsStorage.saveEnabledRules(<String>{});
    await SettingsStorage.saveRuleOutbounds(<String, String>{});
    await SettingsStorage.markPresetsMigrated();
  }

  Future<void> _apply() async {
    await SettingsStorage.saveEnabledGroups(_enabledGroups);
    await SettingsStorage.saveRouteFinal(_routeFinal);
    await SettingsStorage.saveCustomRules(_customRules);

    if (!mounted) return;

    final config = await widget.subController.generateConfig();
    if (config != null && mounted) {
      final ok = await widget.homeController.saveParsedConfig(config);
      if (ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Routing applied, config regenerated')),
        );
        if (widget.homeController.state.tunnelUp) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Restart VPN to apply changes')),
          );
        }
      }
    }

    setState(() {});
  }

  /// Returns the list of available outbound options depending on enabled groups.
  List<_OutboundOption> _outboundOptions() {
    final opts = <_OutboundOption>[
      const _OutboundOption(label: 'direct', tag: 'direct-out'),
      const _OutboundOption(label: 'auto', tag: kAutoOutboundTag),
    ];
    final template = _template;
    if (template != null) {
      for (final g in template.presetGroups) {
        if (_enabledGroups.contains(g.tag) && g.tag != kAutoOutboundTag) {
          opts.add(_OutboundOption(label: g.label.isNotEmpty ? g.label : g.tag, tag: g.tag));
        }
      }
    }
    return opts;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Routing')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final template = _template!;
    final bottomPad = MediaQuery.of(context).padding.bottom + 24;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Routing'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Channels'),
              Tab(text: 'Presets'),
              Tab(text: 'Rules'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // ─── Channels: proxy groups + default fallback + Auto tuning ───
            ListView(
              padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPad),
              children: [
                Text(
                  'Enabled groups appear in the selector on the home screen.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 8),
                ...template.presetGroups.map(_buildGroupTile),
                const Divider(height: 24),
                _buildRouteFinalTile(),
                ..._buildRoutingVarSections(template),
              ],
            ),

            // ─── Presets: catalog of pre-built rules to copy into Rules ───
            ListView(
              padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPad),
              children: [
                Text(
                  'Ready-made rules you can copy into Rules, then edit freely.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 8),
                ...template.selectableRules.map(_buildPresetCatalogTile),
              ],
            ),

            // ─── Rules: unified custom routing (spec §030) ───
            // NB: ListView с горизонтальными paddings'ами 0 — чтобы тайлы
            // растягивались edge-to-edge. Интро и Add-button сами дают
            // себе 12px через Padding.
            ListView(
              padding: EdgeInsets.only(top: 12, bottom: bottomPad),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'Route or block by app / domain / IP / port / protocol, or remote .srs rule-set.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
                const SizedBox(height: 8),
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: _customRules.length,
                  onReorder: _onReorderCustomRule,
                  itemBuilder: (ctx, i) => KeyedSubtree(
                    key: ValueKey(_customRules[i].id),
                    child: _buildCustomRuleTile(i),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextButton.icon(
                    onPressed: _addCustomRule,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add rule'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupTile(PresetGroup group) {
    // VPN ① is always enabled — can't be disabled
    final isRequired = group.tag == 'vpn-1';
    return SwitchListTile(
      title: Text(group.label.isNotEmpty ? group.label : group.tag),
      subtitle: Text(
        isRequired
            ? '${group.type} \u00b7 ${group.tag} \u00b7 required'
            : '${group.type} \u00b7 ${group.tag}',
        style: const TextStyle(fontSize: 12),
      ),
      value: isRequired ? true : _enabledGroups.contains(group.tag),
      onChanged: isRequired ? null : (val) {
        setState(() {
          if (val) {
            _enabledGroups.add(group.tag);
          } else {
            _enabledGroups.remove(group.tag);
          }
          _scheduleSave();
        });
      },
    );
  }

  /// Каталог пресетов (read-only). Tap на "Copy" → клонирует в `_customRules`
  /// через `selectableRuleToCustom`, переходит на таб Rules. Если пресет уже
  /// есть по label (или конверсия неудачна) — показываем snackbar.
  Widget _buildPresetCatalogTile(SelectableRule rule) {
    final template = _template!;
    // Bundle-пресеты (spec §033) матчим по стабильному `presetId`, legacy —
    // по label (как было в 1.4). Юзер может переименовать CustomRule;
    // для bundle это не должно ломать "In Rules"-индикатор.
    // Identity-match по `presetId` (стабильный slug, не ломается при
    // переименовании CustomRule). Kind не фильтруем — для legacy-пресетов
    // CustomRule имеет `kind: inline|srs`, но presetId проставлен через
    // `selectableRuleToCustom` (spec §033). Пресет без `preset_id` → в
    // каталоге всегда кнопка "Add to Rules" (дубли на совести юзера:
    // по label не матчим, т.к. юзер может переименовать).
    final existing = rule.presetId.isNotEmpty &&
        _customRules.any((c) => c.presetId == rule.presetId);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(rule.label,
                    style: const TextStyle(fontWeight: FontWeight.w500)),
              ),
              TextButton.icon(
                icon: Icon(existing ? Icons.check : Icons.add, size: 16),
                label: Text(existing ? 'In Rules' : 'Add to Rules'),
                onPressed: existing ? null : () => _copyPreset(rule, template),
              ),
            ],
          ),
          if (rule.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(rule.description,
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
          const Divider(height: 1),
        ],
      ),
    );
  }

  void _copyPreset(SelectableRule rule, WizardTemplate template) {
    CustomRule? cr = selectableRuleToCustom(rule, template);
    if (cr == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot represent "${rule.label}" as a rule')),
      );
      return;
    }
    // Правила нуждающиеся в SRS-файле добавляются disabled — юзер сначала
    // качает через ☁, потом включает switch (или toggle-on сам auto-
    // download'ит и enable на успехе).
    final needsSrs = cr is CustomRuleSrs ||
        (cr is CustomRulePreset && _remoteRuleSetsOf(rule).isNotEmpty);
    if (needsSrs) cr = cr.withEnabled(false);

    final insertAt = _computeInsertIndex(cr!);
    setState(() {
      _customRules.insert(insertAt, cr!);
      _scheduleSave();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(needsSrs
            ? 'Added "${rule.label}" — tap ☁ to download, then enable'
            : 'Added "${rule.label}" to Rules'),
      ),
    );
  }

  Widget _buildRouteFinalTile() {
    final options = _outboundOptions();
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: const Text('Default traffic'),
      subtitle: const Text(
        'Fallback for unmatched traffic (route.final)',
        style: TextStyle(fontSize: 12),
      ),
      trailing: SizedBox(
        width: 120,
        child: DropdownButton<String>(
          isExpanded: true,
          isDense: true,
          value: options.any((o) => o.tag == _routeFinal) ? _routeFinal : options.first.tag,
          items: options
              .map((o) => DropdownMenuItem(value: o.tag, child: Text(o.label, style: const TextStyle(fontSize: 13))))
              .toList(),
          onChanged: (val) {
            if (val == null) return;
            setState(() {
              _routeFinal = val;
              _scheduleSave();
            });
          },
        ),
      ),
    );
  }

  // ─── Custom Rules (Routing, spec §030) ───

  void _onReorderCustomRule(int oldIndex, int newIndex) {
    setState(() {
      // ReorderableListView передаёт newIndex сдвинутым на 1 если move вниз.
      if (newIndex > oldIndex) newIndex -= 1;
      final moved = _customRules.removeAt(oldIndex);
      _customRules.insert(newIndex, moved);
      _scheduleSave();
    });
  }

  Widget _buildCustomRuleTile(int index) {
    final rule = _customRules[index];
    final options = _outboundOptions();
    final cs = Theme.of(context).colorScheme;
    final subtitleColor = rule.enabled ? cs.primary : cs.onSurfaceVariant;
    final preset =
        rule.kind == CustomRuleKind.preset ? _presetFor(rule.presetId) : null;
    final subtitle = _ruleSubtitle(rule, preset);
    final pickerValue =
        rule.kind == CustomRuleKind.preset ? _presetOut(rule, preset) : rule.outbound;
    final pickerDisabled =
        rule.kind == CustomRuleKind.preset && preset == null;

    final content = GestureDetector(
      onTap: () => _openCustomRuleEditor(index),
      onLongPressStart: (d) => _showRuleContextMenu(index, d.globalPosition),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Switch(
                  value: rule.enabled,
                  onChanged: (v) {
                    if (v && rule is CustomRuleSrs &&
                        !_srsCached.contains(rule.id)) {
                      unawaited(_enableAfterDownload(rule));
                      return;
                    }
                    if (v && rule is CustomRulePreset &&
                        preset != null &&
                        _presetNeedsDownload(rule, preset)) {
                      unawaited(_enableAfterDownload(rule));
                      return;
                    }
                    setState(() {
                      _customRules[index] = rule.withEnabled(v);
                      _scheduleSave();
                    });
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(rule.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: rule.enabled ? null : cs.onSurfaceVariant,
                      )),
                ),
                if (rule is CustomRuleSrs) _srsStatusButton(rule),
                if (rule is CustomRulePreset &&
                    preset != null &&
                    _remoteRuleSetsOf(preset).isNotEmpty)
                  _presetSrsStatusButton(rule, preset),
                if (pickerDisabled)
                  Icon(Icons.warning_amber_outlined,
                      color: cs.error, size: 18)
                else
                  OutboundPicker(
                    value: pickerValue,
                    options: options
                        .map((o) =>
                            OutboundOption(value: o.tag, label: o.label))
                        .toList(),
                    onChanged: (val) {
                      setState(() {
                        _customRules[index] = rule.withOutbound(val);
                        _scheduleSave();
                      });
                    },
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 64, bottom: 4),
              child: Row(
                children: [
                  if (rule.kind == CustomRuleKind.preset) ...[
                    Icon(Icons.lock_outline,
                        size: 12, color: subtitleColor),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(subtitle,
                        style:
                            TextStyle(fontSize: 12, color: subtitleColor),
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Container(
              width: 18,
              margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(Icons.drag_indicator,
                  size: 16, color: cs.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                content,
                const Divider(height: 1),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _srsStatusButton(CustomRule rule) {
    final cs = Theme.of(context).colorScheme;
    if (_srsDownloading.contains(rule.id)) {
      return const SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
        ),
      );
    }
    final cached = _srsCached.contains(rule.id);
    // NB: без tooltip — иначе long-press на иконке показывает тултип и
    // перехватывает контекст-меню родительского GestureDetector.
    return IconButton(
      iconSize: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      icon: Icon(
        cached ? Icons.cloud_done_outlined : Icons.cloud_download_outlined,
        color: cached ? Colors.green : cs.onSurfaceVariant,
      ),
      onPressed: () => unawaited(_downloadSrs(rule)),
    );
  }

  /// ☁-кнопка для preset-правил с remote rule_set'ами. "cached" = все
  /// remote rule_set'ы пресета имеют локальный `.srs` (spec §011 compliance,
  /// task 011).
  Widget _presetSrsStatusButton(CustomRulePreset rule, SelectableRule preset) {
    final cs = Theme.of(context).colorScheme;
    if (_srsDownloading.contains(rule.id)) {
      return const SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
        ),
      );
    }
    final cached = !_presetNeedsDownload(rule, preset);
    // Намеренно InkWell, а не IconButton внутри GestureDetector — GestureDetector
    // с HitTestBehavior.opaque перехватывал tap ДО IconButton.onPressed. InkWell
    // получает и tap, и long-press одним нодом.
    return SizedBox(
      width: 32,
      height: 32,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => unawaited(_downloadSrsForPresetRule(rule)),
        onLongPress: () async {
          final pos = await _centerOf(context) ?? Offset.zero;
          if (!mounted) return;
          _showPresetCloudMenu(rule, preset, pos);
        },
        child: Icon(
          cached ? Icons.cloud_done_outlined : Icons.cloud_download_outlined,
          size: 18,
          color: cached ? Colors.green : cs.onSurfaceVariant,
        ),
      ),
    );
  }

  /// Грубое определение центра виджета для показа popup меню от long-press.
  /// BuildContext в момент long-press не доступен (InkWell.onLongPress без
  /// details), поэтому используем координаты текущего контекста экрана.
  Future<Offset?> _centerOf(BuildContext ctx) async {
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return null;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  /// Long-press меню у ☁ для preset-rule: Refresh / Clear. Refresh =
  /// повторный download всех remote rule_set'ов. Clear = удалить все cached
  /// файлы + disabled switch (правило не матчит без кэша).
  Future<void> _showPresetCloudMenu(
    CustomRulePreset rule,
    SelectableRule preset,
    Offset pos,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy,
        overlay.size.width - pos.dx,
        overlay.size.height - pos.dy,
      ),
      items: [
        const PopupMenuItem<String>(
          value: 'refresh',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.refresh, size: 20),
            title: Text('Refresh rule-sets'),
          ),
        ),
        PopupMenuItem<String>(
          value: 'clear',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.cloud_off_outlined,
                size: 20, color: Theme.of(context).colorScheme.error),
            title: Text('Clear cached files',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'refresh':
        unawaited(_downloadSrsForPresetRule(rule));
      case 'clear':
        for (final rs in _remoteRuleSetsOf(preset)) {
          await RuleSetDownloader.deleteForPreset(rule.presetId, rs.tag);
          _srsCached.remove(_presetSrsKey(rule, rs.tag));
        }
        if (!mounted) return;
        final i = _customRules.indexWhere((r) => r.id == rule.id);
        if (i >= 0) {
          setState(() {
            _customRules[i] = rule.withEnabled(false);
            _scheduleSave();
          });
        } else {
          setState(() {});
        }
    }
  }

  /// Контекстное меню по long-press на tile — только Delete. Refresh для
  /// srs живёт в редакторе (long-press на cloud ☁).
  Future<void> _showRuleContextMenu(int index, Offset pos) async {
    if (index < 0 || index >= _customRules.length) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy,
        overlay.size.width - pos.dx,
        overlay.size.height - pos.dy,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'delete',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline,
                size: 20, color: Theme.of(context).colorScheme.error),
            title: Text('Delete',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ),
      ],
    );
    if (!mounted) return;
    if (action == 'delete') {
      unawaited(_confirmDeleteCustomRule(index));
    }
  }

  Future<void> _confirmDeleteCustomRule(int index) async {
    final rule = _customRules[index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete rule?'),
        content: Text('Remove "${rule.name}" permanently?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _customRules.removeAt(index);
      _srsCached.remove(rule.id);
      _scheduleSave();
    });
    // Подчищаем cached-файлы: SRS — один файл по `id`, preset — по каждому
    // remote rule_set'у пресета + убираем composite-ключи из _srsCached.
    if (rule is CustomRuleSrs) {
      unawaited(RuleSetDownloader.delete(rule.id));
    } else if (rule is CustomRulePreset) {
      final preset = _presetFor(rule.presetId);
      if (preset != null) {
        for (final rs in _remoteRuleSetsOf(preset)) {
          unawaited(RuleSetDownloader.deleteForPreset(rule.presetId, rs.tag));
          _srsCached.remove(_presetSrsKey(rule, rs.tag));
        }
      }
    }
  }

  void _addCustomRule() async {
    // Новое пользовательское правило — inline (default). Juzer в редакторе
    // может переключить на srs; `preset` добавляется только через
    // каталог Presets.
    final fresh = CustomRuleInline(
      name: _uniqueCustomRuleName('Rule ${_customRules.length + 1}', ''),
    );
    final result = await openCustomRuleEditor(
      context,
      initial: fresh,
      outboundOptions: _outboundOptions()
          .map((o) => OutboundOption(value: o.tag, label: o.label))
          .toList(),
      existingNames: _customRules.map((r) => r.name).toSet(),
    );
    if (result == null) return;
    if (result.wasDeleted) return; // нечего удалять — только что создали
    if (result.saved != null && mounted) {
      final saved = result.saved!;
      final insertAt = _computeInsertIndex(saved);
      setState(() {
        _customRules.insert(insertAt, saved);
        _scheduleSave();
      });
    }
  }

  Future<void> _openCustomRuleEditor(int index) async {
    final current = _customRules[index];
    final existing = _customRules
        .where((r) => r.id != current.id)
        .map((r) => r.name)
        .toSet();
    final result = await openCustomRuleEditor(
      context,
      initial: current,
      outboundOptions: _outboundOptions()
          .map((o) => OutboundOption(value: o.tag, label: o.label))
          .toList(),
      existingNames: existing,
      preset: current.kind == CustomRuleKind.preset
          ? _presetFor(current.presetId)
          : null,
    );
    if (result == null || !mounted) return;
    if (result.wasDeleted) {
      setState(() {
        _customRules.removeAt(index);
        _scheduleSave();
      });
    } else if (result.saved != null) {
      final saved = result.saved!;
      final urlChanged = current.kind == CustomRuleKind.srs &&
          current.srsUrl.trim() != saved.srsUrl.trim();
      final kindChanged = current.kind != saved.kind;
      setState(() {
        // URL или kind поменялись → старый cached-файл невалидный, правило
        // выключаем до повторного Download.
        final next = (urlChanged || kindChanged) ? saved.withEnabled(false) : saved;
        _customRules[index] = next;
        if (urlChanged || kindChanged) _srsCached.remove(current.id);
        _scheduleSave();
      });
      if (urlChanged || kindChanged) {
        unawaited(RuleSetDownloader.delete(current.id));
      }
    }
  }

  /// Находит bundle-пресет по id в загруженном шаблоне. null если
  /// `_template == null` или пресет отсутствует (broken preset — show error
  /// card в редакторе + skip при сборке).
  SelectableRule? _presetFor(String presetId) {
    if (presetId.isEmpty) return null;
    final template = _template;
    if (template == null) return null;
    for (final p in template.selectableRules) {
      if (p.presetId == presetId) return p;
    }
    return null;
  }

  /// Текущий effective outbound для preset-правила — используется как
  /// value для OutboundPicker'а. Fallback-chain:
  ///
  /// 1. `rule.varsValues['outbound']` — explicit user override. Универсально
  ///    применяется в `preset_expand` независимо от формы template'а.
  /// 2. `preset.vars['outbound'].default_value` — если template объявил
  ///    outbound-var (Russian domains direct → `direct-out`).
  /// 3. `preset.rule['action']` — template shorthand вроде Block Ads
  ///    (`action: reject`). Отдаём сам `action`; picker интерпретирует
  ///    `reject` как пункт "Reject".
  /// 4. `preset.rule['outbound']` — hardcoded literal (ru-inside →
  ///    `direct-out`).
  /// 5. Fallback `'direct-out'`.
  ///
  /// `preset_expand` использует override из шага 1 чтобы полностью заменить
  /// template-решение на любой канал: юзер может сменить Block Ads с reject
  /// на vpn-1, и обратно. Template-форма (action vs outbound vs `@outbound`)
  /// — лишь default, не ограничение.
  /// Effective outbound любого правила — для inline/srs берёт поле, для
  /// preset делегирует в [_presetOut] через fallback-chain. Используется
  /// при insertion-sort'е нового preset'а: reject → верх, direct-out → после
  /// reject-блока, остальное → в хвост.
  String _effectiveOutboundOf(CustomRule rule) {
    if (rule is CustomRulePreset) {
      return _presetOut(rule, _presetFor(rule.presetId));
    }
    return rule.outbound;
  }

  /// Индекс куда вставить новое правило, чтобы сохранить "specific-first"
  /// порядок: reject-блок ─ direct-блок ─ всё остальное.
  ///
  /// - Новое правило с effective outbound `reject` → самый верх (index 0)
  /// - Новое правило с effective outbound `direct-out` → сразу после
  ///   последнего reject (пропускает reject-блок)
  /// - Новое правило с любым другим outbound → в хвост
  ///
  /// Внутри одного типа порядок добавления сохраняется (новый direct
  /// ложится за уже существующими direct'ами). Юзер может переставить
  /// drag'ом — это лишь initial-insert.
  int _computeInsertIndex(CustomRule newRule) {
    final outbound = _effectiveOutboundOf(newRule);
    if (outbound == kOutboundReject) return 0;
    if (outbound == 'direct-out') {
      var i = 0;
      while (i < _customRules.length &&
          _effectiveOutboundOf(_customRules[i]) == kOutboundReject) {
        i++;
      }
      return i;
    }
    return _customRules.length;
  }

  String _presetOut(CustomRule rule, SelectableRule? preset) {
    final explicit = rule.varsValues['outbound'];
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (preset == null) return 'direct-out';
    for (final v in preset.vars) {
      if (v.name == 'outbound') return v.defaultValue;
    }
    final action = preset.rule['action'];
    if (action is String && action.isNotEmpty) return action;
    final literal = preset.rule['outbound'];
    if (literal is String && literal.isNotEmpty && !literal.startsWith('@')) {
      return literal;
    }
    return 'direct-out';
  }

  String _ruleSubtitle(CustomRule rule, SelectableRule? preset) {
    if (rule.kind == CustomRuleKind.preset) {
      if (preset == null) return 'Preset not found — tap to fix';
      final parts = <String>[preset.label];
      final extras = <String>[];
      for (final v in preset.vars) {
        final value = rule.varsValues[v.name] ?? v.defaultValue;
        if (value.isEmpty) continue;
        extras.add(value);
      }
      if (extras.isNotEmpty) parts.add(extras.take(2).join(', '));
      return '${parts.join(' · ')} — tap to edit';
    }
    final summary = rule.summary;
    return summary.isEmpty
        ? 'Tap to add match fields'
        : '$summary — tap to edit';
  }

  String _uniqueCustomRuleName(String requested, String selfId) {
    final others = _customRules
        .where((r) => r.id != selfId)
        .map((r) => r.name)
        .toSet();
    if (!others.contains(requested)) return requested;
    var i = 2;
    while (others.contains('$requested ($i)')) { i++; }
    return '$requested ($i)';
  }
}

class _PresetRemoteRuleSet {
  const _PresetRemoteRuleSet({required this.tag, required this.url});
  final String tag;
  final String url;
}

class _OutboundOption {
  const _OutboundOption({required this.label, required this.tag});
  final String label;
  final String tag;
}

final SelectableRule _emptySelectable = SelectableRule(label: '');
