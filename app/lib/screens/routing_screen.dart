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

    await _migrateLegacyPresets(template);
    await _refreshSrsCache();

    setState(() {
      _template = template;
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

  /// Обновить `_srsCached` — проверить наличие файла по id для всех srs-правил.
  Future<void> _refreshSrsCache() async {
    _srsCached.clear();
    for (final r in _customRules.where((r) => r.kind == CustomRuleKind.srs)) {
      if (await RuleSetDownloader.isCached(r.id)) _srsCached.add(r.id);
    }
  }

  /// Качает SRS и при успехе включает правило. Вызывается из Switch'а
  /// "включить" по правилу с не-закэшеным SRS — раньше Switch был disabled
  /// и юзеру приходилось сначала тапать ☁ вручную, потом сам Switch.
  Future<void> _enableAfterDownload(CustomRule rule) async {
    await _downloadSrs(rule);
    if (!mounted) return;
    if (!_srsCached.contains(rule.id)) return; // download failed
    final i = _customRules.indexWhere((r) => r.id == rule.id);
    if (i < 0) return; // rule deleted while downloading
    setState(() {
      _customRules[i] = _customRules[i].copyWith(enabled: true);
      _scheduleSave();
    });
  }

  Future<void> _downloadSrs(CustomRule rule) async {
    if (rule.kind != CustomRuleKind.srs) return;
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
    final existing = _customRules.any((c) => c.name == rule.label);
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
                label: Text(existing ? 'In Rules' : 'Copy to Rules'),
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
    var cr = selectableRuleToCustom(rule, template);
    if (cr == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot represent "${rule.label}" as a rule')),
      );
      return;
    }
    // srs-пресет копируется в state "disabled" — юзер сначала качает, потом
    // включает переключатель. Inline можно включать сразу.
    if (cr.kind == CustomRuleKind.srs) cr = cr.copyWith(enabled: false);
    setState(() {
      _customRules.add(cr!);
      _scheduleSave();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(cr.kind == CustomRuleKind.srs
              ? 'Copied "${rule.label}" — tap ☁ to download SRS, then enable'
              : 'Copied "${rule.label}" to Rules')),
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
    final summary = rule.summary;
    final subtitle = summary.isEmpty
        ? 'Tap to add match fields'
        : '$summary — tap to edit';

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
                    if (v &&
                        rule.kind == CustomRuleKind.srs &&
                        !_srsCached.contains(rule.id)) {
                      // SRS ещё не закэшен — качаем, после успеха включаем.
                      unawaited(_enableAfterDownload(rule));
                      return;
                    }
                    setState(() {
                      _customRules[index] = rule.copyWith(enabled: v);
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
                if (rule.kind == CustomRuleKind.srs) _srsStatusButton(rule),
                OutboundPicker(
                  value: rule.target,
                  options: options
                      .map((o) => OutboundOption(value: o.tag, label: o.label))
                      .toList(),
                  onChanged: (val) {
                    setState(() {
                      _customRules[index] = rule.copyWith(target: val);
                      _scheduleSave();
                    });
                  },
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 64, bottom: 4),
              child: Text(subtitle,
                  style: TextStyle(fontSize: 12, color: subtitleColor)),
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
    if (rule.kind == CustomRuleKind.srs) {
      unawaited(RuleSetDownloader.delete(rule.id));
    }
  }

  void _addCustomRule() async {
    final fresh = CustomRule(
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
      setState(() {
        _customRules.add(result.saved!);
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
        final next = (urlChanged || kindChanged)
            ? saved.copyWith(enabled: false)
            : saved;
        _customRules[index] = next;
        if (urlChanged || kindChanged) _srsCached.remove(current.id);
        _scheduleSave();
      });
      if (urlChanged || kindChanged) {
        unawaited(RuleSetDownloader.delete(current.id));
      }
    }
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

class _OutboundOption {
  const _OutboundOption({required this.label, required this.tag});
  final String label;
  final String tag;
}

final SelectableRule _emptySelectable = SelectableRule(label: '');
