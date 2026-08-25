import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/custom_rule.dart';
import '../services/builder/post_steps.dart';
import '../services/dns/dns_controller.dart';
import '../services/l10n/template_aware_state.dart';
import '../services/template_loader.dart';
import '../services/preset_on_change.dart';
import '../services/ui_helpers.dart';
import '../services/settings_storage.dart';
import '../vpn/box_vpn_client.dart';
import '../vpn/cc_channel.dart';
import '../widgets/outbound_picker.dart';
import 'dns_server_edit_screen.dart';
import 'dns_settings_screen/dns_server_resolver.dart';
import 'dns_settings_screen/resolved_server.dart';
import 'dns_settings_screen/user_rule_editor_sheet.dart';
import 'dns_settings_screen/widgets/dns_mirror_group_card.dart';
import 'dns_settings_screen/widgets/dns_rule_tile.dart';
import 'dns_settings_screen/widgets/local_resolver_warning_banner.dart';
import 'dns_settings_screen/widgets/merged_server_tile.dart';
import 'dns_settings_screen/widgets/resolver_picker.dart';
import 'lazy_persist_mixin.dart';
import '../services/l10n/locale_controller.dart';

/// DNS Settings (§014, §061 dns-rules-refactor, бывший feature §041).
///
/// §061 — DNS rules refactored to first-class named/toggleable model:
/// `dns_options.rules: List<{enabled, type, title, rule?}>` где
/// `type ∈ {user, template, rule}`. Linear order (free reorder через
/// drag-handle), individual enable/disable, user-rules editable.
class DnsSettingsScreen extends StatefulWidget {
  const DnsSettingsScreen({
    super.key,
    required this.subController,
    required this.homeController,
  });

  final SubscriptionController subController;
  final HomeController homeController;

  @override
  State<DnsSettingsScreen> createState() => _DnsSettingsScreenState();
}

class _DnsSettingsScreenState extends State<DnsSettingsScreen>
    with
        WidgetsBindingObserver,
        LazyPersistMixin<DnsSettingsScreen>,
        TemplateAwareState<DnsSettingsScreen> {
  @override
  SubscriptionController get lazyController => widget.subController;

  /// §043: kind-discriminated refs (резолвер `resolveDnsServersList`):
  /// - `{enabled, kind: 'inline',   tag, body}` — user-defined OR override
  /// - `{enabled, kind: 'template', tag}`        — ref на template-server
  /// - `{enabled, kind: 'preset',   tag}`        — ref на active preset's server
  ///
  /// Body для `template`/`preset` берётся из [_templateByTag] / [_presetServersByTag]
  /// в [_displayedServers] / [_resolveBody].
  List<Map<String, dynamic>> _servers = [];

  /// §043: Tag → template-server map. Lookup canonical body для
  /// `kind: template` ref'ов и для override-detection.
  Map<String, Map<String, dynamic>> _templateByTag = {};

  /// §043: Tag → preset-server map. Lookup canonical body для `kind: preset`
  /// ref'ов и для override-detection. preset > template на tag-collision.
  Map<String, Map<String, dynamic>> _presetServersByTag = {};

  /// §061 + §032: structured rules list `{enabled, kind, title?, presetId?, rule?}`.
  List<Map<String, dynamic>> _rules = [];

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

  bool _loading = true;
  // §076/§085 R4/§107: staging через LazyPersistMixin (markDirty/stageChanges).

  String _strategy = '';
  String _dnsFinal = '';
  String _defaultResolver = '';

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

  Future<void> _load() async {
    // §300 — вся read+derive-логика вынесена в DnsController.load() (тело
    // verbatim + типизация краёв §294). Экран только присваивает snapshot.
    final s = await DnsController.load();
    if (!mounted) return;
    setState(() {
      _servers = s.servers;
      _templateByTag = s.templateByTag;
      _presetServersByTag = s.presetServersByTag;
      _rules = s.rules;
      _templateRulesByName = s.templateRulesByName;
      _presetRulesByPresetId = s.presetRulesByPresetId;
      _presetLabelByPresetId = s.presetLabelByPresetId;
      _presetDnsEnable = s.presetDnsEnable;
      _outboundOptions = s.outboundOptions;
      _customRules = s.customRules;
      _dnsMirrorsByRuleId = s.dnsMirrorsByRuleId;
      _strategy = s.strategy;
      _dnsFinal = s.dnsFinal;
      _defaultResolver = s.defaultResolver;
      _loading = false;
    });
    // §121: исчезнувший resolver-tag сброшен → persist (config dirty).
    if (s.resolverReset) _markDirty();
  }

  /// §107: staging — буфер экрана в `_cache` на каждую мутацию; дисковый
  /// flush — mixin'ом (flushToDisk) на dispose/paused.
  @override
  Future<void> stageChanges() async {
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
  List<ResolvedServer> get _displayedServers => resolveDisplayedServers(
      _servers, _templateByTag, _presetServersByTag,
      ruleRefsByTag: _ruleRefsByTag);

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
              enabled: s.enabled || s.locked,
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

  /// §117 задача 4: «+» → полноэкранный редактор в new-режиме (kind inline).
  /// Заготовка — форма UDP с пустым адресом (save требует ввода); порт/
  /// detour отсутствуют — ключи появляются только при явном выборе.
  Future<void> _addServer() async {
    final result = await openDnsServerEditor(
      context,
      initialRef: <String, dynamic>{
        'enabled': true,
        'kind': 'inline',
        'tag': 'dns_new',
        // §279 seed-time-локализация: метка резолвится через активную локаль
        // в момент создания (дальше — user data, ретроактивно не мигрируется).
        'description': getLocalText.s("My DNS"),
        'body': <String, dynamic>{'type': 'udp'},
      },
      outboundOptions: _outboundOptions,
      dnsServerTags: _enabledServerTags,
      dnsMemberOptions: _dnsMemberOptions,
      existingTags: {for (final s in _servers) s['tag'].toString()},
    );
    if (result == null || !mounted) return;
    final saved = result.saved;
    if (saved == null) return;
    setState(() {
      // Tag conflict: replace existing (юзер подтвердил в редакторе).
      _servers.removeWhere((s) => s['tag'] == saved['tag']);
      _servers.add(saved);
      _markDirty();
    });
  }

  /// §117 задача 4: тап по тайлу → полноэкранный редактор (Params/JSON).
  /// Reset-to-canonical и Delete — AppBar-actions редактора, результат
  /// приходит сюда единым `DnsServerEditResult`.
  Future<void> _editServer(String tag) async {
    final idx = _servers.indexWhere((s) => s['tag'] == tag);
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
      initialRef: Map<String, dynamic>.from(_servers[idx]),
      resolved: resolved,
      templateWrapper:
          resolved.kind == ServerKind.template ? _templateByTag[tag] : null,
      canonicalDescription: canonicalDescription,
      outboundOptions: _outboundOptions,
      // §117: dom_resolver-пикер — теги без самого сервера (петля).
      dnsServerTags: _enabledServerTags.where((t) => t != tag).toList(),
      dnsMemberOptions: _dnsMemberOptions,
      // §117 задача 4b: rename-коллизии (без текущего тега).
      existingTags: {
        for (final s in _servers)
          if (s['tag'] != tag) s['tag'].toString(),
      },
    );
    if (result == null || !mounted) return;
    setState(() {
      if (result.wasDeleted) {
        _servers.removeAt(idx);
      } else if (result.saved != null) {
        _servers[idx] = result.saved!;
        // §117 задача 4b: rename → каскад по ссылкам, чтобы не орфанить
        // (DNS-правила, resolvers, domain_resolver'ы, DNS-опции правил).
        final newTag = result.saved!['tag']?.toString() ?? tag;
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
            // custom_rules — чужой этому экрану storage (routing), staged
            // персистом LazyPersistMixin не покрывается — пишем сразу.
            unawaited(SettingsStorage.saveCustomRules(renamed));
          }
        }
      } else {
        return;
      }
      _markDirty();
    });
  }

  void _addUserRule() => _showUserRuleEditor(-1);

  /// §117 задача 3: routing-правила с активным DNS-mirror'ом (routing order).
  List<CustomRule> get _ruleMirrors =>
      [for (final cr in _customRules) if (cr.dnsMirrorActive) cr];

  /// §117 (решение №6): display-модель списка DNS-правил. Элемент ≥0 —
  /// индекс standalone-записи в [_rules]; `-1` — атомарная mirror-группа
  /// (kind:preset записи + rule-mirror'ы, порядок = routing-правила).
  /// Якорь группы зеркалит эмиссию `applyCustomDns`: первая kind:preset
  /// запись → иначе перед template-блоком → иначе в конец.
  List<int> get _ruleDisplayRows {
    final hasGroup =
        _rules.any((e) => e['kind'] == 'preset') || _ruleMirrors.isNotEmpty;
    final rows = <int>[];
    var groupInserted = false;
    for (var i = 0; i < _rules.length; i++) {
      final kind = _rules[i]['kind'];
      if (kind == 'preset') {
        if (!groupInserted) {
          rows.add(-1);
          groupInserted = true;
        }
        continue;
      }
      if (kind == 'template' && hasGroup && !groupInserted) {
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
      if (_rules[i]['kind'] == 'preset') {
        final pid = _rules[i]['presetId']?.toString();
        if (pid != null && pid.isNotEmpty) presetIdxByPid[pid] = i;
      }
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
        ));
      } else {
        // §257: объединённый блок DNS-аспектов правила — заголовок = имя,
        // под-строки «Server» (RuleDns.enabled) и «Force IPv4»
        // (RuleDns.forceIpv4), каждая со своим свитчем. Блок виден, когда
        // настроен ХОТЬ ОДИН аспект — Force IPv4-правило без dedicated-
        // сервера больше не невидимка (гейт не требует serverTag).
        final hasServerAspect = cr.dnsMirrorEligible; // serverTag настроен
        // Вариант A (решение владельца): Force-строка — только когда галка
        // РЕАЛЬНО стоит (forceIpv4Active), не у любого eligible-правила.
        // Правило с одним сервером не тащит пустой Force-тумблер; включают
        // Force в редакторе правила.
        final hasForceAspect = cr.forceIpv4Active;
        if (!hasServerAspect && !hasForceAspect) continue;
        final mirrors = _dnsMirrorsByRuleId[cr.id] ?? const <DnsMirrorEntry>[];
        Map<String, dynamic>? serverBody;
        Map<String, dynamic>? forceBody;
        for (final m in mirrors) {
          if (m.serverless) {
            forceBody ??= m.body;
          } else {
            serverBody ??= m.body;
          }
        }
        final missing =
            !_servers.any((s) => s['tag'] == (cr.dns?.serverTag ?? ''));
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
        if (e['kind'] == 'preset') e,
    ];
    final units = <List<Map<String, dynamic>>>[
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

  void _showUserRuleEditor(int index) {
    final isNew = index < 0;
    final existing = isNew ? null : _rules[index];
    showUserRuleEditor(
      context,
      isNew: isNew,
      existing: existing,
      onSave: (entry) {
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
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(getLocalText.s("DNS Settings"))),
        body: const Center(child: CircularProgressIndicator()),
      );
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

    return Scaffold(
      appBar: AppBar(title: Text(getLocalText.s("DNS Settings"))),
      body: ListView(
        padding: EdgeInsets.fromLTRB(12, 12, 12, MediaQuery.of(context).padding.bottom + 24),
        children: [
          // --- Servers ---
          Row(
            children: [
              Text(getLocalText.s("DNS Servers"),
                  style: theme.textTheme.titleMedium),
              const Spacer(),
              IconButton(icon: const Icon(Icons.add), onPressed: _addServer),
            ],
          ),
          const SizedBox(height: 4),
          // §042: единый render через 3-tier merged list. §117 задача 4:
          // тайл — только switch + тап→полноэкранный редактор.
          ...displayed.map((entry) => MergedServerTile(
                entry: entry,
                onToggleEnabled: _toggleServerEnabled,
                onTap: _editServer,
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
                  final draggable =
                      _rules.any((e) => e['kind'] == 'preset');
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
                    'dns-rule-$row-${_rules[row]['name'] ?? _rules[row]['presetId'] ?? ''}',
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
            tooltip: getLocalText.s("Default fallback DNS server. Used when an app makes a DNS query and no DNS rule above matches it. Every app DNS query that isn't routed by a rule ends up here.\n\nRecommended:\n  • dns_shield — default; races 9 providers, answers from whichever replies first\n  • google_doh — encrypted (DoH)\n  • cloudflare_dot / google_dot — encrypted (DoT)\n  • cloudflare_udp / google_udp — fast plain UDP\n\nlocal_dns_resolver works but reveals queries to your ISP. Encrypted options keep them private."),
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
            tooltip: getLocalText.s("Used by routing engine to resolve hostnames internally (outbound endpoints, routing rules). Not the resolver apps use.\n\nRecommended:\n  • dns_shield — default; races 9 providers, answers from whichever replies first\n  • cloudflare_udp — UDP to 1.1.1.1 (fast)\n  • google_udp — UDP to 8.8.8.8 (fast)\n  • google_doh — encrypted\n\n⚠ local_dns_resolver here leaks lookups to your ISP — system DNS bypasses the VPN."),
            warnIfLocal: true,
          ),
          if (_defaultResolver == 'local_dns_resolver')
            LocalResolverWarningBanner(
              hasCloudflareUdp:
                  _servers.any((s) => s['tag'] == 'cloudflare_udp'),
              onSwitchToCloudflareUdp: () => setState(() {
                _defaultResolver = 'cloudflare_udp';
                _markDirty();
              }),
            ),

          // §263 — сброс DNS-кэша ядра (cache.db). Внизу экрана, отдельным
          // блоком: это разовое действие, не настройка конфига (не в rebuild).
          const Divider(height: 32),
          ListTile(
            leading: Icon(Icons.cleaning_services_outlined,
                color: Theme.of(context).colorScheme.error),
            title: Text(getLocalText.s("Clear DNS cache")),
            subtitle: Text(getLocalText.s("Flush FakeIP allocations and cached DNS responses. Reloads the VPN if running.")),
            onTap: _confirmClearDnsCache,
          ),
        ],
      ),
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
  void _toggleServerEnabled(String tag, bool value) {
    final idx = _servers.indexWhere((s) => s['tag'] == tag);
    if (idx < 0) return;
    setState(() {
      _servers[idx] = Map<String, dynamic>.from(_servers[idx])
        ..['enabled'] = value;
      _markDirty();
    });
  }

  /// §033: Toggle enabled на rule-entry (kind не меняется).
  void _toggleRuleEnabled(int index, bool value) {
    setState(() {
      _rules[index] = Map<String, dynamic>.from(_rules[index])
        ..['enabled'] = value;
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
      CustomRuleInline() => cr.copyWith(dns: cr.dns!.copyWith(enabled: value)),
      CustomRuleSrs() => cr.copyWith(dns: cr.dns!.copyWith(enabled: value)),
      _ => cr,
    };
    setState(() {
      _customRules = [..._customRules]..[idx] = updated;
      _markDirty();
    });
    unawaited(SettingsStorage.saveCustomRules(_customRules));
  }

  /// §257: свитч Force IPv4 в DNS-блоке правила — пишет `RuleDns.forceIpv4`
  /// (тот же persist-паттерн, что [_toggleRuleDns]). Снятие при пустых
  /// остальных полях обнуляет `dns` целиком (clearDns) — не копим мёртвый
  /// пустой объект в storage/backup (§256-инвариант).
  void _toggleRuleForceIpv4(CustomRule cr, bool value) {
    final idx = _customRules.indexWhere((r) => r.id == cr.id);
    if (idx < 0) return;
    final next = (cr.dns ?? const RuleDns()).copyWith(forceIpv4: value);
    final clear =
        !next.forceIpv4 && !next.enabled && next.serverTag.isEmpty;
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
    unawaited(SettingsStorage.saveCustomRules(_customRules));
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
    unawaited(SettingsStorage.saveCustomRules(_customRules));
    // §266 — dns_enable-тумблер входит в формулу on_change (@rule_enable AND
    // @dns_enable) → каскад (FakeIP DNS off → resolve_enabled возвращается).
    unawaited(() async {
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
    final name = _rules[index]['name'] as String? ?? '';
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
