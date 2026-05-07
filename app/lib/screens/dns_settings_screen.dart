import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
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

/// DNS Settings (§014, §041).
///
/// §041 — DNS rules refactored to first-class named/toggleable model:
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

class _DnsSettingsScreenState extends State<DnsSettingsScreen> {
  /// User-saved DNS servers from storage. Может быть пустым (fresh install)
  /// или содержать любой subset: pure user-серверы (tag не в template/preset)
  /// + overrides (tag совпадает с template или preset).
  List<Map<String, dynamic>> _servers = [];

  /// Полный список template'овских серверов (`wizard_template.dns_options.servers`).
  /// Используется как overlay layer 2 в [_displayedServers] — если tag отсутствует
  /// в `_servers`, template-shape отображается напрямую.
  List<Map<String, dynamic>> _templateServersRaw = [];

  /// Tag → template-server map (производное от [_templateServersRaw]).
  /// Используется для override-detection в [_isOverridden].
  Map<String, Map<String, dynamic>> _templateByTag = {};

  /// §041 + §032: structured rules list `{enabled, kind, title?, presetId?, rule?}`.
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

  /// Preset-injected DNS-серверы. Stored as `[{tag, ..., _preset_label: '...'}]`
  /// per server для отрисовки read-only плитки с подписью пресета.
  List<Map<String, dynamic>> _presetServersWithLabel = [];

  bool _loading = true;
  Timer? _saveTimer;

  String _strategy = '';
  String _dnsFinal = '';
  String _defaultResolver = '';

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

  Future<void> _load() async {
    final template = await TemplateLoader.load();
    final userServers = await SettingsStorage.getDnsServers();
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

    // §042: storage = user's modifications + customs. Template и preset —
    // overlay-слои, мерджатся at render time в [_displayedServers].
    final servers = userServers;
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

    if (mounted) {
      setState(() {
        _servers = servers;
        _templateServersRaw = templateServersRaw;
        _templateByTag = templateByTag;
        _presetServersWithLabel = presetServersWithLabel;
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

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () => unawaited(_save()));
  }

  Future<void> _save() async {
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

    if (!mounted) return;
    final config = await widget.subController.generateConfig();
    if (config != null && mounted) {
      await widget.homeController.saveParsedConfig(config);
    }
  }

  /// §042: 3-tier merge с tag-приоритетом + override-detection.
  ///
  /// Order: **user → preset → template** — каждый следующий слой добавляет
  /// только tag'и которых нет в предыдущих. Preset технически может
  /// переписать template (если в active preset'е DNS-сервер с тем же tag'ом
  /// что в template'е — preset wins).
  ///
  /// User-saved entries классифицируются 3-state'ом:
  ///   • Нет canonical (preset/template) → `_origin: 'user'` (custom).
  ///   • Canonical есть, shape совпадает → `_origin: 'template'` или `'preset'`
  ///     (юзер просто toggle'нул `enabled` — не override).
  ///   • Canonical есть, shape отличается → `_origin: 'overridden'` +
  ///     `_overrides`: 'preset'|'template' (для UI subtitle / Reset action).
  ///
  /// Pure preset / template серверы (без user-saved counterpart) — `_origin`
  /// = 'preset'/'template' напрямую.
  List<Map<String, dynamic>> get _displayedServers {
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];

    /// Lookup canonical for tag (preset wins over template).
    /// Returns null + null if no canonical exists.
    (Map<String, dynamic>?, String?) findCanonical(String tag) {
      for (final p in _presetServersWithLabel) {
        if (p['tag'] == tag) return (p, 'preset');
      }
      final t = _templateByTag[tag];
      if (t != null) return (t, 'template');
      return (null, null);
    }

    void take(Map<String, dynamic> s, String origin, {String? overridesSrc, String? presetLabel}) {
      final tag = s['tag']?.toString();
      if (tag == null || tag.isEmpty) return;
      if (seen.contains(tag)) return;
      seen.add(tag);
      final annotated = Map<String, dynamic>.from(s)..['_origin'] = origin;
      if (overridesSrc != null) annotated['_overrides'] = overridesSrc;
      if (presetLabel != null && presetLabel.isNotEmpty) {
        annotated['_preset_label'] = presetLabel;
      }
      out.add(annotated);
    }

    for (final s in _servers) {
      final tag = s['tag']?.toString() ?? '';
      final (canonical, canonicalSrc) = findCanonical(tag);
      if (canonical == null) {
        take(s, 'user');
      } else if (_shapesMatch(s, canonical)) {
        // User-saved совпадает по shape с canonical → не override, просто
        // юзер toggle'нул enabled. Подхватим preset_label если есть.
        final pl = canonical['_preset_label']?.toString();
        take(s, canonicalSrc!, presetLabel: pl);
      } else {
        // Shape отличается — настоящий override.
        final pl = canonical['_preset_label']?.toString();
        take(s, 'overridden', overridesSrc: canonicalSrc, presetLabel: pl);
      }
    }
    for (final s in _presetServersWithLabel) {
      take(s, 'preset');
    }
    for (final s in _templateServersRaw) {
      take(s, 'template');
    }
    return out;
  }

  /// Tags доступные в dropdown'ах (DNS Final / Default Resolver / per-rule).
  /// Filter `enabled != false` (template'овские дефолты могут быть disabled).
  List<String> get _enabledServerTags {
    final out = <String>[];
    for (final s in _displayedServers) {
      if (s['enabled'] == false) continue;
      final t = s['tag']?.toString();
      if (t != null && t.isNotEmpty) out.add(t);
    }
    return out;
  }

  /// Deep-equality по shape (без `enabled`/`description`/UI-аннотаций).
  /// Order-insensitive — `DeepCollectionEquality` рекурсивно сравнивает
  /// nested maps/lists. Без этого `jsonEncode` мог давать разные строки на
  /// одинаковых shape'ах из-за порядка ключей после storage roundtrip.
  bool _shapesMatch(Map<String, dynamic> a, Map<String, dynamic> b) {
    Map<String, dynamic> strip(Map<String, dynamic> m) {
      final out = Map<String, dynamic>.from(m);
      out.remove('enabled');
      out.remove('description');
      out.remove('_origin');
      out.remove('_overrides');
      out.remove('_preset_label');
      return out;
    }

    return const DeepCollectionEquality().equals(strip(a), strip(b));
  }

  /// Reset override: удалить user-saved entry для этого tag'а.
  /// Сервер остаётся в списке через template/preset overlay.
  void _resetServerToCanonical(String tag) {
    setState(() {
      _servers.removeWhere((s) => s['tag'] == tag);
      _scheduleSave();
    });
  }

  void _addServer() {
    _showServerJsonEditor(-1);
  }

  void _showServerJsonEditor(int index) {
    final isNew = index < 0;
    final json = isNew
        ? '{\n  "type": "udp",\n  "tag": "dns_new",\n  "server": "1.1.1.1",\n  "server_port": 53,\n  "description": "My DNS",\n  "enabled": true\n}'
        : const JsonEncoder.withIndent('  ').convert(_servers[index]);
    final ctrl = TextEditingController(text: json);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(isNew ? 'Add DNS Server' : 'Edit DNS Server', style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 12),
            SizedBox(
              height: 200,
              child: TextField(
                controller: ctrl,
                maxLines: null,
                expands: true,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                try {
                  final obj = jsonDecode(ctrl.text) as Map<String, dynamic>;
                  if ((obj['tag']?.toString() ?? '').isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tag is required')));
                    return;
                  }
                  Navigator.pop(ctx);
                  setState(() {
                    if (isNew) {
                      _servers.add(obj);
                    } else {
                      _servers[index] = obj;
                    }
                    _scheduleSave();
                  });
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Invalid JSON: ${formatUserError(e)}')));
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ).then((_) => ctrl.dispose());
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
                  _scheduleSave();
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
              onChanged: (v) { if (v != null) setState(() { _strategy = v; _scheduleSave(); }); },
            ),
          ),

          const Divider(height: 32),

          // --- DNS Rules (§041) ---
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
                  _scheduleSave();
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
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('DNS Final'),
            subtitle: const Text('Fallback DNS server', style: TextStyle(fontSize: 12)),
            trailing: DropdownButton<String>(
              value: serverTags.contains(_dnsFinal) ? _dnsFinal : null,
              hint: const Text('select'),
              items: serverTags.map((t) => DropdownMenuItem(value: t, child: Text(t, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: (v) { if (v != null) setState(() { _dnsFinal = v; _scheduleSave(); }); },
            ),
          ),

          // --- Default Resolver ---
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Default Domain Resolver'),
            subtitle: const Text('Resolves domains in DNS server addresses', style: TextStyle(fontSize: 12)),
            trailing: DropdownButton<String>(
              value: serverTags.contains(_defaultResolver) ? _defaultResolver : null,
              hint: const Text('select'),
              items: serverTags.map((t) => DropdownMenuItem(value: t, child: Text(t, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: (v) { if (v != null) setState(() { _defaultResolver = v; _scheduleSave(); }); },
            ),
          ),
        ],
      ),
    );
  }

  /// §042: единый builder для всех трёх tier'ов merge'а. Различия по `_origin`:
  ///
  /// - **user**: edit + delete (🗑) — обычный user-сервер.
  /// - **user (overridden)**: tag совпадает с template/preset, shape отличается
  ///   → edit + reset (↺) — reset убирает user-saved entry, сервер возвращается
  ///   к canonical (template/preset shape).
  /// - **template**: read-only кроме switch enabled. Удалить нельзя (template
  ///   overlay восстановит на следующий render).
  /// - **preset**: full read-only (preset-managed, нет даже switch'а).
  Widget _buildMergedServerTile(Map<String, dynamic> entry) {
    final tag = entry['tag']?.toString() ?? '';
    final type = entry['type']?.toString() ?? '';
    final addr = entry['server']?.toString() ?? '';
    final desc = entry['description']?.toString() ?? '';
    final enabled = entry['enabled'] != false;
    final origin = entry['_origin']?.toString() ?? 'user';
    final presetLabel = entry['_preset_label']?.toString() ?? '';
    final theme = Theme.of(context);

    // Override-detection актуально только для origin=='user' (другие — canonical).
    final overrideStatus = origin == 'user' ? _isOverridden(entry) : null;
    final overridden = overrideStatus == true;
    final isUserOnly = origin == 'user' && overrideStatus == null;

    // Badge: текст + цвет. На overridden — указываем какой канонический
    // источник перекрыт (preset wins over template, см. _isOverridden lookup).
    final overriddenSource = overridden
        ? (_presetServersWithLabel.any((p) => p['tag'] == tag)
            ? 'preset'
            : 'template')
        : '';
    final (String badgeText, Color badgeColor) = switch (origin) {
      'template' => ('Template', theme.colorScheme.tertiary),
      'preset' => (
          presetLabel.isNotEmpty ? 'Preset · $presetLabel' : 'Preset',
          theme.colorScheme.primary,
        ),
      _ => isUserOnly
          ? ('User', theme.colorScheme.secondary)
          : (
              'User (overrides $overriddenSource)',
              theme.colorScheme.error.withValues(alpha: 0.9),
            ),
    };

    // index в _servers — нужен для edit handler (только для origin='user').
    final userIndex = origin == 'user'
        ? _servers.indexWhere((s) => s['tag'] == tag)
        : -1;

    // Switch enabled allowed для user и template (per-user override),
    // но НЕ для preset (preset-managed).
    final canToggle = origin != 'preset';

    return Card(
      child: ListTile(
        onTap: () => _showServerBodyDialog(entry,
            title: desc.isNotEmpty ? desc : tag, sourceLabel: badgeText),
        leading: SizedBox(
          width: 40,
          child: canToggle
              ? Switch(
                  value: enabled,
                  onChanged: (v) => _toggleServerEnabled(entry, v),
                )
              : Icon(Icons.push_pin_outlined,
                  size: 18, color: theme.colorScheme.primary),
        ),
        title: Text(
          desc.isNotEmpty ? desc : tag,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: enabled ? null : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        subtitle: Text(
          '$tag · $type${addr.isNotEmpty ? ' · $addr' : ''}'
          '${origin == 'preset' && presetLabel.isNotEmpty ? ' · $presetLabel' : ''}',
          style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
        ),
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _badge(badgeText, badgeColor),
            if (origin == 'user') ...[
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: userIndex >= 0
                        ? () => _showServerJsonEditor(userIndex)
                        : null,
                    visualDensity: VisualDensity.compact,
                  ),
                  if (overridden)
                    IconButton(
                      icon: const Icon(Icons.restart_alt, size: 18),
                      tooltip: 'Reset to default',
                      onPressed: () => _resetServerToCanonical(tag),
                      visualDensity: VisualDensity.compact,
                    )
                  else
                    IconButton(
                      icon: Icon(Icons.delete_outline,
                          size: 18, color: theme.colorScheme.error),
                      onPressed: userIndex >= 0
                          ? () {
                              setState(() {
                                _servers.removeAt(userIndex);
                                _scheduleSave();
                              });
                            }
                          : null,
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

  /// Toggle enabled для сервера в merged-list view'е. Если origin='template',
  /// первое переключение копирует template-shape в `_servers` с применённым
  /// флагом (copy-on-write). Для existing user-saved — обычный update.
  void _toggleServerEnabled(Map<String, dynamic> entry, bool value) {
    final tag = entry['tag']?.toString();
    if (tag == null || tag.isEmpty) return;

    setState(() {
      final existingIdx = _servers.indexWhere((s) => s['tag'] == tag);
      if (existingIdx >= 0) {
        // User-saved entry — обычный update.
        _servers[existingIdx] = Map<String, dynamic>.from(_servers[existingIdx])
          ..['enabled'] = value;
      } else {
        // Template-only (copy-on-write) — берём template shape, применяем enabled.
        final canonical = _templateByTag[tag];
        if (canonical != null) {
          final copy = Map<String, dynamic>.from(canonical)..['enabled'] = value;
          // Ничего не аннотируем (`_origin` не сохраняем в storage).
          copy.remove('_origin');
          _servers.add(copy);
        }
        // origin == 'preset' не доходит сюда — у него canToggle=false.
      }
      _scheduleSave();
    });
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
  void _showServerBodyDialog(Map<String, dynamic> server,
      {required String title, required String sourceLabel}) {
    final clean = Map<String, dynamic>.from(server)..remove('_preset_label');
    final pretty = const JsonEncoder.withIndent('  ').convert(clean);
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
                    _scheduleSave();
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
                        _scheduleSave();
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
