import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/custom_rule.dart';
import '../models/dns_ref.dart';
import '../services/builder/build_config.dart' show varIntInBounds;
import '../services/builder/post_steps.dart';
import '../services/dns/dns_controller.dart';
import '../services/dns/tailscale_endpoint_options.dart';
import '../services/l10n/template_aware_state.dart';
import '../services/template_loader.dart';
import '../services/preset_nodes_view.dart';
import '../services/preset_on_change.dart';
import '../services/ui_helpers.dart';
import '../services/settings_storage.dart';
import '../vpn/box_vpn_client.dart';
import '../vpn/cc_channel.dart';
import '../widgets/outbound_picker.dart';
import 'dns_server_edit_screen.dart';
import 'dns_settings_screen/dns_server_catalog_screen.dart';
import 'dns_settings_screen/dns_server_copy.dart';
import 'dns_settings_screen/dns_server_delete.dart';
import 'dns_settings_screen/dns_server_resolver.dart';
import 'dns_settings_screen/resolved_server.dart';
import 'dns_settings_screen/user_rule_edit_screen.dart';
import 'dns_settings_screen/widgets/dns_mirror_group_card.dart';
import 'dns_settings_screen/widgets/dns_rule_tile.dart';
import 'dns_settings_screen/widgets/local_resolver_warning_banner.dart';
import 'dns_settings_screen/widgets/merged_server_tile.dart';
import 'dns_settings_screen/widgets/resolver_picker.dart';
import 'lazy_persist_mixin.dart';
import 'routing_screen/routing_screen_menus.dart' show showRuleContextMenu;
import '../services/l10n/locale_controller.dart';

/// §655 — записи вкладки DNS, которых ждёт экран Routing.
///
/// Вкладка DNS и остальные вкладки Routing держат свои буферы и стейджат их в
/// `SettingsStorage._cache` (§107). Вкладка DNS пишет и чужой ей
/// `custom_rules` (переименование сервера, DNS-аспект правила, `dns_enable`
/// пресета), а каскад `on_change` (§266) — глобальные vars. Routing после
/// ухода с вкладки DNS ждёт [settle] и перечитывает свои буферы, иначе его
/// следующий staging затёр бы эти правки. Слушатели (`addListener`)
/// узнают о завершении каждой записи.
class DnsTabWrites extends ChangeNotifier {
  final Set<Future<void>> _pending = {};

  /// Запись в работе: [settle] её дождётся, по завершении — notify.
  void track(Future<void> write) {
    late final Future<void> done;
    done = write.catchError((Object e, StackTrace st) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: e,
        stack: st,
        library: 'dns settings tab',
      ));
    }).whenComplete(() {
      _pending.remove(done);
      notifyListeners();
    });
    _pending.add(done);
  }

  /// Дождаться всех записей, включая начатые во время ожидания.
  Future<void> settle() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }
}

/// DNS Settings (§014, §061 dns-rules-refactor, бывший feature §041).
/// §655 — вкладка экрана Routing (после Rules), своего маршрута нет.
///
/// §061 — DNS rules refactored to first-class named/toggleable model
/// ([DnsRuleRef], §033 виды inline/srs/preset/template). Linear order (free
/// reorder через drag-handle), individual enable/disable, user-rules editable.
///
/// §655 — вкладка не держится живой: каждый вход монтирует её заново и
/// читает хранилище (`_load`), уход с вкладки — dispose с flush'ем
/// [LazyPersistMixin].
class DnsSettingsTab extends StatefulWidget {
  const DnsSettingsTab({
    super.key,
    required this.subController,
    required this.homeController,
    this.writes,
  });

  final SubscriptionController subController;
  final HomeController homeController;

  /// §655 — куда сообщать о записях (staging и прямые записи
  /// `custom_rules`/vars). null — вкладка вне Routing (тесты).
  final DnsTabWrites? writes;

  @override
  State<DnsSettingsTab> createState() => _DnsSettingsTabState();
}

class _DnsSettingsTabState extends State<DnsSettingsTab>
    with
        WidgetsBindingObserver,
        LazyPersistMixin<DnsSettingsTab>,
        TemplateAwareState<DnsSettingsTab> {
  @override
  SubscriptionController get lazyController => widget.subController;

  /// §043: kind-discriminated refs (резолвер `resolveDnsServersList`):
  /// - [DnsServerInline]   — user-defined OR override
  /// - [DnsServerTemplate] — ref на template-server
  /// - [DnsServerPreset]   — ref на active preset's server
  ///
  /// Body для `template`/`preset` берётся из [_templateByTag] / [_presetServersByTag]
  /// в [_displayedServers].
  List<DnsServerRef> _servers = [];

  /// §043: Tag → template-server map. Lookup canonical body для
  /// `kind: template` ref'ов и для override-detection.
  Map<String, Map<String, dynamic>> _templateByTag = {};

  /// §043: Tag → preset-server map. Lookup canonical body для `kind: preset`
  /// ref'ов и для override-detection. preset > template на tag-collision.
  Map<String, Map<String, dynamic>> _presetServersByTag = {};

  /// §061 + §032: structured rules list.
  List<DnsRuleRef> _rules = [];

  /// Name-keyed map: template defaults from wizard_template.json
  /// (used to render content for `kind: template` rows).
  Map<String, Map<String, dynamic>> _templateRulesByName = {};

  /// PresetId-keyed map: expanded `dns_rule` from active preset
  /// CustomRulePreset entries (used to render content for `kind: preset` rows).
  /// §032: pivot moved from preset.label to preset.preset_id (immutable).
  Map<String, List<Map<String, dynamic>>> _presetRulesByPresetId = {};

  /// PresetId → label map для UI render'а title'а у `kind: preset` строк.
  /// Live lookup: storage хранит presetId, UI отображает текущий label.
  Map<String, String> _presetLabelByPresetId = {};

  /// §578 — пресет с `for_each_node` → обслуживаемые узлы (подпись строки).
  Map<String, List<String>> _presetServedTagsByPresetId = {};

  /// §117: Направления для `type: outbound` vars DNS-серверов — Direct + активные
  /// Направления (решение №2). Активность = как в `_buildPresetGroups`:
  /// stored enabled_groups (или default_enabled при пустом) + vpn-1 всегда.
  List<OutboundOption> _outboundOptions = const [];

  /// §117 задача 3: routing-правила (storage order) — источник mirror-группы
  /// (DNS-mirror'ы inline/srs правил) и lifecycle-локов «used by <правило>».
  List<CustomRule> _customRules = const [];

  /// §117: эмитимые DNS-rule тела каждого rule-источника mirror'а (ключ —
  /// `cr.id`) для read-only превью по тапу. Реальный билд через
  /// [applyAllCustomRules] (тот же тег rule_set, что в финальном конфиге).
  /// §257: правило может нести ДВА mirror'а (server + serverless Force IPv4)
  /// — значение стало списком (раньше Map→entry терял второй mirror).
  Map<String, List<DnsMirrorEntry>> _dnsMirrorsByRuleId = const {};

  /// §257: состояние магической var `dns_enable` активных пресетов.
  /// Ключ — presetId; null-отсутствие ключа = пресет var не объявляет
  /// (тумблера нет, DNS-блок жив пока routing on).
  Map<String, bool> _presetDnsEnable = const {};

  /// §435/§575 — узлы Tailscale для пикера `endpoint` в форме DNS-сервера:
  /// перечень узлов источников на момент открытия редактора.
  List<TailscaleEndpointOption> get _tailscaleEndpoints =>
      collectTailscaleEndpointOptions(
        [for (final e in widget.subController.entries) e.list],
        lastEmittedTagMap: widget.subController.lastEmittedTagMap,
      );

  bool _loading = true;
  // §076/§085 R4/§107: staging через LazyPersistMixin (markDirty/stageChanges).

  String _strategy = '';
  String _dnsFinal = '';
  String _defaultResolver = '';

  // §580 — кэш DNS (`dns_cache_capacity`, `dns_optimistic`, `dns_store_cache`).
  String _cacheCapacity = '';
  bool _optimistic = true;
  bool _storeCache = true;

  /// §643 (TEMPLATE_LANG §6.9) — `dns_resolver_no_stale`:
  /// `route.default_domain_resolver.disable_optimistic_cache`.
  bool _resolverNoStale = true;
  String _cacheCapacityError = '';
  final TextEditingController _cacheCapacityCtl = TextEditingController();

  @override
  void dispose() {
    _cacheCapacityCtl.dispose();
    super.dispose();
  }

  /// §580 — ввод размера кэша: вне границ не сохраняется, поле показывает
  /// ошибку с границами.
  void _applyCacheCapacity(String raw) {
    final v = raw.trim();
    if (!varIntInBounds('dns_cache_capacity', v)) {
      setState(() => _cacheCapacityError =
          getLocalText.s("Range 1024..65535"));
      return;
    }
    setState(() {
      _cacheCapacityError = '';
      if (v == _cacheCapacity) return;
      _cacheCapacity = v;
      _markDirty();
    });
  }

  // §279 — _load() стартует из onLocaleTemplateFetch (TemplateAwareState):
  // первый вызов — до первого build; смена локали — повторный _load()
  // (безопасно: буферы экрана staged в SettingsStorage-кэш на каждую мутацию
  // через markDirty→stageChanges, перечитывание вернёт их же, а
  // template-derived display-данные — описания серверов, label'ы пресетов —
  // пере-дерайвятся из свежелокализованного шаблона).
  @override
  void onLocaleTemplateFetch({required bool first}) {
    unawaited(_load());
    // §312 — pull live-состояния DNS-групп на открытии экрана (решение №2:
    // без таймера). Смена локали дёргает повторно — снапшот дешёвый.
    if (first) unawaited(_pullDnsGroups());
  }

  // §085 R4 — alias: сохраняет существующие call-sites `_markDirty()`.
  void _markDirty() => markDirty();

  /// §655 — запись, которую Routing дождётся перед перечитыванием буферов.
  void _track(Future<void> write) {
    final writes = widget.writes;
    if (writes == null) {
      unawaited(write);
    } else {
      writes.track(write);
    }
  }

  Future<void> _load() async {
    // §300 — вся read+derive-логика вынесена в DnsController.load() (тело
    // verbatim + типизация краёв §294). Экран только присваивает snapshot.
    // §578/§643 — узлы для пресетов с обходом узлов: тот же отбор, что у
    // строки пресета на экране маршрутов.
    final template = await TemplateLoader.load();
    final s = await DnsController.load(
      presetNodes: presetNodesForView(
        [for (final e in widget.subController.entries) e.list],
        nodeTypes: presetLoopNodeTypes(template.selectableRules),
        lastEmittedTagMap: widget.subController.lastEmittedTagMap,
      ),
    );
    if (!mounted) return;
    setState(() {
      _servers = s.servers;
      _templateByTag = s.templateByTag;
      _presetServersByTag = s.presetServersByTag;
      _rules = s.rules;
      _templateRulesByName = s.templateRulesByName;
      _presetRulesByPresetId = s.presetRulesByPresetId;
      _presetLabelByPresetId = s.presetLabelByPresetId;
      _presetServedTagsByPresetId = s.presetServedTagsByPresetId;
      _presetDnsEnable = s.presetDnsEnable;
      _outboundOptions = s.outboundOptions;
      _customRules = s.customRules;
      _dnsMirrorsByRuleId = s.dnsMirrorsByRuleId;
      _strategy = s.strategy;
      _dnsFinal = s.dnsFinal;
      _defaultResolver = s.defaultResolver;
      _cacheCapacity = s.cacheCapacity;
      _optimistic = s.optimistic;
      _storeCache = s.storeCache;
      _resolverNoStale = s.resolverNoStale;
      _cacheCapacityError = '';
      _cacheCapacityCtl.text = s.cacheCapacity;
      _loading = false;
    });
    // §121: исчезнувший resolver-tag сброшен → persist (config dirty).
    if (s.resolverReset) _markDirty();
  }

  /// §107: staging — буфер экрана в `_cache` на каждую мутацию; дисковый
  /// flush — mixin'ом (flushToDisk) на dispose/paused.
  @override
  Future<void> stageChanges() {
    final staging = _stage();
    widget.writes?.track(staging);
    return staging;
  }

  Future<void> _stage() async {
    // §300 D3 — staged-запись через DnsController.stage (byte-identical).
    // custom_rules НЕ входит (это §295, device). §076: configDirty уже true.
    await DnsController.stage(
      servers: _servers,
      rules: _rules,
      templateRulesByName: _templateRulesByName,
      presetRulesByPresetId: _presetRulesByPresetId,
      strategy: _strategy,
      dnsFinal: _dnsFinal,
      defaultResolver: _defaultResolver,
      cacheCapacity: _cacheCapacity,
      optimistic: _optimistic,
      storeCache: _storeCache,
      resolverNoStale: _resolverNoStale,
    );
  }

  /// §117 задача 3: tag → имя routing-правила с активной DNS-опцией —
  /// lifecycle-лок серверов («used by <правило>», тоггл/delete блокированы).
  Map<String, String> get _ruleRefsByTag => {
        for (final cr in _customRules)
          if (cr.dnsMirrorActive)
            cr.dns!.serverTag: cr.name.isNotEmpty ? cr.name : 'rule',
      };

  /// §044: render list — typed `ResolvedServer` для каждой ref-записи.
  /// §680 — + ссылки из самого списка (группы, domain_resolver, пикеры
  /// DNS Final / Default Domain Resolver ниже на вкладке).
  List<ResolvedServer> get _displayedServers => resolveDisplayedServers(
        _servers,
        _templateByTag,
        _presetServersByTag,
        ruleRefsByTag: _ruleRefsByTag,
        dnsFinal: _dnsFinal,
        defaultResolver: _defaultResolver,
        dnsFinalLabel: getLocalText.s("DNS Final"),
        defaultResolverLabel: getLocalText.s("Default Domain Resolver"),
      );

  /// Tags доступные в dropdown'ах (DNS Final / Default Resolver / per-rule).
  /// Filter `enabled` на ref-level.
  List<String> get _enabledServerTags => enabledServerTags(_displayedServers);

  /// §312 — опции пикера членов DNS-группы: ВСЕ серверы (disabled видимы и
  /// помечаются — drop-семантика №3), кроме fakeip/hosts (запрет ядра).
  /// Self-исключение делает сама секция формы (знает актуальный tag).
  List<DnsMemberOption> get _dnsMemberOptions => [
        for (final s in _displayedServers)
          if (s.body['type'] != 'fakeip' && s.body['type'] != 'hosts')
            DnsMemberOption(
              tag: s.tag,
              type: s.body['type']?.toString() ?? '',
              enabled: dnsServerRefEmitted(
                enabled: s.enabled,
                presetReferenced: s.lockedByPreset,
                ruleReferenced: s.usedByRule != null,
              ),
            ),
      ];

  /// §312 — live-состояние DNS-групп от ядра (pull на открытии экрана,
  /// решение №2). Пусто = туннель down / ядро без метода / групп нет.
  Map<String, CcDnsGroup> _liveDnsGroups = const {};

  Future<void> _pullDnsGroups() async {
    if (!widget.homeController.state.tunnelUp) return;
    final groups = await CcChannel.instance.getDnsGroups();
    if (!mounted || groups == null) return;
    setState(() {
      _liveDnsGroups = {for (final g in groups) g.tag: g};
    });
  }

  /// §680: «+» → страница «Add DNS server»: каталог шаблона и строка
  /// «Custom server» (inline-редактор [_addServer]). Add дописывает
  /// шаблонную запись в конец списка и ставит dirty, страница остаётся.
  Future<void> _openCatalog() async {
    final result = await Navigator.of(context).push<DnsServerCatalogResult>(
      MaterialPageRoute(
        builder: (_) => DnsServerCatalogScreen(
          templateServers: _templateByTag.values.toList(),
          presentTags: {for (final s in _servers) s.tag},
          onAdd: (refs) {
            if (!mounted) return;
            setState(() {
              for (final r in refs) {
                if (_servers.any((s) => s.tag == r.tag)) continue;
                _servers.add(r);
              }
              _markDirty();
            });
          },
        ),
      ),
    );
    if (result == DnsServerCatalogResult.custom && mounted) {
      await _addServer();
    }
  }

  /// §117 задача 4: строка «Custom server» каталога (§680) → полноэкранный
  /// редактор в new-режиме (kind inline).
  /// Заготовка — форма UDP с пустым адресом (save требует ввода); порт/
  /// detour отсутствуют — ключи появляются только при явном выборе.
  /// §682 — [initial]: заготовка Duplicate (копия шаблонного/пресетного
  /// сервера), открывается тем же редактором нового сервера.
  Future<void> _addServer({DnsServerInline? initial}) async {
    final result = await openDnsServerEditor(
      context,
      initialRef: initial ??
          DnsServerInline(
            enabled: true,
            tag: 'dns_new',
            // §279 seed-time-локализация: метка резолвится через активную
            // локаль в момент создания (дальше — user data, ретроактивно не
            // мигрируется).
            description: getLocalText.s("My DNS"),
            body: const <String, dynamic>{'type': 'udp'},
          ),
      outboundOptions: _outboundOptions,
      dnsServerTags: _enabledServerTags,
      dnsMemberOptions: _dnsMemberOptions,
      tailscaleEndpoints: _tailscaleEndpoints, // §435
      existingTags: {for (final s in _servers) s.tag},
    );
    if (result == null || !mounted) return;
    final saved = result.saved;
    if (saved == null) return;
    setState(() {
      // Tag conflict: replace existing (юзер подтвердил в редакторе).
      _servers.removeWhere((s) => s.tag == saved.tag);
      _servers.add(saved);
      _markDirty();
    });
  }

  /// §117 задача 4: тап по тайлу → полноэкранный редактор (Params/JSON).
  /// Reset-to-canonical и Delete — AppBar-actions редактора, результат
  /// приходит сюда единым `DnsServerEditResult`.
  Future<void> _editServer(String tag) async {
    final idx = _servers.indexWhere((s) => s.tag == tag);
    if (idx < 0) return;
    ResolvedServer? resolved;
    for (final s in _displayedServers) {
      if (s.tag == tag) {
        resolved = s;
        break;
      }
    }
    if (resolved == null) return; // orphan/malformed — нечего редактировать

    final canonicalDescription = switch (resolved.kind) {
      ServerKind.template =>
        _templateByTag[tag]?['description']?.toString() ?? '',
      ServerKind.preset =>
        _presetServersByTag[tag]?['description']?.toString() ?? '',
      ServerKind.inline => '',
    };

    final result = await openDnsServerEditor(
      context,
      initialRef: _servers[idx],
      resolved: resolved,
      templateWrapper:
          resolved.kind == ServerKind.template ? _templateByTag[tag] : null,
      canonicalDescription: canonicalDescription,
      outboundOptions: _outboundOptions,
      // §117: dom_resolver-пикер — теги без самого сервера (петля).
      dnsServerTags: _enabledServerTags.where((t) => t != tag).toList(),
      dnsMemberOptions: _dnsMemberOptions,
      tailscaleEndpoints: _tailscaleEndpoints, // §435
      // §117 задача 4b: rename-коллизии (без текущего тега).
      existingTags: {
        for (final s in _servers)
          if (s.tag != tag) s.tag,
      },
    );
    if (result == null || !mounted) return;
    // §682 — Duplicate: копия открывается редактором нового сервера.
    if (result.duplicate case final dup?) {
      await _addServer(initial: dup);
      return;
    }
    setState(() {
      if (result.copy case final copy?) {
        // §682 — «Save as copy»: оригинал и ссылки на него не трогаются.
        _servers.add(copy);
      } else if (result.wasDeleted) {
        _servers.removeAt(idx);
      } else if (result.saved != null) {
        _servers[idx] = result.saved!;
        // §117 задача 4b: rename → каскад по ссылкам, чтобы не орфанить
        // (DNS-правила, resolvers, domain_resolver'ы, DNS-опции правил).
        final newTag = result.saved!.tag;
        if (newTag.isNotEmpty && newTag != tag) {
          final updated = renameDnsServerTagRefs(
            servers: _servers,
            rules: _rules,
            templateByTag: _templateByTag,
            oldTag: tag,
            newTag: newTag,
            dnsFinal: _dnsFinal,
            defaultResolver: _defaultResolver,
          );
          _dnsFinal = updated.dnsFinal;
          _defaultResolver = updated.defaultResolver;
          final renamed = renameRuleDnsServerTag(_customRules, tag, newTag);
          if (!identical(renamed, _customRules)) {
            _customRules = renamed;
            // custom_rules — чужой этой вкладке storage (routing), staged
            // персистом LazyPersistMixin не покрывается — пишем сразу;
            // Routing перечитает буфер после ухода с вкладки (§655).
            _track(SettingsStorage.saveCustomRules(renamed));
          }
        }
      } else {
        return;
      }
      _markDirty();
    });
  }

  void _addUserRule() => _showUserRuleEditor(-1);

  /// §033: identity записи для reorder-ключа и диалога удаления — name
  /// (inline/template/srs) или presetId (preset).
  static String _ruleIdentity(DnsRuleRef r) => switch (r) {
        DnsRuleInline(:final name) ||
        DnsRuleSrs(:final name) ||
        DnsRuleTemplate(:final name) =>
          name,
        DnsRulePreset(:final presetId) => presetId,
      };

  /// §117 задача 3: routing-правила с активным DNS-mirror'ом (routing order).
  List<CustomRule> get _ruleMirrors =>
      [
        for (final cr in _customRules)
          // §683 — Answer = Fixed IP тоже даёт DNS-правило группы.
          if (cr.dnsMirrorActive || cr.dnsFixedActive) cr,
      ];

  /// §117 (решение №6): display-модель списка DNS-правил. Элемент ≥0 —
  /// индекс standalone-записи в [_rules]; `-1` — атомарная mirror-группа
  /// (kind:preset записи + rule-mirror'ы, порядок = routing-правила).
  /// Якорь группы зеркалит эмиссию `applyCustomDns`: первая kind:preset
  /// запись → иначе перед template-блоком → иначе в конец.
  List<int> get _ruleDisplayRows {
    final hasGroup =
        _rules.any((e) => e is DnsRulePreset) || _ruleMirrors.isNotEmpty;
    final rows = <int>[];
    var groupInserted = false;
    for (var i = 0; i < _rules.length; i++) {
      final entry = _rules[i];
      if (entry is DnsRulePreset) {
        if (!groupInserted) {
          rows.add(-1);
          groupInserted = true;
        }
        continue;
      }
      if (entry is DnsRuleTemplate && hasGroup && !groupInserted) {
        rows.add(-1);
        groupInserted = true;
      }
      rows.add(i);
    }
    if (hasGroup && !groupInserted) rows.add(-1);
    return rows;
  }

  /// §117: содержимое mirror-группы в порядке routing-правил: preset-записи
  /// (§061-тайлы, toggle работает, drag нет) + read-only mirror-строки
  /// inline/srs правил с DNS-опцией.
  List<Widget> _buildMirrorGroupChildren() {
    final presetIdxByPid = <String, int>{};
    for (var i = 0; i < _rules.length; i++) {
      final entry = _rules[i];
      if (entry is DnsRulePreset) presetIdxByPid[entry.presetId] = i;
    }
    final children = <Widget>[];
    final seenPresetIds = <String>{};
    for (final cr in _customRules) {
      if (cr is CustomRulePreset) {
        // §117: preset-источник DNS-аспекта — единый [DnsMirrorTile].
        // §257: switch тогглит магическую var `dns_enable` пресета
        // (единственный тумблер DNS-блока; запись в `_rules` — только
        // позиционный якорь, её `enabled` мёртв). Пресет без var —
        // строка без свитча (DNS жив, пока routing on).
        final idx = presetIdxByPid[cr.presetId];
        if (idx == null || !seenPresetIds.add(cr.presetId)) continue;
        final dnsEnable = _presetDnsEnable[cr.presetId];
        children.add(DnsMirrorTile(
          key: ValueKey('dns-rule-preset-${cr.presetId}'),
          title: _presetLabelByPresetId[cr.presetId] ?? cr.presetId,
          // §253: пресет может нести несколько DNS-правил — тайл один,
          // switch тогглит блок атомарно, превью показывает все тела.
          previewBodies: _presetRulesByPresetId[cr.presetId] ?? const [],
          sourceKind: 'preset',
          enabled: dnsEnable ?? true,
          onToggle: dnsEnable == null
              ? null
              : (v) => _togglePresetDnsEnable(cr.presetId, v),
          // §578 — пресет с `for_each_node`: какие узлы он обслуживает.
          note: switch (_presetServedTagsByPresetId[cr.presetId]) {
            final List<String> tags => presetServedNodesLabel(tags),
            null => null,
          },
        ));
      } else {
        // §257: объединённый блок DNS-аспектов правила — заголовок = имя,
        // под-строки «Server» (RuleDns.enabled) и «Force IPv4»
        // (RuleDns.forceIpv4), каждая со своим свитчем. Блок виден, когда
        // настроен ХОТЬ ОДИН аспект — Force IPv4-правило без dedicated-
        // сервера больше не невидимка (гейт не требует serverTag).
        // §683 — при Answer = Fixed IP строки сервера нет: режимы
        // взаимоисключающие, ответ даёт само правило.
        final hasFixedAspect = cr.dnsFixedActive;
        final hasServerAspect =
            cr.dnsMirrorEligible && !hasFixedAspect; // serverTag настроен
        // Вариант A (решение владельца): Force-строка — только когда галка
        // РЕАЛЬНО стоит (forceIpv4Active), не у любого eligible-правила.
        // Правило с одним сервером не тащит пустой Force-тумблер; включают
        // Force в редакторе правила.
        final hasForceAspect = cr.forceIpv4Active;
        if (!hasServerAspect && !hasForceAspect && !hasFixedAspect) continue;
        final mirrors = _dnsMirrorsByRuleId[cr.id] ?? const <DnsMirrorEntry>[];
        Map<String, dynamic>? serverBody;
        Map<String, dynamic>? forceBody;
        Map<String, dynamic>? fixedBody;
        for (final m in mirrors) {
          if (m.fixedAnswer) {
            // §683 — тело с адресами (A или AAAA) — для диалога по тапу.
            if (m.body.containsKey('answer')) fixedBody ??= m.body;
          } else if (m.serverless) {
            forceBody ??= m.body;
          } else {
            serverBody ??= m.body;
          }
        }
        final missing =
            !_servers.any((s) => s.tag == (cr.dns?.serverTag ?? ''));
        children.add(DnsRuleAspectsTile(
          key: ValueKey('dns-mirror-${cr.id}'),
          title: cr.name,
          serverRow: hasServerAspect
              ? DnsAspectRow(
                  body: <String, dynamic>{
                    ...?serverBody,
                    'server': cr.dns!.serverTag,
                  },
                  enabled: cr.dns!.enabled,
                  onToggle: (v) => _toggleRuleDns(cr, v),
                  note: [
                    if (cr is CustomRuleSrs) getLocalText.s("matches only domains in the rule-set"),
                    if (missing) getLocalText.s("server missing"),
                  ].join(' · '),
                )
              : null,
          // §257: Force-строка только когда галка стоит (вариант A). У неё
          // НЕ свитч, а крестик-удаление (снял = убрал, помнить нечего).
          // Убрав Force и не имея server-аспекта → правило уходит из секции
          // (_toggleRuleForceIpv4(false) обнуляет dns). Галка активна →
          // serverless-mirror собран → forceBody не null (fallback defensive).
          // §683 — Answer = Fixed IP: ✕ = Answer → Default (адреса
          // остаются в правиле).
          fixedIpRow: hasFixedAspect
              ? DnsAspectRow(
                  body: fixedBody ?? const <String, dynamic>{},
                  enabled: true,
                  // l10n-exempt: sing-box wire fields
                  preview: 'action: predefined · answer: '
                      '${cr.dns!.fixedIps.join(', ')}',
                  note: cr is CustomRuleSrs
                      ? getLocalText.s("matches only domains in the rule-set")
                      : null,
                  onRemove: () => _removeRuleFixedIp(cr),
                )
              : null,
          forceIpv4Row: hasForceAspect
              ? DnsAspectRow(
                  body: forceBody ??
                      const <String, dynamic>{
                        'ip_version': 6,
                        'action': 'predefined',
                        'rcode': 'NOERROR',
                      },
                  enabled: true,
                  onRemove: () => _toggleRuleForceIpv4(cr, false),
                )
              : null,
        ));
      }
    }
    return children;
  }

  /// §117 (решение №6): reorder в display-пространстве — группа двигается
  /// как одна единица, standalone-правила не могут попасть внутрь неё.
  /// Вызывается из `onReorderItem`: newIndex уже приведён к списку БЕЗ
  /// перетаскиваемого элемента, поэтому сдвига «-1 при move вниз» здесь нет.
  void _onReorderRules(int oldIndex, int newIndex) {
    final rows = _ruleDisplayRows;
    if (oldIndex < 0 || oldIndex >= rows.length) return;
    final presetBlock = [
      for (final e in _rules)
        if (e is DnsRulePreset) e,
    ];
    final units = <List<DnsRuleRef>>[
      for (final r in rows) r == -1 ? presetBlock : [_rules[r]],
    ];
    final moved = units.removeAt(oldIndex);
    units.insert(newIndex.clamp(0, units.length), moved);
    setState(() {
      _rules
        ..clear()
        ..addAll([for (final u in units) ...u]);
      _markDirty();
    });
  }

  Future<void> _showUserRuleEditor(int index) async {
    final isNew = index < 0;
    // Редактор открывается только у inline-тайла (DnsRuleTile).
    final existing = isNew ? null : _rules[index] as DnsRuleInline;
    // §626 ревизия 2 — полноэкранный редактор вместо шторки.
    final entry = await openUserRuleEditor(context, existing: existing);
    if (entry == null || !mounted) return;
    setState(() {
      if (isNew) {
        // Default order: user > preset > template — новые user
        // правила добавляются в начало (юзер всегда может
        // перетащить в любое место drag-handle'ом).
        _rules.insert(0, entry);
      } else {
        _rules[index] = entry;
      }
      _markDirty();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final theme = Theme.of(context);
    // §219 — цепочки геттеров вычисляем ОДИН раз за build (каждый заново
    // прогонял _customRules/_rules): _displayedServers→_ruleRefsByTag→
    // _customRules, _ruleMirrors, _ruleDisplayRows звались по 2-3 раза.
    final displayed = _displayedServers;
    final serverTags = enabledServerTags(displayed);
    // §384 — опции DNS Final / Default Domain Resolver: ядро запрещает там
    // fakeip/hosts (`default server cannot be fakeip` — фатально на старте),
    // тот же запрет, что §312 держит для членов групп. Per-rule пикеры и
    // прочие потребители `serverTags` не трогаем: в правиле fakeip законен.
    final resolverTags = [
      for (final s in displayed)
        if (serverTags.contains(s.tag) &&
            s.body['type'] != 'fakeip' &&
            s.body['type'] != 'hosts')
          s.tag,
    ];
    final mirrors = _ruleMirrors;
    final rows = _ruleDisplayRows;

    return ListView(
      padding: EdgeInsets.fromLTRB(12, 12, 12, MediaQuery.of(context).padding.bottom + 24),
      children: [
        // --- Servers ---
        Row(
          children: [
            Text(getLocalText.s("DNS Servers"),
                style: theme.textTheme.titleMedium),
            const Spacer(),
            IconButton(icon: const Icon(Icons.add), onPressed: _openCatalog),
          ],
        ),
        const SizedBox(height: 4),
        // §042: единый render через 3-tier merged list. §117 задача 4:
        // тайл — только switch + тап→полноэкранный редактор.
        ...displayed.map((entry) => MergedServerTile(
              entry: entry,
              onToggleEnabled: _toggleServerEnabled,
              onTap: _editServer,
              onLongPressStart: _showServerContextMenu,
              liveGroup: _liveDnsGroups[entry.tag], // §312
            )),
        const Divider(height: 32),

        // --- Strategy ---
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(getLocalText.s("Strategy")),
          trailing: DropdownButton<String>(
            value: ['prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'].contains(_strategy)
                ? _strategy : 'ipv4_only',
            items: const [
              DropdownMenuItem(value: 'prefer_ipv4', child: Text('prefer_ipv4')), // l10n-exempt: sing-box wire value
              DropdownMenuItem(value: 'prefer_ipv6', child: Text('prefer_ipv6')), // l10n-exempt: sing-box wire value
              DropdownMenuItem(value: 'ipv4_only', child: Text('ipv4_only')), // l10n-exempt: sing-box wire value
              DropdownMenuItem(value: 'ipv6_only', child: Text('ipv6_only')), // l10n-exempt: sing-box wire value
            ],
            onChanged: (v) { if (v != null) setState(() { _strategy = v; _markDirty(); }); },
          ),
        ),

        const Divider(height: 32),

        // --- DNS Rules (§061 dns-rules-refactor) ---
        Row(
          children: [
            Text(getLocalText.s("DNS Rules"), style: theme.textTheme.titleMedium),
            const Spacer(),
            TextButton.icon(
              onPressed: _addUserRule,
              icon: const Icon(Icons.add, size: 18),
              label: Text(getLocalText.s("Add user rule")),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (_rules.isEmpty && mirrors.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              getLocalText.s("No DNS rules. Add user rules manually, or enable presets / template defaults."),
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
          )
        else
          // §117 (решение №6): display-модель — standalone-записи +
          // атомарная mirror-группа одним элементом (см. _ruleDisplayRows).
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: rows.length,
            onReorderItem: _onReorderRules,
            itemBuilder: (ctx, i) {
              final row = rows[i];
              if (row == -1) {
                // Группа draggable только при наличии preset-якорей —
                // иначе позицию не во что персистить.
                final draggable = _rules.any((e) => e is DnsRulePreset);
                return DnsMirrorGroupCard(
                  key: const ValueKey('dns-mirror-group'),
                  dragIndex: draggable ? i : null,
                  children: _buildMirrorGroupChildren(),
                );
              }
              return DnsRuleTile(
                index: row,
                dragIndex: i,
                entry: _rules[row],
                templateRulesByName: _templateRulesByName,
                presetRulesByPresetId: _presetRulesByPresetId,
                presetLabelByPresetId: _presetLabelByPresetId,
                onToggleEnabled: _toggleRuleEnabled,
                onEdit: _showUserRuleEditor,
                onDelete: _deleteRule,
                // §033: identity для reorder — name (inline/template/srs)
                // или presetId (preset). Нужно стабильное непустое значение.
                key: ValueKey(
                  'dns-rule-$row-${_ruleIdentity(_rules[row])}',
                ),
              );
            },
          ),
        const Divider(height: 32),

        // --- Final ---
        // §048/§047 tooltip — `dns.final` — catch-all для app's DNS queries
        // (когда не match'ит ни один rule). `local_dns_resolver` тут БЕЗОПАСЕН:
        // app's queries не recurse через TUN потому что system resolver
        // вызывается через protected JNI path для apps. Encrypted options
        // (`google_doh`, `*_dot`) рекомендуем для privacy.
        ResolverPicker(
          title: getLocalText.s("DNS Final"),
          subtitle: getLocalText.s("For apps · default fallback when no DNS rule matches"),
          value: _dnsFinal,
          serverTags: resolverTags,
          onChanged: (v) => setState(() { _dnsFinal = v; _markDirty(); }),
          tooltip: getLocalText.s("Default fallback DNS server. Used when an app makes a DNS query and no DNS rule above matches it. Every app DNS query that isn't routed by a rule ends up here.\n\nRecommended:\n  • dns_shield — default; races 6 encrypted providers, answers from whichever replies first\n  • google_doh — encrypted (DoH)\n  • cloudflare_dot / google_dot — encrypted (DoT)\n  • cloudflare_udp / google_udp — fast plain UDP\n\nlocal_dns_resolver works but reveals queries to your ISP. Encrypted options keep them private."),
          warnIfLocal: false,
        ),

        // --- Default Resolver ---
        // §047 tooltip — `route.default_domain_resolver` — internal sing-box
        // DNS lookups (outbound endpoint hostname'ы, domain matching в routing
        // rules). Здесь `local_dns_resolver` ОПАСЕН: на Android-VPN system
        // resolver может recurse через TUN и накапливать stale kernel state
        // → §047 deterioration через несколько часов uptime. Показываем
        // жёлтый ⚠ если выбран local_dns_resolver.
        ResolverPicker(
          title: getLocalText.s("Default Domain Resolver"),
          subtitle: getLocalText.s("For routing · resolves hostnames inside sing-box (outbound endpoints, routing rules)"),
          value: _defaultResolver,
          serverTags: resolverTags,
          onChanged: (v) => setState(() { _defaultResolver = v; _markDirty(); }),
          tooltip: getLocalText.s("Used by routing engine to resolve hostnames internally (outbound endpoints, routing rules). Not the resolver apps use.\n\nRecommended:\n  • dns_shield — default; races 6 encrypted providers, answers from whichever replies first\n  • cloudflare_udp — UDP to 1.1.1.1 (fast)\n  • google_udp — UDP to 8.8.8.8 (fast)\n  • google_doh — encrypted\n\n⚠ local_dns_resolver here leaks lookups to your ISP — system DNS bypasses the VPN."),
          warnIfLocal: true,
          // §682 — резолвер через туннель: запросы ждут ещё не поднятый
          // туннель.
          tunnelDetour:
              defaultResolverTunnelDetour(_defaultResolver, _displayedServers),
        ),
        if (_defaultResolver == 'local_dns_resolver')
          LocalResolverWarningBanner(
            hasCloudflareUdp:
                _servers.any((s) => s.tag == 'cloudflare_udp'),
            onSwitchToCloudflareUdp: () => setState(() {
              _defaultResolver = 'cloudflare_udp';
              _markDirty();
            }),
          ),
        // §643 (TEMPLATE_LANG §6.9) — резолвер по умолчанию не отдаёт из
        // оптимистичного кэша ответ с истёкшим TTL (имена серверов узлов).
        SwitchListTile(
          key: const ValueKey('dns_resolver_no_stale'),
          contentPadding: EdgeInsets.zero,
          title: Text(getLocalText
              .s("Never serve stale answers for node hostnames")),
          subtitle: Text(getLocalText.s(
              "Node hostnames are resolved again once the cached answer expires. App DNS queries are not affected.")),
          value: _resolverNoStale,
          onChanged: (v) => setState(() {
            _resolverNoStale = v;
            _markDirty();
          }),
        ),

        // §580 — кэш DNS ядра: размер, устаревшие ответы, хранение в
        // cache.db. Изменение помечает конфиг к пересборке.
        const Divider(height: 32),
        TextField(
          key: const ValueKey('dns_cache_capacity'),
          controller: _cacheCapacityCtl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: getLocalText.s("DNS cache size"),
            helperText: getLocalText.s("Number of cached answers."),
            errorText:
                _cacheCapacityError.isEmpty ? null : _cacheCapacityError,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onChanged: _applyCacheCapacity,
        ),
        SwitchListTile(
          key: const ValueKey('dns_optimistic'),
          contentPadding: EdgeInsets.zero,
          title: Text(getLocalText.s("Serve stale answers")),
          subtitle: Text(getLocalText.s(
              "Answer from cache at once and refresh in the background.")),
          value: _optimistic,
          onChanged: (v) => setState(() {
            _optimistic = v;
            _markDirty();
          }),
        ),
        SwitchListTile(
          key: const ValueKey('dns_store_cache'),
          contentPadding: EdgeInsets.zero,
          title: Text(getLocalText.s("Keep DNS cache after restart")),
          value: _storeCache,
          onChanged: (v) => setState(() {
            _storeCache = v;
            _markDirty();
          }),
        ),

        // §263 — сброс DNS-кэша ядра (cache.db). Внизу экрана, отдельным
        // блоком: это разовое действие, не настройка конфига (не в rebuild).
        // §580: удаляется файл целиком — с ним и записи DNS (`store_dns`).
        ListTile(
          leading: Icon(Icons.cleaning_services_outlined,
              color: Theme.of(context).colorScheme.error),
          title: Text(getLocalText.s("Clear DNS cache")),
          subtitle: Text(getLocalText.s("Flush FakeIP allocations and cached DNS responses. Reloads the VPN if running.")),
          onTap: _confirmClearDnsCache,
        ),
      ],
    );
  }

  /// §263 — подтверждение + сброс DNS-кэша. При работающем VPN native удалит
  /// cache.db и reload'нёт ядро (тоннель дропнется ~3с); при выключенном —
  /// только удалит файл (чистый создастся на следующем старте).
  Future<void> _confirmClearDnsCache() async {
    final running = widget.homeController.state.tunnelUp;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Clear DNS cache?")),
        content: Text(
          getLocalText.s("This deletes the DNS cache (FakeIP allocations and cached responses).\n\n%s", running
              ? getLocalText.s("The VPN will briefly reload to apply.")
              : getLocalText.s("It will be rebuilt clean on the next connect.")),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(getLocalText.s("Clear")),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final ok = await BoxVpnClient().clearDnsCache();
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(ok
          ? (running
              ? getLocalText.s("DNS cache cleared — reloading")
              : getLocalText.s("DNS cache cleared"))
          : getLocalText.s("Could not clear DNS cache")),
    ));
  }

  /// §043: Toggle enabled — обновляет `enabled` в ref'е, kind не меняется.
  /// §680 — long-press на тайле сервера: меню «Delete», как у правил на
  /// Rules. У залоченного и preset-сервера пункт неактивен.
  Future<void> _showServerContextMenu(String tag, Offset pos) async {
    ResolvedServer? resolved;
    for (final s in _displayedServers) {
      if (s.tag == tag) {
        resolved = s;
        break;
      }
    }
    if (resolved == null) return;
    // §682 — Duplicate у шаблонного/пресетного сервера (и override).
    final canCopy =
        resolved.kind != ServerKind.inline || resolved.overrides != null;
    final action = await showRuleContextMenu(context, pos,
        deleteEnabled: canDeleteDnsServer(resolved), showDuplicate: canCopy);
    if (!mounted) return;
    if (action == 'duplicate') {
      final src = resolved;
      await _addServer(
        initial: dnsServerCopy(
          body: src.body,
          tag: dnsCopyTag(src.tag, {for (final s in _servers) s.tag}),
          enabled: true,
          description: getLocalText.s("%s (copy)",
              src.description.isNotEmpty ? src.description : src.tag),
        ),
      );
      return;
    }
    if (action != 'delete') return;
    final ok = await confirmDeleteDnsServer(context, resolved);
    if (ok != true || !mounted) return;
    setState(() {
      _servers.removeWhere((s) => s.tag == tag);
      _markDirty();
    });
  }

  void _toggleServerEnabled(String tag, bool value) {
    final idx = _servers.indexWhere((s) => s.tag == tag);
    if (idx < 0) return;
    setState(() {
      _servers[idx] = _servers[idx].withEnabled(value);
      _markDirty();
    });
  }

  /// §033: Toggle enabled на rule-entry (kind не меняется).
  void _toggleRuleEnabled(int index, bool value) {
    setState(() {
      _rules[index] = _rules[index].withEnabled(value);
      _markDirty();
    });
  }

  /// §117: тоггл DNS-аспекта rule-источника mirror-группы — пишет
  /// `cr.dns.enabled` (routing-часть правила не трогается). DNS-аспект живёт
  /// в custom rules storage, не в `dns.rules`, поэтому персистим явно
  /// (как rename-каскад) + markDirty для пересборки конфига. Сервер-локи
  /// (`_ruleRefsByTag`) пересчитаются на rebuild от обновлённого `_customRules`.
  void _toggleRuleDns(CustomRule cr, bool value) {
    final idx = _customRules.indexWhere((r) => r.id == cr.id);
    if (idx < 0 || cr.dns == null) return;
    final updated = switch (cr) {
      // §683 — включение сервера выходит из Answer = Fixed IP.
      CustomRuleInline() => cr.copyWith(
          dns: cr.dns!.copyWith(enabled: value, fixed: value ? false : null)),
      CustomRuleSrs() => cr.copyWith(
          dns: cr.dns!.copyWith(enabled: value, fixed: value ? false : null)),
      _ => cr,
    };
    setState(() {
      _customRules = [..._customRules]..[idx] = updated;
      _markDirty();
    });
    _track(SettingsStorage.saveCustomRules(_customRules));
  }

  /// §683: ✕ у строки Fixed IP — Answer → Default (`fixed = false`),
  /// адреса остаются в правиле (вернуть можно в редакторе).
  void _removeRuleFixedIp(CustomRule cr) {
    final idx = _customRules.indexWhere((r) => r.id == cr.id);
    if (idx < 0 || cr.dns == null) return;
    final next = cr.dns!.copyWith(fixed: false);
    final updated = switch (cr) {
      CustomRuleInline() => cr.copyWith(dns: next),
      CustomRuleSrs() => cr.copyWith(dns: next),
      _ => cr,
    };
    if (identical(updated, cr)) return;
    setState(() {
      _customRules = [..._customRules]..[idx] = updated;
      _markDirty();
    });
    _track(SettingsStorage.saveCustomRules(_customRules));
  }

  /// §257: свитч Force IPv4 в DNS-блоке правила — пишет `RuleDns.forceIpv4`
  /// (тот же persist-паттерн, что [_toggleRuleDns]). Снятие при пустых
  /// остальных полях обнуляет `dns` целиком (clearDns) — не копим мёртвый
  /// пустой объект в storage/backup (§256-инвариант).
  void _toggleRuleForceIpv4(CustomRule cr, bool value) {
    final idx = _customRules.indexWhere((r) => r.id == cr.id);
    if (idx < 0) return;
    final next = (cr.dns ?? const RuleDns()).copyWith(forceIpv4: value);
    final clear = next.isEmpty;
    final updated = switch (cr) {
      CustomRuleInline() =>
        clear ? cr.copyWith(clearDns: true) : cr.copyWith(dns: next),
      CustomRuleSrs() =>
        clear ? cr.copyWith(clearDns: true) : cr.copyWith(dns: next),
      _ => cr,
    };
    if (identical(updated, cr)) return;
    setState(() {
      _customRules = [..._customRules]..[idx] = updated;
      _markDirty();
    });
    _track(SettingsStorage.saveCustomRules(_customRules));
  }

  /// §257: свитч DNS-блока пресета — пишет магическую var `dns_enable` в
  /// `varsValues` (единая точка истины с билдером, [presetDnsEnableVar]).
  /// Затрагивает ПЕРВУЮ запись с этим presetId (список рендерит её же —
  /// dedup через seenPresetIds).
  void _togglePresetDnsEnable(String presetId, bool value) {
    final idx = _customRules.indexWhere(
        (r) => r is CustomRulePreset && r.presetId == presetId);
    if (idx < 0) return;
    final cr = _customRules[idx] as CustomRulePreset;
    final updated = cr.copyWith(
      varsValues: {...cr.varsValues, 'dns_enable': value ? 'true' : 'false'},
    );
    setState(() {
      _customRules = [..._customRules]..[idx] = updated;
      _presetDnsEnable = {..._presetDnsEnable, presetId: value};
      _markDirty();
    });
    _track(SettingsStorage.saveCustomRules(_customRules));
    // §266 — dns_enable-тумблер входит в формулу on_change (@rule_enable AND
    // @dns_enable) → каскад (FakeIP DNS off → resolve_enabled возвращается).
    _track(() async {
      final template = await TemplateLoader.load();
      final match = template.selectableRules
          .where((p) => p.presetId == presetId)
          .firstOrNull;
      if (match != null) await applyPresetOnChange(match, updated);
    }());
  }

  /// §033: Delete inline user-rule. §219 — удаление необратимо (правило не
  /// восстановить из шаблона, как template/preset), поэтому через confirm.
  Future<void> _deleteRule(int index) async {
    if (index < 0 || index >= _rules.length) return;
    final name = _ruleIdentity(_rules[index]);
    final confirmed = await showDeleteConfirmDialog(
      context,
      title: getLocalText.s("Delete rule?"),
      message: getLocalText.s("Remove \"%s\" permanently?", name),
    );
    if (confirmed != true || !mounted) return;
    // Список мог укоротиться, пока висел диалог, — проверяем индекс повторно.
    setState(() {
      if (index < _rules.length) _rules.removeAt(index);
      _markDirty();
    });
  }

}
