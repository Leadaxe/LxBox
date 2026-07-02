import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/channel.dart';
import '../models/custom_rule.dart';
import '../models/parser_config.dart';
import '../services/rule_set_downloader.dart';
import '../services/selectable_to_custom.dart';
import '../services/settings_storage.dart';
import '../services/template_loader.dart';
import '../widgets/outbound_picker.dart';
import 'channel_edit_screen.dart';
import 'custom_rule_edit_screen.dart';
import 'lazy_persist_mixin.dart';
import 'routing_screen/routing_screen_helpers.dart';
import 'routing_screen/routing_screen_menus.dart';
import 'routing_screen/widgets/custom_rule_tile.dart';
import 'routing_screen/widgets/preset_catalog_tile.dart';
import 'routing_screen/widgets/route_final_tile.dart';
import 'routing_screen/widgets/routing_group_tile.dart';
import 'routing_screen/widgets/routing_tabs.dart';
import 'routing_screen/widgets/srs_status_button.dart';
import 'tun_apps_tab.dart';

part 'routing_screen/routing_srs_cache.dart';

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

class _RoutingScreenState extends State<RoutingScreen>
    with
        WidgetsBindingObserver,
        LazyPersistMixin<RoutingScreen>,
        _RoutingSrsCacheMixin {
  @override
  WizardTemplate? _template;
  @override
  final _channels = <Channel>[]; // §125 — source-of-truth каналов (storage)
  // §219 — кэш опций outbound: _outboundOptions() звался в itemBuilder на КАЖДЫЙ
  // custom-rule tile (N каналов × M правил реконструкций/build). Инвалидируем
  // при любой мутации _channels (_invalidateOutboundOptions).
  List<RoutingOutboundOption>? _cachedOutboundOptions;
  @override
  String _routeFinal = '';
  @override
  final _customRules = <CustomRule>[];
  @override
  final _srsCached = <String>{};      // rule.id → файл есть в кэше
  @override
  final _srsDownloading = <String>{}; // rule.id → идёт загрузка
  @override
  bool _loading = true;
  // §076/§085 R4/§107: staging через LazyPersistMixin (markDirty/stageChanges).

  @override
  SubscriptionController get lazyController => widget.subController;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  // §085 R4 — alias: сохраняет существующие call-sites `_markDirty()`.
  @override
  void _markDirty() => markDirty();


  /// См. [RoutingHelpers.remoteRuleSetsOf].
  @override
  List<PresetRemoteRuleSet> _remoteRuleSetsOf(
    SelectableRule preset, [
    CustomRulePreset? rule,
  ]) =>
      RoutingHelpers.remoteRuleSetsOf(preset, rule);

  /// См. [RoutingHelpers.presetSrsKey].
  @override
  String _presetSrsKey(CustomRulePreset rule, String tag) =>
      RoutingHelpers.presetSrsKey(rule, tag);

  /// См. [RoutingHelpers.presetNeedsDownload].
  @override
  bool _presetNeedsDownload(CustomRulePreset rule, SelectableRule preset) =>
      RoutingHelpers.presetNeedsDownload(rule, preset, _srsCached);

  /// §125 — доступные outbound-опции из включённых каналов (storage). vpn-1
  /// всегда присутствует (required-инвариант). Глобальный ✨auto убран —
  /// каждый канал имеет свой `<tag>-auto`, который опцией роутинга не выставляем
  /// (это внутренняя деталь канала).
  /// §219 — сбросить кэш опций после мутации `_channels`.
  @override
  void _invalidateOutboundOptions() => _cachedOutboundOptions = null;

  List<RoutingOutboundOption> _outboundOptions() {
    final cached = _cachedOutboundOptions;
    if (cached != null) return cached;
    final opts = <RoutingOutboundOption>[
      const RoutingOutboundOption(label: 'direct', tag: 'direct-out'),
    ];
    for (final c in _channels) {
      if (c.enabled || c.isRequired) {
        opts.add(RoutingOutboundOption(
            label: c.label.isNotEmpty ? c.label : c.tag, tag: c.tag));
      }
    }
    // §201 — block всегда доступен (системный), красный как reject; держим
    // его последним в списке.
    opts.add(
        const RoutingOutboundOption(label: 'block', tag: 'block', danger: true));
    _cachedOutboundOptions = opts;
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
      length: 4,
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
              Tab(text: 'Tunnel apps'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // ─── Channels: каналы (CRUD) + default fallback + Auto tuning ───
            RoutingChannelsTab(
              bottomPad: bottomPad,
              groupTiles: _channels.map(_buildChannelTile).toList(),
              channelCount: _channels.length,
              maxChannels: kMaxChannels,
              onAddChannel:
                  _channels.length >= kMaxChannels ? null : _addChannel,
              routeFinalTile: _buildRouteFinalTile(),
            ),

            // ─── Presets: catalog of pre-built rules to copy into Rules ───
            RoutingPresetsTab(
              bottomPad: bottomPad,
              catalogTiles:
                  template.selectableRules.map(_buildPresetCatalogTile).toList(),
            ),

            // ─── Rules: unified custom routing (spec §030) ───
            RoutingRulesTab(
              bottomPad: bottomPad,
              itemCount: _customRules.length,
              onReorder: _onReorderCustomRule,
              itemKey: (i) => ValueKey(_customRules[i].id),
              itemBuilder: _buildCustomRuleTile,
              onAdd: _addCustomRule,
            ),

            // ─── Tunnel apps: §046 OS-level split-tunneling ───
            TunAppsTab(
              homeController: widget.homeController,
              subController: widget.subController,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelTile(Channel channel) {
    return RoutingChannelTile(
      channel: channel,
      nodeCount: _nodeCountFor(channel),
      onToggle: (val) {
        setState(() {
          final i = _channels.indexWhere((c) => c.tag == channel.tag);
          if (i >= 0) _channels[i] = _channels[i].copyWith(enabled: val);
          _invalidateOutboundOptions();
          _markDirty();
        });
      },
      onTap: () => _editChannel(channel),
    );
  }

  /// Кол-во нод канала после regex-фильтра (для subtitle). -1 = снимок нод
  /// недоступен (туннель не поднят).
  int _nodeCountFor(Channel channel) {
    final all = _allNodeTags();
    if (all.isEmpty) return -1;
    if (channel.nodeFilter.isEmpty) return all.length;
    try {
      final re = RegExp(channel.nodeFilter);
      return all.where(re.hasMatch).length;
    } catch (_) {
      return all.length; // невалидный regex → все ноды (как в билдере)
    }
  }

  /// Снимок всех node-тегов подписки из ccGroups (union по группам, без самих
  /// групп). Для live-превью фильтров в редакторе. Пусто = туннель не поднят.
  List<String> _allNodeTags() {
    final groupTags =
        widget.homeController.state.ccGroups.map((g) => g.tag).toSet();
    final seen = <String>{};
    final out = <String>[];
    for (final g in widget.homeController.state.ccGroups) {
      for (final item in g.items) {
        if (groupTags.contains(item.tag)) continue; // это группа, не нода
        if (seen.add(item.tag)) out.add(item.tag);
      }
    }
    return out;
  }

  Future<void> _addChannel() async {
    final created = await SettingsStorage.addChannel();
    if (!mounted) return;
    setState(() {
      _channels.add(created);
      _invalidateOutboundOptions();
    });
    _markDirty();
    _editChannel(created);
  }

  Future<void> _editChannel(Channel channel) async {
    final result = await openChannelEditor(
      context,
      initial: channel,
      canDelete: !channel.isRequired,
      allNodeTags: _allNodeTags(),
    );
    if (result == null || !mounted) return;
    if (result.wasDeleted) {
      // deleteChannel в storage уже перевёл dangling-ссылки на vpn-1.
      await SettingsStorage.deleteChannel(channel.tag);
      if (!mounted) return;
      setState(() {
        _channels.removeWhere((c) => c.tag == channel.tag);
        if (_routeFinal == channel.tag) _routeFinal = 'vpn-1';
        _invalidateOutboundOptions();
      });
      _markDirty();
    } else if (result.saved != null) {
      setState(() {
        final i = _channels.indexWhere((c) => c.tag == channel.tag);
        if (i >= 0) _channels[i] = result.saved!;
        _invalidateOutboundOptions();
      });
      _markDirty();
    }
    // §125 — обновить tag→label кеш для home-dropdown (label мог измениться,
    // канал мог удалиться). stageChanges уже застейджила channels; здесь только
    // освежаем labels в HomeState. Persist канала — flushToDisk на dispose.
    await SettingsStorage.setChannels(_channels, flush: true);
    await widget.homeController.refreshChannelLabels();
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
    return PresetCatalogTile(
      rule: rule,
      existing: existing,
      onCopy: () => _copyPreset(rule, template),
    );
  }

  void _copyPreset(SelectableRule rule, WizardTemplate template) {
    CustomRule cr = selectableRuleToCustom(rule, template);
    // Правила нуждающиеся в SRS-файле добавляются disabled — юзер сначала
    // качает через ☁, потом включает switch (или toggle-on сам auto-
    // download'ит и enable на успехе).
    final needsSrs = cr is CustomRuleSrs ||
        (cr is CustomRulePreset &&
            _remoteRuleSetsOf(rule, cr).isNotEmpty);
    if (needsSrs) cr = cr.withEnabled(false);

    final insertAt = _computeInsertIndex(cr);
    setState(() {
      _customRules.insert(insertAt, cr);
      _markDirty();
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
    return RouteFinalTile(
      options: _outboundOptions(),
      routeFinal: _routeFinal,
      onChanged: (val) {
        setState(() {
          _routeFinal = val;
          _markDirty();
        });
      },
    );
  }

  // ─── Custom Rules (Routing, spec §030) ───

  void _onReorderCustomRule(int oldIndex, int newIndex) {
    setState(() {
      // ReorderableListView передаёт newIndex сдвинутым на 1 если move вниз.
      if (newIndex > oldIndex) newIndex -= 1;
      final moved = _customRules.removeAt(oldIndex);
      _customRules.insert(newIndex, moved);
      _markDirty();
    });
  }

  Widget _buildCustomRuleTile(int index) {
    final rule = _customRules[index];
    final options = _outboundOptions();
    final preset =
        rule.kind == CustomRuleKind.preset ? _presetFor(rule.presetId) : null;
    final subtitle = _ruleSubtitle(rule, preset);
    final pickerValue =
        rule.kind == CustomRuleKind.preset ? _presetOut(rule, preset) : rule.outbound;
    final pickerDisabled =
        rule.kind == CustomRuleKind.preset && preset == null;

    Widget? statusButton;
    if (rule is CustomRuleSrs) {
      statusButton = _srsStatusButton(rule);
    } else if (rule is CustomRulePreset &&
        preset != null &&
        _remoteRuleSetsOf(preset, rule).isNotEmpty) {
      statusButton = _presetSrsStatusButton(rule, preset);
    }

    return CustomRuleTile(
      index: index,
      rule: rule,
      options: options,
      subtitle: subtitle,
      pickerValue: pickerValue,
      pickerDisabled: pickerDisabled,
      statusButton: statusButton,
      onTap: () => _openCustomRuleEditor(index),
      onLongPressStart: (pos) => _showRuleContextMenu(index, pos),
      onSwitchChanged: (v) {
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
          _markDirty();
        });
      },
      onOutboundChanged: (val) {
        setState(() {
          _customRules[index] = rule.withOutbound(val);
          _markDirty();
        });
      },
    );
  }

  Widget _srsStatusButton(CustomRule rule) {
    return SrsStatusButton(
      rule: rule,
      downloading: _srsDownloading.contains(rule.id),
      cached: _srsCached.contains(rule.id),
      onPressed: () => unawaited(_downloadSrs(rule)),
    );
  }

  /// ☁-кнопка для preset-правил с remote rule_set'ами. "cached" = все
  /// remote rule_set'ы пресета имеют локальный `.srs` (spec §011 compliance,
  /// task 011).
  Widget _presetSrsStatusButton(CustomRulePreset rule, SelectableRule preset) {
    return PresetSrsStatusButton(
      rule: rule,
      preset: preset,
      downloading: _srsDownloading.contains(rule.id),
      cached: !_presetNeedsDownload(rule, preset),
      onTap: () => unawaited(_downloadSrsForPresetRule(rule)),
      onLongPress: () async {
        final pos = await _centerOf(context) ?? Offset.zero;
        if (!mounted) return;
        _showPresetCloudMenu(rule, preset, pos);
      },
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
    final action = await showPresetCloudMenu(context, pos);
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
            _markDirty();
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
    final action = await showRuleContextMenu(context, pos);
    if (!mounted) return;
    if (action == 'delete') {
      unawaited(_confirmDeleteCustomRule(index));
    }
  }

  Future<void> _confirmDeleteCustomRule(int index) async {
    final rule = _customRules[index];
    final ok = await showDeleteCustomRuleDialog(context, rule);
    if (ok != true || !mounted) return;
    setState(() {
      _customRules.removeAt(index);
      _srsCached.remove(rule.id);
      _markDirty();
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
        _markDirty();
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
        _markDirty();
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
        _markDirty();
      });
      if (urlChanged || kindChanged) {
        unawaited(RuleSetDownloader.delete(current.id));
      }
    }
  }

  /// Находит bundle-пресет по id в загруженном шаблоне. null если
  /// `_template == null` или пресет отсутствует (broken preset — show error
  /// card в редакторе + skip при сборке).
  @override
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

  String _presetOut(CustomRule rule, SelectableRule? preset) =>
      RoutingHelpers.presetOut(rule, preset);

  String _ruleSubtitle(CustomRule rule, SelectableRule? preset) =>
      RoutingHelpers.ruleSubtitle(rule, preset);

  String _uniqueCustomRuleName(String requested, String selfId) =>
      RoutingHelpers.uniqueCustomRuleName(requested, selfId, _customRules);
}
