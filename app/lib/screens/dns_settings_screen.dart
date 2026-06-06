import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/custom_rule.dart';
import '../models/parser_config.dart';
import '../services/builder/post_steps.dart';
import '../services/error_format.dart';
import '../services/builder/preset_expand.dart';
import '../services/template_loader.dart';
import '../services/settings_storage.dart';

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
    with WidgetsBindingObserver {
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
  // §076: _saveTimer удалён — write-on-exit pattern через _markDirty + _persist.

  String _strategy = '';
  String _dnsFinal = '';
  String _defaultResolver = '';
  // §076: dirty flag — нужно ли persist на exit. Set'ится в _markDirty,
  // clears'ся после _persist. Защита от лишнего write при open+close.
  bool _pendingChanges = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // §076 write-on-exit: Navigator.pop → flush pending.
    if (_pendingChanges) unawaited(_persist());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // §076 safety net: app backgrounded → flush. Только `paused`.
    if (state == AppLifecycleState.paused && _pendingChanges) {
      unawaited(_persist());
    }
  }

  /// §076: mutation → set in-memory flags синхронно. configDirty должен
  /// быть видим _pushRoute.then() до того как .then() начнёт проверять —
  /// иначе race condition (см. spec §076).
  void _markDirty() {
    _pendingChanges = true;
    widget.subController.configDirty = true; // sync race-safe
  }

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

  /// §076: atomic storage flush. Inline rebuild удалён — lazy через
  /// home._pushRoute.then() на возврате на home.
  Future<void> _persist() async {
    if (!_pendingChanges) return;
    _pendingChanges = false;
    await SettingsStorage.saveDnsServers(_servers);
    // §033: orphan-cleanup safety — only persist entries whose source still
    // exists. UI mutation already filtered, но keep guard symmetric с
    // resolveDnsRulesList semantics.
    final cleaned = _rules.where((e) {
      final kind = e['kind'] as String?;
      if (kind == null) return false;
      if (kind == 'inline') {
        final name = e['name'] as String?;
        return name != null && name.isNotEmpty;
      }
      if (kind == 'srs') {
        final id = e['id'] as String?;
        final name = e['name'] as String?;
        return id != null && id.isNotEmpty && name != null && name.isNotEmpty;
      }
      if (kind == 'template') {
        final name = e['name'] as String?;
        return name != null && _templateRulesByName.containsKey(name);
      }
      if (kind == 'preset') {
        final pid = e['presetId'] as String?;
        return pid != null && _presetRulesByPresetId.containsKey(pid);
      }
      return false;
    }).toList();
    await SettingsStorage.saveDnsRulesList(cleaned);
    await SettingsStorage.setVar('dns_strategy', _strategy);
    await SettingsStorage.setVar('dns_final', _dnsFinal);
    await SettingsStorage.setVar('dns_default_domain_resolver', _defaultResolver);

    // §076: configDirty уже true (set в _markDirty). Lazy rebuild на
    // возврате home через _pushRoute.then().
  }

  /// §044: render list — typed `ResolvedServer` для каждой ref-записи.
  ///
  /// Single source of truth для полей:
  /// - `tag` — из ref'а (синтезируется в body для display)
  /// - `description` — из ref'а если переопределён, иначе из canonical
  /// - `enabled` — из ref'а
  /// - `body` — для inline это `ref.body` + injected tag; для template/preset —
  ///   canonical lookup + strip meta + injected tag
  ///
  /// `kind` / `overrides` / `presetLabel` — typed accessors на `ResolvedServer`.
  List<ResolvedServer> get _displayedServers {
    final out = <ResolvedServer>[];
    for (final ref in _servers) {
      final kindStr = ref['kind']?.toString();
      final tag = ref['tag']?.toString();
      if (kindStr == null || tag == null || tag.isEmpty) continue;
      final kind = ServerKind.tryParse(kindStr);
      if (kind == null) continue;

      Map<String, dynamic>? body;
      ServerKind? overrides;
      String? presetLabel;
      String? canonicalDescription;

      if (kind == ServerKind.inline) {
        final b = ref['body'];
        body = b is Map ? Map<String, dynamic>.from(b) : <String, dynamic>{};
        // Override-detection (preset wins over template).
        if (_presetServersByTag.containsKey(tag)) {
          overrides = ServerKind.preset;
          final p = _presetServersByTag[tag]!;
          presetLabel = p['_preset_label']?.toString();
          canonicalDescription = p['description']?.toString();
        } else if (_templateByTag.containsKey(tag)) {
          overrides = ServerKind.template;
          canonicalDescription = _templateByTag[tag]?['description']?.toString();
        }
      } else if (kind == ServerKind.preset) {
        final p = _presetServersByTag[tag];
        if (p == null) continue; // orphan
        body = Map<String, dynamic>.from(p)..remove('_preset_label');
        presetLabel = p['_preset_label']?.toString();
        canonicalDescription = p['description']?.toString();
      } else if (kind == ServerKind.template) {
        final t = _templateByTag[tag];
        if (t == null) continue; // orphan
        body = Map<String, dynamic>.from(t);
        canonicalDescription = t['description']?.toString();
      }

      // Synthesize tag в body (single source of truth — ref.tag).
      // Strip meta (description/enabled из canonical body не нужны).
      body!
        ..['tag'] = tag
        ..remove('description')
        ..remove('enabled');

      // Resolved description: ref.description если есть; иначе canonical's.
      final refDesc = ref['description']?.toString();
      final description = (refDesc != null && refDesc.isNotEmpty)
          ? refDesc
          : (canonicalDescription ?? '');

      out.add(ResolvedServer(
        kind: kind,
        tag: tag,
        description: description,
        enabled: ref['enabled'] != false,
        body: body,
        overrides: overrides,
        presetLabel: presetLabel,
      ));
    }
    // §044: render-order — template → preset → inline (см. ServerKind enum).
    // Stable sort: внутри каждой группы insertion-order сохраняется.
    out.sort((a, b) => a.kind.index.compareTo(b.kind.index));
    return out;
  }

  /// Tags доступные в dropdown'ах (DNS Final / Default Resolver / per-rule).
  /// Filter `enabled` на ref-level.
  List<String> get _enabledServerTags {
    final out = <String>[];
    for (final s in _displayedServers) {
      if (!s.enabled) continue;
      if (s.tag.isEmpty) continue;
      out.add(s.tag);
    }
    return out;
  }

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
    _showServerEditor(
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

  /// §044: универсальный editor для DNS-server entry. Три явных input'а
  /// (tag / description / enabled) + body JSON (sing-box body **без**
  /// tag/description/enabled — они на ref-level).
  ///
  /// Validation на save:
  /// - tag непустой
  /// - если `lockedTag: true` — tag не редактируем (read-only input)
  /// - body — валидный JSON object; auto-strip tag/description/enabled
  ///   если случайно оставлены
  void _showServerEditor({
    required String title,
    required String initialTag,
    required bool lockedTag,
    required String initialDescription,
    required bool initialEnabled,
    required Map<String, dynamic> initialBody,
    required void Function(
      String tag,
      String description,
      bool enabled,
      Map<String, dynamic> body,
    ) onSave,
  }) {
    final tagCtrl = TextEditingController(text: initialTag);
    final descCtrl = TextEditingController(text: initialDescription);
    final bodyCtrl = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(initialBody),
    );
    var enabled = initialEnabled;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 12),
              TextField(
                controller: tagCtrl,
                readOnly: lockedTag,
                decoration: InputDecoration(
                  labelText: 'Tag',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  helperText: lockedTag ? 'Tag locked while editing' : null,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: descCtrl,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Enabled'),
                value: enabled,
                onChanged: (v) => setSheetState(() => enabled = v),
              ),
              const SizedBox(height: 8),
              const Text('Body (sing-box JSON)',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              SizedBox(
                height: 180,
                child: TextField(
                  controller: bodyCtrl,
                  maxLines: null,
                  expands: true,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () {
                  final tag = tagCtrl.text.trim();
                  if (tag.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Tag is required')));
                    return;
                  }
                  Map<String, dynamic> body;
                  try {
                    final parsed = jsonDecode(bodyCtrl.text);
                    if (parsed is! Map<String, dynamic>) {
                      throw const FormatException(
                          'Body must be a JSON object');
                    }
                    body = parsed;
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content:
                            Text('Invalid body JSON: ${formatUserError(e)}')));
                    return;
                  }
                  // §044: tag/description/enabled — на ref-level. Если юзер
                  // случайно оставил их в body — silently strip (warn'ить
                  // не будем, тривиально).
                  body
                    ..remove('tag')
                    ..remove('description')
                    ..remove('enabled')
                    ..remove('_origin')
                    ..remove('_kind')
                    ..remove('_overrides')
                    ..remove('_preset_label');
                  Navigator.pop(ctx);
                  onSave(tag, descCtrl.text.trim(), enabled, body);
                },
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    ).then((_) {
      tagCtrl.dispose();
      descCtrl.dispose();
      bodyCtrl.dispose();
    });
  }

  void _addUserRule() => _showUserRuleEditor(-1);

  void _showUserRuleEditor(int index) {
    final isNew = index < 0;
    final existing = isNew ? null : _rules[index];
    final nameCtrl = TextEditingController(
      text: existing?['name']?.toString() ?? '',
    );
    final body = existing?['rule'];
    final bodyCtrl = TextEditingController(
      text: body is Map<String, dynamic>
          ? const JsonEncoder.withIndent('  ').convert(body)
          : '{\n  "rule_set": "geoip-ru",\n  "server": "yandex_doh"\n}',
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(isNew ? 'Add DNS Rule' : 'Edit DNS Rule',
                style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: TextField(
                controller: bodyCtrl,
                maxLines: null,
                expands: true,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: 'Rule body (JSON)',
                  border: OutlineInputBorder(),
                  isDense: true,
                  alignLabelWithHint: true,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'sing-box DNS rule shape: {rule_set, domain, domain_suffix, server, ...}',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Name is required')));
                  return;
                }
                Map<String, dynamic>? parsed;
                try {
                  final obj = jsonDecode(bodyCtrl.text);
                  if (obj is! Map<String, dynamic>) {
                    throw const FormatException('Rule body must be a JSON object');
                  }
                  parsed = obj;
                } catch (e) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('Invalid JSON: ${formatUserError(e)}')));
                  return;
                }
                Navigator.pop(ctx);
                setState(() {
                  final entry = <String, dynamic>{
                    'enabled': existing?['enabled'] ?? true,
                    'kind': 'inline',
                    'name': name,
                    'rule': parsed,
                  };
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
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ).then((_) {
      nameCtrl.dispose();
      bodyCtrl.dispose();
    });
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
          ..._displayedServers.map(_buildMergedServerTile),

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
              itemBuilder: (ctx, i) => _buildRuleTile(
                i,
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
          _resolverPicker(
            context: context,
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
          _resolverPicker(
            context: context,
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
            _localResolverWarningBanner(context),
        ],
      ),
    );
  }

  /// §047/§048 — DNS resolver picker с info-icon ℹ tooltip'ом и опциональным
  /// жёлтым ⚠ маркером когда выбран `local_dns_resolver` (только для
  /// `Default Domain Resolver` поля — там это antipattern).
  Widget _resolverPicker({
    required BuildContext context,
    required String title,
    required String subtitle,
    required String value,
    required List<String> serverTags,
    required ValueChanged<String> onChanged,
    required String tooltip,
    required bool warnIfLocal,
  }) {
    final cs = Theme.of(context).colorScheme;
    final showWarn = warnIfLocal && value == 'local_dns_resolver';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Row(
        children: [
          Tooltip(
            message: tooltip,
            preferBelow: false,
            triggerMode: TooltipTriggerMode.tap,
            showDuration: const Duration(seconds: 12),
            waitDuration: const Duration(milliseconds: 100),
            child: Icon(
              showWarn ? Icons.warning_amber_rounded : Icons.info_outline,
              size: 18,
              color: showWarn ? Colors.amber.shade700 : cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Text(title),
        ],
      ),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: DropdownButton<String>(
        value: serverTags.contains(value) ? value : null,
        hint: const Text('select'),
        items: serverTags
            .map((t) => DropdownMenuItem(
                value: t,
                child: Text(t, style: const TextStyle(fontSize: 13))))
            .toList(),
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  /// §047 — banner который показывается под `Default Domain Resolver` когда
  /// выбран `local_dns_resolver`. Объясняет риск + предлагает quick-fix
  /// «Switch to cloudflare_udp» если этот server существует в catalog'е.
  Widget _localResolverWarningBanner(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasCloudflareUdp = _servers.any((s) => s['tag'] == 'cloudflare_udp');
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 4, 0, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.amber.shade400),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 18, color: Colors.amber.shade800),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'System DNS leaks lookups to your ISP',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Hostnames sing-box resolves internally (your VPN server '
            'addresses, custom outbound endpoints) will go through your '
            'ISP\'s DNS, bypassing the VPN tunnel. Pick a regular DNS '
            'server for full privacy.',
            style: TextStyle(fontSize: 12, color: cs.onSurface),
          ),
          if (hasCloudflareUdp) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.bolt, size: 16),
                label: const Text('Switch to cloudflare_udp'),
                onPressed: () => setState(() {
                  _defaultResolver = 'cloudflare_udp';
                  _markDirty();
                }),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.amber.shade900,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// §044: единый builder через typed `ResolvedServer`. Никаких Map['_kind'] —
  /// classification через typed accessors на ResolvedServer.
  ///
  /// - `kind: template` — badge `Template`, edit (copy-on-write) + switch
  /// - `kind: preset`   — badge `Preset` (subtitle с preset-label), edit + switch
  /// - `kind: inline` + `overrides != null` — badge `Overridden`, edit + reset (↺)
  /// - `kind: inline` + `overrides == null` — badge `User`, edit + delete (🗑)
  Widget _buildMergedServerTile(ResolvedServer entry) {
    final type = entry.body['type']?.toString() ?? '';
    final addr = entry.body['server']?.toString() ?? '';
    final theme = Theme.of(context);

    // Короткие labels (§044).
    final (String badgeText, Color badgeColor) = switch (entry.kind) {
      ServerKind.template => ('Template', theme.colorScheme.tertiary),
      ServerKind.preset => ('Preset', theme.colorScheme.primary),
      ServerKind.inline => entry.isOverridden
          ? ('Overridden', theme.colorScheme.error.withValues(alpha: 0.9))
          : ('User', theme.colorScheme.secondary),
    };

    return Card(
      child: ListTile(
        onTap: () => _showServerBodyDialog(entry),
        leading: SizedBox(
          width: 40,
          child: Switch(
            value: entry.enabled,
            onChanged: (v) => _toggleServerEnabled(entry.tag, v),
          ),
        ),
        title: Text(
          entry.description.isNotEmpty ? entry.description : entry.tag,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: entry.enabled ? null : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        subtitle: Text(
          '${entry.tag} · $type${addr.isNotEmpty ? ' · $addr' : ''}'
          '${entry.presetLabel != null && entry.presetLabel!.isNotEmpty ? ' · ${entry.presetLabel}' : ''}',
          style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
        ),
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _badge(badgeText, badgeColor),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  tooltip: 'Edit',
                  onPressed: () => _editServerBody(entry.tag),
                  visualDensity: VisualDensity.compact,
                ),
                if (entry.isOverridden)
                  IconButton(
                    icon: const Icon(Icons.restart_alt, size: 18),
                    tooltip: 'Reset to default',
                    onPressed: () => _resetServerToCanonical(entry.tag),
                    visualDensity: VisualDensity.compact,
                  )
                else if (entry.isUserOnly)
                  IconButton(
                    icon: Icon(Icons.delete_outline,
                        size: 18, color: theme.colorScheme.error),
                    tooltip: 'Delete',
                    onPressed: () => _deleteServer(entry.tag),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ),
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

    _showServerEditor(
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

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.w500),
      ),
    );
  }

  /// Read-only dialog с полным JSON DNS-сервера.
  /// §044: read-only dialog показывает body синтезированного sing-box shape'а
  /// (без UI-аннотаций — их физически нет в `ResolvedServer.body`).
  void _showServerBodyDialog(ResolvedServer server) {
    final pretty = const JsonEncoder.withIndent('  ').convert(server.body);
    final title = server.description.isNotEmpty ? server.description : server.tag;
    final sourceLabel = switch (server.kind) {
      ServerKind.template => 'Template',
      ServerKind.preset =>
        server.presetLabel != null && server.presetLabel!.isNotEmpty
            ? 'Preset · ${server.presetLabel}'
            : 'Preset',
      ServerKind.inline =>
        server.isOverridden ? 'Overridden' : 'User',
    };
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: const TextStyle(fontSize: 15)),
            Text(sourceLabel,
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
          ],
        ),
        content: SingleChildScrollView(
          child: SelectableText(
            pretty,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// §033: builds a tile for a single `dns_options.rules[i]` entry.
  Widget _buildRuleTile(int index, {required Key key}) {
    final entry = _rules[index];
    final kind = entry['kind'] as String? ?? 'inline';
    final enabled = entry['enabled'] == true;
    final theme = Theme.of(context);

    // §033: title для kind=preset рендерится динамически из текущего шаблона
    // (storage хранит presetId), для остальных — берётся из entry.name.
    final String displayTitle;
    Map<String, dynamic>? body;
    if (kind == 'inline') {
      displayTitle = entry['name'] as String? ?? '';
      final r = entry['rule'];
      if (r is Map<String, dynamic>) body = r;
    } else if (kind == 'template') {
      displayTitle = entry['name'] as String? ?? '';
      body = _templateRulesByName[displayTitle];
    } else if (kind == 'preset') {
      final pid = entry['presetId'] as String? ?? '';
      displayTitle = _presetLabelByPresetId[pid] ?? pid;
      body = _presetRulesByPresetId[pid];
    } else if (kind == 'srs') {
      displayTitle = entry['name'] as String? ?? '';
      // body: показываем сам entry как preview (срz config'а здесь нет — body
      // строится builder'ом при emit'е). Достаточно для UI.
      body = {
        'srsUrl': entry['srsUrl'],
        'server': entry['server'],
      };
    } else {
      displayTitle = entry['name'] as String? ?? '';
    }

    final preview = _formatRulePreview(body, kind: kind);

    final badgeText = switch (kind) {
      'template' => 'from template',
      'preset' => 'from preset',
      'srs' => 'srs',
      _ => 'inline',
    };
    final badgeColor = switch (kind) {
      'template' => theme.colorScheme.tertiary,
      'preset' => theme.colorScheme.primary,
      'srs' => theme.colorScheme.outline,
      _ => theme.colorScheme.secondary,
    };

    return Card(
      key: key,
      child: ListTile(
        onTap: () => _showRuleBodyDialog(displayTitle, kind, body),
        leading: SizedBox(
          width: 80,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.drag_handle, size: 20),
                ),
              ),
              Switch(
                value: enabled,
                onChanged: (v) {
                  setState(() {
                    _rules[index] = Map<String, dynamic>.from(entry)..['enabled'] = v;
                    _markDirty();
                  });
                },
              ),
            ],
          ),
        ),
        title: Text(
          displayTitle,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: enabled ? null : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        subtitle: Text(
          preview,
          style: TextStyle(
            fontSize: 11,
            color: theme.colorScheme.onSurfaceVariant,
            fontFamily: 'monospace',
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        // Badge над action-кнопками. У kind:inline — edit/delete; у
        // template/preset/srs — только badge (не редактируются).
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _badge(badgeText, badgeColor),
            if (kind == 'inline') ...[
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: () => _showUserRuleEditor(index),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline,
                        size: 18, color: theme.colorScheme.error),
                    onPressed: () {
                      setState(() {
                        _rules.removeAt(index);
                        _markDirty();
                      });
                    },
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Read-only dialog с полным JSON body правила. Юзер видит что внутри
  /// без необходимости лезть в исходник (особенно для kind=template/rule
  /// где body proxy'ится из шаблона/пресета).
  void _showRuleBodyDialog(String title, String kind, Map<String, dynamic>? body) {
    final pretty = body == null
        ? '(content unavailable)'
        : const JsonEncoder.withIndent('  ').convert(body);
    final sourceLabel = switch (kind) {
      'template' => 'from template',
      'preset' => 'from preset',
      'srs' => 'srs',
      _ => 'user rule',
    };
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: const TextStyle(fontSize: 15)),
            Text(sourceLabel,
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
          ],
        ),
        content: SingleChildScrollView(
          child: SelectableText(
            pretty,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _formatRulePreview(Map<String, dynamic>? body, {required String kind}) {
    if (body == null) {
      // Should not happen post-resolve; defensive fallback.
      return kind == 'preset' ? '(preset disabled — orphan)'
          : kind == 'template' ? '(missing in template)'
          : '';
    }
    final parts = <String>[];
    final clean = Map<String, dynamic>.from(body)
      ..remove('name')
      ..remove('enabled_default');
    for (final entry in clean.entries) {
      final v = entry.value;
      if (v is List && v.length > 3) {
        parts.add('${entry.key}: [${v.take(2).join(', ')}, …]');
      } else if (v is List) {
        parts.add('${entry.key}: ${v.join(', ')}');
      } else {
        parts.add('${entry.key}: $v');
      }
    }
    return parts.join(' · ');
  }
}


// ===========================================================================
// §044: Typed render-layer for DNS servers (заменяет underscore-аннотации
// в Map'ах из §043).
// ===========================================================================

/// Порядок enum-значений = порядок render'а в UI (§044): template первым
/// (системные defaults), потом preset (от active preset'ов), потом inline
/// (user-defined / overrides). `_displayedServers` сортирует по `kind.index`.
enum ServerKind {
  template,
  preset,
  inline;

  static ServerKind? tryParse(String s) {
    switch (s) {
      case 'inline':
        return ServerKind.inline;
      case 'preset':
        return ServerKind.preset;
      case 'template':
        return ServerKind.template;
    }
    return null;
  }

  String get name => toString().split('.').last;
}

/// §044: typed wrapper для render'а DNS-сервера в UI. Заменяет Map с
/// underscore-полями (`_kind`/`_overrides`/`_preset_label`).
///
/// Источники полей:
/// - `kind`/`tag`/`enabled` — `dns_options.servers[i]`
/// - `description` — `dns_options.servers[i].description` если override; иначе
///   из canonical (template/preset by tag)
/// - `body` — для inline это `dns_options.servers[i].body`; для template/preset —
///   canonical lookup. В обоих случаях с injected `tag` (single source of truth).
/// - `overrides`/`presetLabel` — computed (kind canonical'а если ref overrides).
class ResolvedServer {
  const ResolvedServer({
    required this.kind,
    required this.tag,
    required this.description,
    required this.enabled,
    required this.body,
    this.overrides,
    this.presetLabel,
  });

  final ServerKind kind;
  final String tag;
  final String description;
  final bool enabled;
  final Map<String, dynamic> body;
  final ServerKind? overrides;
  final String? presetLabel;

  bool get isOverridden => kind == ServerKind.inline && overrides != null;
  bool get isUserOnly => kind == ServerKind.inline && overrides == null;
}
