import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';

import 'package:file_picker/file_picker.dart' show FileType;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/channel.dart';
import '../models/custom_rule.dart';
import '../models/parser_config.dart';
import '../services/builder/rule_order.dart';
import '../services/channel_mutations.dart';
import '../services/error_format.dart';
import '../services/file_export.dart';
import '../services/file_import.dart';
import '../services/l10n/template_aware_state.dart';
import '../services/preset_on_change.dart';
import '../services/rule_display_names.dart';
import '../services/rule_set_downloader.dart';
import '../services/rule_transfer.dart';
import '../services/selectable_to_custom.dart';
import '../services/settings_storage.dart';
import '../services/template_loader.dart';
import '../services/ui_helpers.dart';
import '../services/url_launcher.dart';
import '../services/utf8_decode.dart';
import '../widgets/export_action_sheet.dart';
import '../widgets/outbound_picker.dart';
import 'channel_edit_screen.dart';
import 'custom_rule_edit_screen.dart';
import 'lazy_persist_mixin.dart';
import 'routing_screen/routing_screen_helpers.dart';
import 'routing_screen/routing_screen_menus.dart';
import 'routing_screen/rule_transfer_dialogs.dart';
import 'routing_screen/widgets/custom_rule_tile.dart';
import 'routing_screen/widgets/preset_catalog_tile.dart';
import 'routing_screen/widgets/route_final_tile.dart';
import 'routing_screen/widgets/routing_group_tile.dart';
import 'routing_screen/widgets/routing_tabs.dart';
import 'routing_screen/widgets/srs_status_button.dart';
import 'tun_apps_tab.dart';
import '../services/l10n/locale_controller.dart';

part 'routing_screen/routing_srs_cache.dart';

class RoutingScreen extends StatefulWidget {
  const RoutingScreen({
    super.key,
    required this.subController,
    required this.homeController,
    this.focusChannelTag,
    this.initialPresetsTab = false,
  });

  final SubscriptionController subController;
  final HomeController homeController;

  /// §258 — при открытии показать канал с этим тегом и мигнуть его тайлом
  /// (навигация «хоп рантайм-цепочки → канал», openTagOwner). null = нет.
  final String? focusChannelTag;

  /// §262 — открыть сразу на табе Presets (каталог пресетов). Навигация из
  /// листа DNS-health «Enable FakeIP» → юзер видит каталог, находит FakeIP.
  final bool initialPresetsTab;

  @override
  State<RoutingScreen> createState() => _RoutingScreenState();
}

class _RoutingScreenState extends State<RoutingScreen>
    with
        WidgetsBindingObserver,
        LazyPersistMixin<RoutingScreen>,
        _RoutingSrsCacheMixin,
        TemplateAwareState<RoutingScreen>,
        SnackHelper<RoutingScreen> {
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
  final _srsCached = <String>{}; // rule.id → файл есть в кэше
  @override
  final _srsDownloading = <String>{}; // rule.id → идёт загрузка
  @override
  bool _loading = true;
  // §076/§085 R4/§107: staging через LazyPersistMixin (markDirty/stageChanges).

  // §258 — подсветка канала при focusChannelTag (навигация из рантайм-цепочки
  // View-экрана). Ключи per-tag: таб Channels — нелениый ListView(children:),
  // тайл смонтирован с первого кадра, retry (§255) не нужен.
  final _channelKeys = <String, GlobalKey>{};
  String? _highlightedChannelTag;
  Timer? _channelHighlightTimer;

  @override
  SubscriptionController get lazyController => widget.subController;

  // §279 — загрузка стартует из onLocaleTemplateFetch (TemplateAwareState):
  // первый вызов (до первого build) — полный _load(); смена локали — только
  // refetch локализованного шаблона (буферы каналов/правил юзера не трогаем;
  // live-label'ы пресетов и каталог перерендерятся из нового _template).
  @override
  void onLocaleTemplateFetch({required bool first}) {
    if (first) {
      unawaited(_load().then((_) => _focusChannelIfAny()));
    } else {
      unawaited(_refetchTemplate());
    }
  }

  Future<void> _refetchTemplate() async {
    final template = await TemplateLoader.load();
    if (!mounted) return;
    setState(() => _template = template);
  }

  @override
  void dispose() {
    _channelHighlightTimer?.cancel();
    super.dispose();
  }

  /// §258 — после загрузки каналов: скролл к focusChannelTag + вспышка 2.2 с
  /// (зеркало _focusMember в folder_detail_screen, §255).
  void _focusChannelIfAny() {
    final tag = widget.focusChannelTag;
    if (tag == null || !mounted) return;
    if (!_channels.any((c) => c.tag == tag)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _highlightedChannelTag = tag);
      final ctx = _channelKeys[tag]?.currentContext;
      if (ctx != null) {
        unawaited(
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            alignment: 0.3,
          ),
        );
      }
      _channelHighlightTimer?.cancel();
      _channelHighlightTimer = Timer(const Duration(milliseconds: 2200), () {
        if (mounted) setState(() => _highlightedChannelTag = null);
      });
    });
  }

  // §085 R4 — alias: сохраняет существующие call-sites `_markDirty()`.
  @override
  void _markDirty() => markDirty();

  /// См. [RoutingHelpers.remoteRuleSetsOf].
  @override
  List<PresetRemoteRuleSet> _remoteRuleSetsOf(
    SelectableRule preset, [
    CustomRulePreset? rule,
  ]) => RoutingHelpers.remoteRuleSetsOf(preset, rule);

  /// См. [RoutingHelpers.presetSrsKey].
  @override
  String _presetSrsKey(CustomRulePreset rule, String tag) =>
      RoutingHelpers.presetSrsKey(rule, tag);

  /// См. [RoutingHelpers.presetNeedsDownload].
  @override
  bool _presetNeedsDownload(CustomRulePreset rule, SelectableRule preset) =>
      RoutingHelpers.presetNeedsDownload(rule, preset, _srsCached);

  /// §219 — сбросить кэш опций после мутации `_channels`.
  @override
  void _invalidateOutboundOptions() => _cachedOutboundOptions = null;

  /// См. [RoutingHelpers.outboundOptions] (семантика списка — там). Глобальный
  /// ✨auto убран — каждый канал имеет свой `<tag>-auto`, который опцией
  /// роутинга не выставляем (это внутренняя деталь канала). Кэш §219
  /// инвалидируется на любой мутации каналов.
  List<RoutingOutboundOption> _outboundOptions() =>
      _cachedOutboundOptions ??= RoutingHelpers.outboundOptions(_channels);

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(getLocalText.s("Routing"))),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final template = _template!;
    final bottomPad = MediaQuery.of(context).padding.bottom + 24;

    return DefaultTabController(
      length: 4,
      // §262 — таб Presets (index 1) первым при навигации из DNS-health листа.
      initialIndex: widget.initialPresetsTab ? 1 : 0,
      child: Builder(
        builder: (tabCtx) => Scaffold(
          appBar: AppBar(
            title: Text(getLocalText.s("Routing")),
            actions: [
              // §396 — меню экспорта/импорта правил. Живёт в AppBar (решение
              // владельца: «⋮ на самом верху, напротив Routing»), но видно
              // только на табе Rules (index 2) — на остальных табах меню про
              // правила сбивало бы с толку. animation (а не index) — чтобы
              // кнопка появлялась уже во время свайпа, а не по его завершении.
              AnimatedBuilder(
                animation: DefaultTabController.of(tabCtx).animation!,
                builder: (_, _) {
                  final onRulesTab =
                      DefaultTabController.of(
                        tabCtx,
                      ).animation!.value.round() ==
                      2;
                  if (!onRulesTab) return const SizedBox.shrink();
                  return RulesMenuButton(
                    canExport: _customRules.isNotEmpty,
                    onExport: _exportRules,
                    onImport: _importRules,
                  );
                },
              ),
            ],
            bottom: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: getLocalText.s("Channels")),
                Tab(text: getLocalText.s("Presets")),
                Tab(text: getLocalText.s("Rules")),
                Tab(text: getLocalText.s("Tunnel apps")),
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
                onAddChannel: _channels.length >= kMaxChannels
                    ? null
                    : _addChannel,
                routeFinalTile: _buildRouteFinalTile(),
              ),

              // ─── Presets: catalog of pre-built rules to copy into Rules ───
              RoutingPresetsTab(
                bottomPad: bottomPad,
                catalogTiles: template.selectableRules
                    .map(_buildPresetCatalogTile)
                    .toList(),
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
      ),
    );
  }

  Widget _buildChannelTile(Channel channel) {
    // §258 — вспышка при focusChannelTag (стиль как у члена папки, §255).
    final cs = Theme.of(context).colorScheme;
    final highlighted = _highlightedChannelTag == channel.tag;
    return AnimatedContainer(
      key: _channelKeys.putIfAbsent(channel.tag, GlobalKey.new),
      duration: const Duration(milliseconds: 200),
      decoration: highlighted
          ? BoxDecoration(
              color: cs.primaryContainer.withValues(alpha: 0.5),
              border: Border(left: BorderSide(color: cs.primary, width: 3)),
            )
          : null,
      child: RoutingChannelTile(
        channel: channel,
        nodeCount: _nodeCountFor(channel),
        onToggle: (val) => unawaited(_toggleChannel(channel, val)),
        onTap: () => _editChannel(channel),
      ),
    );
  }

  /// Вкл/выкл канала. §202/§248 — идёт через storage-API: disable лечит
  /// ссылки покинутых ролей (rules → vpn-1, detour-ссылки → None) и
  /// возвращает счётчики для SnackBar. Storage мутируем ДО локальных
  /// буферов: stageChanges (markDirty) тогда пишет в кэш уже вылеченные
  /// значения, а не затирает их устаревшим буфером экрана.
  Future<void> _toggleChannel(Channel channel, bool val) async {
    final next = channel.copyWith(enabled: val);
    final healed = await ChannelMutations.update(next, widget.subController);
    if (!mounted) return;
    await _resyncHealedRefs(healed);
    if (!mounted) return;
    setState(() {
      final i = _channels.indexWhere((c) => c.tag == channel.tag);
      if (i >= 0) _channels[i] = next;
      _invalidateOutboundOptions();
      _markDirty();
    });
    // enable heal'ов не даёт (нулевые счётчики) — SnackBar молчит.
    _notifyHealed(next, healed, ruleLead: getLocalText.s('disabled'));
  }

  /// §248 — heal мог переписать route_final / custom-rule outbounds в storage
  /// (→ vpn-1); подтягиваем локальные буферы экрана, иначе следующий
  /// stageChanges затёр бы вылеченные значения устаревшим буфером.
  ///
  /// §275 — detour-ссылки живут в `_entries` контроллера (не в буферах
  /// экрана); их зеркальный ресинк делает `ChannelMutations` в той же
  /// операции, что и storage-heal — здесь только буферы экрана.
  Future<void> _resyncHealedRefs(ChannelHealResult healed) async {
    if (healed.rules == 0) return;
    final storedFinal = await SettingsStorage.getRouteFinal();
    _routeFinal = storedFinal.isNotEmpty ? storedFinal : 'vpn-1';
    _customRules
      ..clear()
      ..addAll(await SettingsStorage.getCustomRules());
  }

  /// §248 Q3 — heal молчаливым не бывает: SnackBar со счётчиками вылеченных
  /// ссылок после мутации канала. [ruleLead] — вводная для rules-части
  /// («disabled» / «deleted»; §274 убрал flag-set-heal и его вводную).
  /// Оба счётчика ненулевые → один суммарный SnackBar. Нулевые → тишина.
  void _notifyHealed(
    Channel channel,
    ChannelHealResult healed, {
    required String ruleLead,
  }) {
    if (healed.rules == 0 && healed.detours == 0) return;
    final label = channel.label.isNotEmpty ? channel.label : channel.tag;
    final lead = healed.rules > 0
        ? getLocalText.s('Channel "%1\$s" %2\$s', label, ruleLead)
        : getLocalText.s('Channel "%s" is no longer a detour target', label);
    // §292 — части сообщения из единого форматтера (общий с node_list).
    final parts = ChannelMutations.healMessageParts(healed);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$lead — ${parts.join(', ')}.')));
  }

  /// Кол-во нод канала после regex-фильтра (для subtitle). -1 = снимок нод
  /// недоступен (туннель не поднят).
  int _nodeCountFor(Channel channel) {
    final all = _allNodeTags();
    if (all.isEmpty) return -1;
    if (channel.nodeFilter.isEmpty) return all.length;
    try {
      // §301 — регистронезависимо, как основное окно и билдер.
      final re = RegExp(channel.nodeFilter, caseSensitive: false);
      return all.where(re.hasMatch).length;
    } catch (_) {
      return all.length; // невалидный regex → все ноды (как в билдере)
    }
  }

  /// Снимок всех node-тегов подписки из ccGroups (union по группам, без самих
  /// групп). Для live-превью фильтров в редакторе. Пусто = туннель не поднят.
  List<String> _allNodeTags() {
    final groupTags = widget.homeController.state.ccGroups
        .map((g) => g.tag)
        .toSet();
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
    final created = await ChannelMutations.add();
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
      // deleteChannel в storage лечит ссылки: rules → vpn-1 (§202),
      // detour-ссылки → None (§248). Счётчики — в SnackBar ниже.
      final healed = await ChannelMutations.delete(
        channel.tag,
        widget.subController,
      );
      if (!mounted) return;
      await _resyncHealedRefs(healed);
      if (!mounted) return;
      setState(() {
        _channels.removeWhere((c) => c.tag == channel.tag);
        _invalidateOutboundOptions();
      });
      _markDirty();
      _notifyHealed(channel, healed, ruleLead: getLocalText.s('deleted'));
    } else if (result.saved != null) {
      final saved = result.saved!;
      // §202/§248/§274 — persist канала: disable лечит оба рода ссылок,
      // flag-unset — detour-ссылки; счётчики — в SnackBar ниже.
      // §275 — ChannelMutations зеркалит detour-heal в _entries контроллера.
      final healed = await ChannelMutations.update(saved, widget.subController);
      if (!mounted) return;
      await _resyncHealedRefs(healed);
      if (!mounted) return;
      setState(() {
        final i = _channels.indexWhere((c) => c.tag == channel.tag);
        if (i >= 0) _channels[i] = saved;
        _invalidateOutboundOptions();
      });
      _markDirty();
      // §274 — rules-ссылки лечатся только при disable (flag-set больше не
      // heal-триггер: detour-флаг — разрешение, канал остаётся целью
      // правил). ruleLead поэтому один; detours-часть (flag-unset) свою
      // вводную берёт в _notifyHealed.
      _notifyHealed(saved, healed, ruleLead: getLocalText.s('disabled'));
    }
    // §125 — обновить tag→label кеш для home-dropdown (label мог измениться,
    // канал мог удалиться). stageChanges уже застейджила channels; здесь только
    // освежаем labels в HomeState. Persist канала — flushToDisk на dispose.
    await ChannelMutations.bulkReplace(_channels, flush: true);
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
    final existing =
        rule.presetId.isNotEmpty &&
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
    final needsSrs =
        cr is CustomRuleSrs ||
        (cr is CustomRulePreset && _remoteRuleSetsOf(rule, cr).isNotEmpty);
    if (needsSrs) cr = cr.withEnabled(false);

    // §370 — пресет из каталога садится на свой шаблонный `num`; если тот
    // занят, соседи сдвигаются лениво. Позиция в списке — производная от оси.
    cr.orderNum = rule.num;
    setState(() {
      _customRules.add(cr);
      final sorted = sortRulesByNum(_customRules);
      _customRules
        ..clear()
        ..addAll(sorted);
      _markDirty();
    });
    // §266 — при создании пресета применяем on_change по начальному состоянию
    // (@rule_enable = cr.enabled). FakeIP добавлен включённым → resolve_enabled
    // сразу выставляется согласно положению (q2).
    if (cr is CustomRulePreset) {
      unawaited(applyPresetOnChange(rule, cr));
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          needsSrs
              ? getLocalText.s(
                  "Added \"%s\" — tap ☁ to download, then enable",
                  rule.label,
                )
              : getLocalText.s("Added \"%s\" to Rules", rule.label),
        ),
      ),
    );
  }

  // ─── §396 — экспорт/импорт правил файлом ───────────────────────────────

  Future<void> _exportRules() async {
    if (_customRules.isEmpty) return; // пункт меню и так disabled
    final selected = await showRuleExportPicker(
      context,
      rules: List<CustomRule>.from(_customRules),
      displayNames: ruleDisplayNames(_customRules, _template),
    );
    if (selected == null || selected.isEmpty || !mounted) return;

    try {
      // §374 — доступные способы выясняем до шита; обе проверки платформенные,
      // поэтому параллельно.
      final availability = await Future.wait([
        UrlLauncher.hasRealFilePicker(),
        UrlLauncher.canSaveToDownloads(),
      ]);
      if (!mounted) return;
      final action = await showExportActionSheet(
        context,
        canSaveToFile: availability[0],
        canSaveToDownloads: availability[1],
      );
      if (action == null) return; // юзер закрыл шит

      String? appVersion;
      try {
        final info = await PackageInfo.fromPlatform();
        appVersion = '${info.version}+${info.buildNumber}';
      } catch (_) {
        // PackageInfo может упасть в test environment — graceful skip.
      }
      final json = buildRulesExport(selected, appVersion: appVersion);
      final filename = suggestedRulesFilename();
      // Размер в БАЙТАХ, а не code units (§374: String.length считает UTF-16,
      // на кириллице цифра расходилась с файлом на диске).
      final bytes = utf8.encode(json).length;

      final SaveOutcome outcome;
      switch (action) {
        case ExportAction.saveToFile:
          outcome = await saveFileSafely(fileName: filename, content: json);
        case ExportAction.saveToDownloads:
          outcome = await saveToDownloadsSafely(
            fileName: filename,
            content: json,
          );
        case ExportAction.share:
          // Share требует файл на диске: кэш подходит — получатель копирует
          // его себе, а очистка кэша системой нам не важна.
          final tmpDir = await getTemporaryDirectory();
          final path = '${tmpDir.path}/$filename';
          await File(path).writeAsString(json);
          await Share.shareXFiles([
            XFile(path, mimeType: 'application/json', name: filename),
          ], subject: 'LxBox rules');
          showSnack(getLocalText.plural("Exported %d rules", selected.length));
          return;
      }

      final problem = saveProblemText(outcome);
      if (problem != null) {
        showSnack(problem);
        return;
      }
      switch (outcome) {
        case SavedToFile(:final name):
          showSnack(getLocalText.s("Saved as %s (%d bytes)", name, bytes));
        case SavedToDownloads(:final name):
          showSnack(
            getLocalText.s("Saved to Downloads: %s (%d bytes)", name, bytes),
          );
        case SaveCancelled():
          break; // юзер закрыл диалог сохранения — молчим
        case SaveNoTarget() || SaveFailed():
          break; // покрыто saveProblemText выше
      }
    } catch (e) {
      showSnack(
        getLocalText.s("Export failed: %s", formatUserError(e).render()),
      );
    }
  }

  Future<void> _importRules() async {
    final template = _template;
    if (template == null) return;
    try {
      // §372 — см. pickFileSafely: Android TV без DocumentsUI.
      final outcome = await pickFileSafely(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (outcome is! PickedFiles) {
        final problem = pickProblemText(outcome);
        if (problem != null) showSnack(problem);
        return; // cancelled / нет пикера / сбой
      }
      final file = outcome.single;
      final bytes = file.bytes;
      String? raw;
      if (bytes != null) {
        raw = utf8DecodeOrNull(bytes);
      } else if (file.path != null) {
        raw = await File(file.path!).readAsString();
      }
      if (raw == null) {
        showSnack(getLocalText.s("Could not read file."));
        return;
      }

      final RulesImportContents contents;
      try {
        contents = parseRulesImport(raw);
      } on FormatException catch (e) {
        showSnack(e.message);
        return;
      }

      // Контекст санации: теги ВСЕХ каналов (ссылку на выключенный лечит
      // существующая механика §274/§277) + DNS-теги как в дропдауне §117
      // (`edit_controller._loadDnsServerTags`: storage-refs ∪ template).
      final channelTags = {for (final c in _channels) c.tag};
      final dnsServerTags = <String>{};
      for (final s in await SettingsStorage.getDnsServers()) {
        final tag = s['tag']?.toString();
        if (tag != null && tag.isNotEmpty) dnsServerTags.add(tag);
      }
      dnsServerTags.addAll(template.dnsOptionsModel.servers.map((s) => s.tag));

      final items = [
        for (final entry in contents.rawRules)
          sanitizeImportedRule(
            entry,
            channelTags: channelTags,
            dnsServerTags: dnsServerTags,
            template: template,
          ),
      ];
      if (!mounted) return;
      final picked = await showRuleImportPreview(
        context,
        items: items,
        createdAt: contents.createdAt,
        sourceAppVersion: contents.sourceAppVersion,
      );
      if (picked == null || picked.isEmpty || !mounted) return;

      final inserted = <CustomRule>[];
      var needsSrs = false;
      for (final item in picked) {
        final rule = item.rule;
        if (rule == null) continue;
        inserted.add(
          insertImportedRule(_customRules, rule, template: template),
        );
        needsSrs = needsSrs || item.needsSrsDownload;
      }
      if (inserted.isEmpty) return;
      setState(() {
        final sorted = sortRulesByNum(_customRules);
        _customRules
          ..clear()
          ..addAll(sorted);
        _markDirty();
      });
      // §266 — как _copyPreset: on_change по начальному состоянию пресета.
      for (final cr in inserted) {
        if (cr is CustomRulePreset) {
          final preset = _presetFor(cr.presetId);
          if (preset != null) unawaited(applyPresetOnChange(preset, cr));
        }
      }
      showSnack(
        needsSrs
            ? getLocalText.plural(
                "Imported %d rules — tap ☁ to download rule-sets, then enable",
                inserted.length,
              )
            : getLocalText.plural("Imported %d rules", inserted.length),
      );
    } catch (e) {
      showSnack(
        getLocalText.s("Import failed: %s", formatUserError(e).render()),
      );
    }
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

  /// §370 — drag: правило встаёт СРАЗУ ЗА тем, на чьё место его бросили,
  /// и получает `num = target.num + 1` (ленивый сдвиг соседей, см.
  /// `placeRuleAfter`). Порядок в списке — производная от оси, поэтому после
  /// пересчёта номеров список пересортировывается, а не переставляется руками.
  void _onReorderCustomRule(int oldIndex, int newIndex) {
    setState(() {
      // ReorderableListView передаёт newIndex сдвинутым на 1 если move вниз.
      if (newIndex > oldIndex) newIndex -= 1;
      final moved = _customRules[oldIndex];
      if (!_isSortable(moved)) return; // несортируемое не двигаем
      // Цель — правило, ЗА которым встаём, в списке БЕЗ самого moved:
      // после удаления moved индексы ниже него смещаются, и брать цель из
      // исходного списка нельзя (иначе при движении вниз целью становится
      // элемент, который сам сдвинется). Бросок в начало (newIndex 0) —
      // «перед первым»: target = null, `placeRuleAfter` уводит в начало
      // сортируемой части, несортируемая шапка при этом не двигается.
      final rest = [..._customRules]..removeAt(oldIndex);
      final target = newIndex == 0 ? null : rest[newIndex - 1];
      placeRuleAfter(_customRules, moved, target, isSortable: _isSortable);
      final sorted = sortRulesByNum(_customRules);
      _customRules
        ..clear()
        ..addAll(sorted);
      _markDirty();
    });
  }

  /// §370 — можно ли двигать правило drag'ом. Несортируемые
  /// (`traffic-processing`) держат позицию: они несут `sniff`, который обязан
  /// быть первым правилом `route.rules`. Правило, которого нет в шаблоне
  /// (пользовательское inline/srs/json), сортируемо всегда.
  bool _isSortable(CustomRule rule) {
    if (rule.kind != CustomRuleKind.preset) return true;
    return _presetFor(rule.presetId)?.isSortable ?? true;
  }

  Widget _buildCustomRuleTile(int index) {
    final rule = _customRules[index];
    final options = _outboundOptions();
    final preset = rule.kind == CustomRuleKind.preset
        ? _presetFor(rule.presetId)
        : null;
    final subtitle = _ruleSubtitle(rule, preset);
    final pickerValue = rule.kind == CustomRuleKind.preset
        ? _presetOut(rule, preset)
        : rule.outbound;
    final pickerDisabled = rule.kind == CustomRuleKind.preset && preset == null;
    // DNS-only пресеты (FakeIP: только dns_rule, без routing rule и без
    // var:outbound) роутить нечего — outbound-picker был бы мёртвым.
    // Для user-rule и пресета «not found» picker оставляем (последний
    // рисует warning через pickerDisabled).
    final showOutbound =
        rule.kind != CustomRuleKind.preset ||
        preset == null ||
        preset.hasOutboundAffordance;
    // §231 — трогает ли правило DNS (для чипа «DNS»). Пресет → touchesDns
    // (dns_rule/dns_servers); inline/srs → dnsMirrorActive ИЛИ forceIpv4Active
    // (§256 — оба гейтятся так же, как билдер; не над-репортят при
    // ports/protocols).
    final touchesDns = rule.kind == CustomRuleKind.preset
        ? (preset?.touchesDns ?? false)
        : (rule.dnsMirrorActive || rule.forceIpv4Active);

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
      // §279 (§3.5.1) — live display-имя: label пресета из локализованного
      // шаблона + порядковый суффикс копий; fallback — сохранённый снапшот.
      displayName: ruleDisplayName(rule, _customRules, _template),
      options: options,
      subtitle: subtitle,
      pickerValue: pickerValue,
      pickerDisabled: pickerDisabled,
      showOutbound: showOutbound,
      touchesDns: touchesDns,
      locked: preset?.locked ?? false,
      sortable: _isSortable(rule),
      statusButton: statusButton,
      onTap: () => _openCustomRuleEditor(index),
      onLongPressStart: (pos) => _showRuleContextMenu(index, pos),
      onSwitchChanged: (v) {
        if (v && rule is CustomRuleSrs && !_srsCached.contains(rule.id)) {
          unawaited(_enableAfterDownload(rule));
          return;
        }
        if (v &&
            rule is CustomRulePreset &&
            preset != null &&
            _presetNeedsDownload(rule, preset)) {
          unawaited(_enableAfterDownload(rule));
          return;
        }
        setState(() {
          _customRules[index] = rule.withEnabled(v);
          _markDirty();
        });
        // §266 — toggle пресета меняет @rule_enable → каскад on_change
        // (напр. FakeIP вкл → resolve_enabled off).
        final updated = _customRules[index];
        if (updated is CustomRulePreset && preset != null) {
          unawaited(applyPresetOnChange(preset, updated));
        }
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
    final ok = await showDeleteCustomRuleDialog(
      context,
      rule,
      displayName: ruleDisplayName(rule, _customRules, _template),
    );
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
      // §279 — дедуп по ВИДИМЫМ именам: inline-правило не может взять
      // live-label пресета (display-резолв + снапшоты).
      existingNames: visibleRuleNames(_customRules, _template),
    );
    if (result == null) return;
    if (result.wasDeleted) return; // нечего удалять — только что создали
    if (result.saved != null && mounted) {
      final saved = result.saved!;
      // §370 — новое пользовательское правило уезжает в конец занятой части
      // зоны 1000..1100 (см. `nextUserRuleNum`).
      saved.orderNum = nextUserRuleNum(_customRules);
      setState(() {
        _customRules.add(saved);
        final sorted = sortRulesByNum(_customRules);
        _customRules
          ..clear()
          ..addAll(sorted);
        _markDirty();
      });
    }
  }

  Future<void> _openCustomRuleEditor(int index) async {
    final current = _customRules[index];
    // §279 — дедуп по видимым именам (live-label'ы пресетов + снапшоты).
    final existing = visibleRuleNames(
      _customRules,
      _template,
      excludeId: current.id,
    );
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
      // §279 — display-имя для read-only Name-поля preset-ветки редактора
      // (live-label + порядковый суффикс копии).
      displayName: current.kind == CustomRuleKind.preset
          ? ruleDisplayName(current, _customRules, _template)
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
      final urlChanged =
          current.kind == CustomRuleKind.srs &&
          current.srsUrl.trim() != saved.srsUrl.trim();
      final kindChanged = current.kind != saved.kind;
      setState(() {
        // URL или kind поменялись → старый cached-файл невалидный, правило
        // выключаем до повторного Download.
        final next = (urlChanged || kindChanged)
            ? saved.withEnabled(false)
            : saved;
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
  /// 3. `preset.terminalRule['action']` — template shorthand вроде Block Ads
  ///    (`action: reject`). Отдаём сам `action`; picker интерпретирует
  ///    `reject` как пункт "Reject". §246: terminalRule — терминальный
  ///    элемент rule-массива (промежуточные resolve/sniff пропускаются).
  /// 4. `preset.terminalRule['outbound']` — hardcoded literal (ru-inside →
  ///    `direct-out`).
  /// 5. Fallback `'direct-out'`.
  ///

  String _presetOut(CustomRule rule, SelectableRule? preset) =>
      RoutingHelpers.presetOut(rule, preset);

  String _ruleSubtitle(CustomRule rule, SelectableRule? preset) =>
      RoutingHelpers.ruleSubtitle(rule, preset);

  String _uniqueCustomRuleName(String requested, String selfId) =>
      RoutingHelpers.uniqueCustomRuleName(
        requested,
        selfId,
        _customRules,
        _template,
      );
}
