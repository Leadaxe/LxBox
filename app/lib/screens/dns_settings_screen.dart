import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/custom_rule.dart';
import '../models/parser_config.dart';
import '../services/builder/post_steps.dart';
import '../services/builder/preset_expand.dart';
import '../services/template_loader.dart';
import '../services/settings_storage.dart';
import 'dns_settings_screen/dns_server_resolver.dart';
import 'dns_settings_screen/resolved_server.dart';
import 'dns_settings_screen/server_editor_sheet.dart';
import 'dns_settings_screen/user_rule_editor_sheet.dart';
import 'dns_settings_screen/widgets/dns_rule_tile.dart';
import 'dns_settings_screen/widgets/local_resolver_warning_banner.dart';
import 'dns_settings_screen/widgets/merged_server_tile.dart';
import 'dns_settings_screen/widgets/resolver_picker.dart';
import 'lazy_persist_mixin.dart';

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
    with WidgetsBindingObserver, LazyPersistMixin<DnsSettingsScreen> {
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
  Map<String, Map<String, dynamic>> _presetRulesByPresetId = {};

  /// PresetId → label map для UI render'а title'а у `kind: preset` строк.
  /// Live lookup: storage хранит presetId, UI отображает текущий label.
  Map<String, String> _presetLabelByPresetId = {};


  bool _loading = true;
  // §076/§085 R4: write-on-exit через LazyPersistMixin (markDirty/persistChanges).

  String _strategy = '';
  String _dnsFinal = '';
  String _defaultResolver = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  // §085 R4 — alias: сохраняет существующие call-sites `_markDirty()`.
  void _markDirty() => markDirty();

  Future<void> _load() async {
    final template = await TemplateLoader.load();
    final vars = await SettingsStorage.getAllVars();

    // Parse dns_options from template
    final templateDns = template.dnsOptions;
    final templateServersRaw = (templateDns['servers'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map((s) => Map<String, dynamic>.from(s))
        .toList();
    final templateRulesRaw = (templateDns['rules'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();

    // §043: storage хранит kind-discriminated refs (симметрия с DNS rules).
    // Resolver делает auto-discovery + orphan cleanup + legacy migration.
    final templateByTag = <String, Map<String, dynamic>>{
      for (final s in templateServersRaw)
        if (s['tag'] is String && (s['tag'] as String).isNotEmpty)
          s['tag'] as String: s,
    };

    // §033: build template rules map by name
    final templateRulesByName = <String, Map<String, dynamic>>{
      for (final r in templateRulesRaw)
        if (r['name'] is String && (r['name'] as String).isNotEmpty)
          r['name'] as String: r,
    };

    // §033: build active preset rules maps by presetId + dns_servers.
    // Walk through ALL custom_rules.kind:preset entries (including disabled —
    // because DNS-aspect может быть enabled независимо). expand для отображения
    // body в DnsSettings UI.
    final presetRulesByPresetId = <String, Map<String, dynamic>>{};
    final presetLabelByPresetId = <String, String>{};
    final presetServersWithLabel = <Map<String, dynamic>>[];
    final activeRules = await SettingsStorage.getCustomRules();
    final allPresets = template.selectableRules;
    final activePresetIdsWithDnsRule = <String>{};
    for (final cr in activeRules) {
      if (cr is! CustomRulePreset) continue;
      if (cr.presetId.isEmpty) continue;
      SelectableRule? match;
      for (final p in allPresets) {
        if (p.presetId == cr.presetId) {
          match = p;
          break;
        }
      }
      if (match == null) continue;
      if (match.dnsRule != null) {
        activePresetIdsWithDnsRule.add(cr.presetId);
      }
      final fragments = expandPreset(cr, match);
      if (fragments.dnsRule != null) {
        presetRulesByPresetId[cr.presetId] = fragments.dnsRule!;
      }
      presetLabelByPresetId[cr.presetId] = match.label;
      // Collect preset's expanded dns_servers — annotate with preset.label
      // for display badge. Tag-collisions с template/user разрешаются на
      // build'е (дедуп по tag, first-wins); UI просто показывает что есть.
      for (final s in fragments.dnsServers) {
        final annotated = Map<String, dynamic>.from(s)
          ..['_preset_label'] = match.label;
        presetServersWithLabel.add(annotated);
      }
    }

    // §033: resolve current rules list (auto-discover + orphan cleanup +
    // persist if changed). Single source of truth shared with builder.
    final resolvedRules = await resolveDnsRulesList(
      templateRules: templateRulesRaw,
      activePresetIdsWithDnsRule: activePresetIdsWithDnsRule,
    );

    // §043: resolve servers refs list (legacy migration → kind-refs;
    // auto-discovery template+preset; orphan cleanup; persist if changed).
    final presetServersByTag = <String, Map<String, dynamic>>{
      for (final s in presetServersWithLabel)
        if (s['tag'] is String && (s['tag'] as String).isNotEmpty)
          s['tag'] as String: s,
    };
    final resolvedServers = await resolveDnsServersList(
      templateServers: templateServersRaw,
      presetServersByTag: presetServersByTag,
    );

    if (mounted) {
      setState(() {
        _servers = resolvedServers;
        _templateByTag = templateByTag;
        _presetServersByTag = presetServersByTag;
        _rules = resolvedRules;
        _templateRulesByName = templateRulesByName;
        _presetRulesByPresetId = presetRulesByPresetId;
        _presetLabelByPresetId = presetLabelByPresetId;
        _strategy = vars['dns_strategy'] ?? 'prefer_ipv4';
        _dnsFinal = vars['dns_final'] ?? '';
        _defaultResolver = vars['dns_default_domain_resolver'] ?? '';
        _loading = false;
      });
    }
  }

  /// §076/§085 R4: atomic storage flush (вызывается mixin'ом). Inline rebuild
  /// удалён — lazy через home return observer.
  @override
  Future<void> persistChanges() async {
    await SettingsStorage.saveDnsServers(_servers);
    final cleaned = cleanDnsRulesForPersist(
      _rules,
      _templateRulesByName,
      _presetRulesByPresetId,
    );
    await SettingsStorage.saveDnsRulesList(cleaned);
    await SettingsStorage.setVar('dns_strategy', _strategy);
    await SettingsStorage.setVar('dns_final', _dnsFinal);
    await SettingsStorage.setVar('dns_default_domain_resolver', _defaultResolver);

    // §076: configDirty уже true (set в _markDirty). Lazy rebuild на
    // возврате home через _pushRoute.then().
  }

  /// §044: render list — typed `ResolvedServer` для каждой ref-записи.
  List<ResolvedServer> get _displayedServers =>
      resolveDisplayedServers(_servers, _templateByTag, _presetServersByTag);

  /// Tags доступные в dropdown'ах (DNS Final / Default Resolver / per-rule).
  /// Filter `enabled` на ref-level.
  List<String> get _enabledServerTags => enabledServerTags(_displayedServers);

  /// §043: Reset inline-override обратно к canonical (template/preset).
  /// Меняет ref kind с `inline` на `template`/`preset`, body убирается.
  /// Если у tag'а нет canonical — это pure user, не reset а delete (отдельная action).
  void _resetServerToCanonical(String tag) {
    final idx = _servers.indexWhere((s) => s['tag'] == tag);
    if (idx < 0) return;
    final ref = _servers[idx];
    if (ref['kind'] != 'inline') return; // только inline можно reset'нуть
    String? newKind;
    if (_presetServersByTag.containsKey(tag)) {
      newKind = 'preset';
    } else if (_templateByTag.containsKey(tag)) {
      newKind = 'template';
    }
    if (newKind == null) return; // нечего reset'ить — pure user
    setState(() {
      _servers[idx] = {
        'enabled': ref['enabled'] != false,
        'kind': newKind!,
        'tag': tag,
      };
      _markDirty();
    });
  }

  /// §044: Add new inline server. Открывает editor с 3 input'ами + body
  /// без tag/description/enabled. На save создаёт kind:inline ref.
  void _addServer() {
    showServerEditor(
      context,
      title: 'Add DNS Server',
      initialTag: 'dns_new',
      lockedTag: false,
      initialDescription: 'My DNS',
      initialEnabled: true,
      initialBody: <String, dynamic>{
        'type': 'udp',
        'server': '1.1.1.1',
        'server_port': 53,
      },
      onSave: (savedTag, savedDescription, savedEnabled, savedBody) {
        // Tag conflict: replace existing (юзер явно ввёл tag).
        setState(() {
          _servers.removeWhere((s) => s['tag'] == savedTag);
          _servers.add({
            'enabled': savedEnabled,
            'kind': 'inline',
            'tag': savedTag,
            if (savedDescription.isNotEmpty) 'description': savedDescription,
            'body': savedBody,
          });
          _markDirty();
        });
      },
    );
  }

  void _addUserRule() => _showUserRuleEditor(-1);

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
        appBar: AppBar(title: const Text('DNS Settings')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final theme = Theme.of(context);
    final serverTags = _enabledServerTags;

    return Scaffold(
      appBar: AppBar(title: const Text('DNS Settings')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(12, 12, 12, MediaQuery.of(context).padding.bottom + 24),
        children: [
          // --- Servers ---
          Row(
            children: [
              Text('DNS Servers', style: theme.textTheme.titleMedium),
              const Spacer(),
              IconButton(icon: const Icon(Icons.add), onPressed: _addServer),
            ],
          ),
          const SizedBox(height: 4),
          // §042: единый render через 3-tier merged list. Builder сам
          // определяет UI поведение по `_origin` annotation.
          ..._displayedServers.map((entry) => MergedServerTile(
                entry: entry,
                onToggleEnabled: _toggleServerEnabled,
                onEdit: _editServerBody,
                onReset: _resetServerToCanonical,
                onDelete: _deleteServer,
              )),

          const Divider(height: 32),

          // --- Strategy ---
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Strategy'),
            trailing: DropdownButton<String>(
              value: ['prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'].contains(_strategy)
                  ? _strategy : 'prefer_ipv4',
              items: const [
                DropdownMenuItem(value: 'prefer_ipv4', child: Text('prefer_ipv4')),
                DropdownMenuItem(value: 'prefer_ipv6', child: Text('prefer_ipv6')),
                DropdownMenuItem(value: 'ipv4_only', child: Text('ipv4_only')),
                DropdownMenuItem(value: 'ipv6_only', child: Text('ipv6_only')),
              ],
              onChanged: (v) { if (v != null) setState(() { _strategy = v; _markDirty(); }); },
            ),
          ),

          const Divider(height: 32),

          // --- DNS Rules (§061 dns-rules-refactor) ---
          Row(
            children: [
              Text('DNS Rules', style: theme.textTheme.titleMedium),
              const Spacer(),
              TextButton.icon(
                onPressed: _addUserRule,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add user rule'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (_rules.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'No DNS rules. Add user rules manually, or enable presets / template defaults.',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: _rules.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex -= 1;
                  final moved = _rules.removeAt(oldIndex);
                  _rules.insert(newIndex, moved);
                  _markDirty();
                });
              },
              itemBuilder: (ctx, i) => DnsRuleTile(
                index: i,
                entry: _rules[i],
                templateRulesByName: _templateRulesByName,
                presetRulesByPresetId: _presetRulesByPresetId,
                presetLabelByPresetId: _presetLabelByPresetId,
                onToggleEnabled: _toggleRuleEnabled,
                onEdit: _showUserRuleEditor,
                onDelete: _deleteRule,
                // §033: identity для reorder — name (inline/template/srs) или
                // presetId (preset). Нужно стабильное непустое значение.
                key: ValueKey(
                  'dns-rule-$i-${_rules[i]['name'] ?? _rules[i]['presetId'] ?? ''}',
                ),
              ),
            ),

          const Divider(height: 32),

          // --- Final ---
          // §048/§047 tooltip — `dns.final` — catch-all для app's DNS queries
          // (когда не match'ит ни один rule). `local_dns_resolver` тут БЕЗОПАСЕН:
          // app's queries не recurse через TUN потому что system resolver
          // вызывается через protected JNI path для apps. Encrypted options
          // (`google_doh`, `*_dot`) рекомендуем для privacy.
          ResolverPicker(
            title: 'DNS Final',
            subtitle:
                'For apps · default fallback when no DNS rule matches',
            value: _dnsFinal,
            serverTags: serverTags,
            onChanged: (v) => setState(() { _dnsFinal = v; _markDirty(); }),
            tooltip: 'Default fallback DNS server. Used when an app makes a '
                'DNS query and no DNS rule above matches it. Every app DNS '
                'query that isn\'t routed by a rule ends up here.\n\n'
                'Recommended:\n'
                '  • google_doh — encrypted (DoH)\n'
                '  • cloudflare_dot / google_dot — encrypted (DoT)\n'
                '  • cloudflare_udp / google_udp — fast plain UDP\n\n'
                'local_dns_resolver works but reveals queries to your ISP. '
                'Encrypted options keep them private.',
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
            title: 'Default Domain Resolver',
            subtitle:
                'For routing · resolves hostnames inside sing-box (outbound '
                'endpoints, routing rules)',
            value: _defaultResolver,
            serverTags: serverTags,
            onChanged: (v) => setState(() { _defaultResolver = v; _markDirty(); }),
            tooltip: 'Used by routing engine to resolve hostnames internally '
                '(outbound endpoints, routing rules). Not the resolver apps '
                'use.\n\n'
                'Recommended:\n'
                '  • cloudflare_udp — UDP to 1.1.1.1 (fast)\n'
                '  • google_udp — UDP to 8.8.8.8 (fast)\n'
                '  • google_doh — encrypted\n\n'
                '⚠ local_dns_resolver here leaks lookups to your ISP — '
                'system DNS bypasses the VPN.',
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
        ],
      ),
    );
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

  /// §043: Delete user-only inline server.
  void _deleteServer(String tag) {
    setState(() {
      _servers.removeWhere((s) => s['tag'] == tag);
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

  /// §033: Delete inline user-rule.
  void _deleteRule(int index) {
    setState(() {
      _rules.removeAt(index);
      _markDirty();
    });
  }

  /// §044: Edit existing entry — диалог с 3 явными input'ами (tag locked,
  /// description, enabled) + body JSON editor (без tag/description/enabled).
  /// На save если entry был template/preset — kind transition в inline.
  void _editServerBody(String tag) {
    final idx = _servers.indexWhere((s) => s['tag'] == tag);
    if (idx < 0) return;
    final ref = _servers[idx];
    final kind = ref['kind'] as String?;

    // Initial body — без tag/description/enabled (для inline это уже так в §044;
    // для template/preset peel'им из canonical перед показом).
    Map<String, dynamic> initialBody;
    String initialDescription;
    if (kind == 'inline' && ref['body'] is Map) {
      initialBody = Map<String, dynamic>.from(ref['body'] as Map);
      // На случай если в body всё ещё лежат tag/description/enabled (pre-§044
      // данные ещё не мигрированные — defensive strip).
      initialBody
        ..remove('tag')
        ..remove('description')
        ..remove('enabled');
      initialDescription = ref['description']?.toString() ?? '';
    } else if (kind == 'preset' && _presetServersByTag.containsKey(tag)) {
      final canonical = _presetServersByTag[tag]!;
      initialBody = Map<String, dynamic>.from(canonical)
        ..remove('tag')
        ..remove('description')
        ..remove('enabled')
        ..remove('_preset_label');
      initialDescription = ref['description']?.toString() ??
          canonical['description']?.toString() ??
          '';
    } else if (kind == 'template' && _templateByTag.containsKey(tag)) {
      final canonical = _templateByTag[tag]!;
      initialBody = Map<String, dynamic>.from(canonical)
        ..remove('tag')
        ..remove('description')
        ..remove('enabled');
      initialDescription = ref['description']?.toString() ??
          canonical['description']?.toString() ??
          '';
    } else {
      return; // нечего редактировать
    }

    showServerEditor(
      context,
      title: 'Edit DNS Server',
      initialTag: tag,
      lockedTag: true, // tag нельзя менять при edit existing — иначе orphan'ит lookup
      initialDescription: initialDescription,
      initialEnabled: ref['enabled'] != false,
      initialBody: initialBody,
      onSave: (savedTag, savedDescription, savedEnabled, savedBody) {
        setState(() {
          _servers[idx] = {
            'enabled': savedEnabled,
            'kind': 'inline',
            'tag': savedTag,
            if (savedDescription.isNotEmpty) 'description': savedDescription,
            'body': savedBody,
          };
          _markDirty();
        });
      },
    );
  }

}
