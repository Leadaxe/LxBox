/// §680/§681 — удерживающие ссылки на DNS-сервер: кто в состоянии ссылается
/// на тег так, что снять сервер нельзя.
///
/// Один расчёт на два потребителя:
///  * вкладка DNS (§680 п. 3) — ссылки самого списка ([dnsServerListHolds]):
///    группы, `domain_resolver` других серверов, DNS Final / Default Domain
///    Resolver; подписи «used by» строит `dnsServerListRefs` экрана поверх
///    этого же списка;
///  * импорт LX-бэкапа (§681, контракт 1.1.135, D-139, BACKUP.md §9 п. 5) —
///    первая удерживающая ссылка по закрытому словарю `used_by`
///    предупреждения `backup_dns_entry_kept` ([dnsServerFirstHolds]).
///
/// Порядок значений [DnsHoldKind] — порядок словаря контракта: при
/// нескольких ссылках пишется первая по нему.
library;

import '../../models/custom_rule.dart';
import '../../models/dns_ref.dart';
import '../../models/parser_config.dart' show SelectableRule;
import '../builder/post_steps.dart' show resolveTemplateDnsServerBody;
import '../builder/preset_expand.dart' show expandPreset;

/// Вид удерживающей ссылки; порядок = словарь `used_by` (BACKUP.md §9 п. 5).
enum DnsHoldKind {
  dnsFinal,
  defaultDomainResolver,
  dnsRule,
  rule,
  group,
  server,
  preset,
  required,
}

/// Одна удерживающая ссылка: вид и источник (тег, имя правила, id пресета).
class DnsServerHold {
  const DnsServerHold(this.kind, [this.source = '']);

  final DnsHoldKind kind;

  /// `dns_rule` — тег сервера правила; `rule` — имя маршрутного правила;
  /// `group` / `server` — тег сервера-источника; `preset` — `preset_id`.
  /// У `final` / `default_domain_resolver` / `required` пусто.
  final String source;

  /// Значение `used_by` по словарю контракта.
  String get usedBy => switch (kind) {
        DnsHoldKind.dnsFinal => 'final',
        DnsHoldKind.defaultDomainResolver => 'default_domain_resolver',
        DnsHoldKind.dnsRule => 'dns_rule:$source',
        DnsHoldKind.rule => 'rule:$source',
        DnsHoldKind.group => 'group:$source',
        DnsHoldKind.server => 'server:$source',
        DnsHoldKind.preset => 'preset:$source',
        DnsHoldKind.required => 'required',
      };

  @override
  bool operator ==(Object other) =>
      other is DnsServerHold && other.kind == kind && other.source == source;

  @override
  int get hashCode => Object.hash(kind, source);

  @override
  String toString() => usedBy;
}

/// §680 — ссылки из самого списка: tag → ссылки в порядке обнаружения.
/// Источники (только записи [servers] — группа вне списка никого не держит):
/// - группа (`type: group`) — каждый член `servers[]`;
/// - `domain_resolver` другого сервера (строка или `{server}`; у template —
///   после подстановки vars, `dom_resolver` у `safe_dns_dot`);
/// - [dnsFinal] / [defaultResolver].
/// [servers] — тег и тело в emit-форме, в порядке списка. Ссылка сервера на
/// себя не считается. — pure.
Map<String, List<DnsServerHold>> dnsServerListHolds(
  Iterable<({String tag, Map<String, dynamic> body})> servers, {
  String dnsFinal = '',
  String defaultResolver = '',
}) {
  final refs = <String, List<DnsServerHold>>{};
  void add(String? target, DnsServerHold hold, {String? self}) {
    if (target == null || target.isEmpty || target == self) return;
    final list = refs.putIfAbsent(target, () => []);
    if (!list.contains(hold)) list.add(hold);
  }

  for (final s in servers) {
    if (s.body['type'] == 'group') {
      for (final m in (s.body['servers'] as List<dynamic>? ?? const [])) {
        add(m?.toString(), DnsServerHold(DnsHoldKind.group, s.tag),
            self: s.tag);
      }
    }
    final dr = s.body['domain_resolver'];
    add(dr is Map ? dr['server']?.toString() : dr?.toString(),
        DnsServerHold(DnsHoldKind.server, s.tag),
        self: s.tag);
  }
  add(dnsFinal, const DnsServerHold(DnsHoldKind.dnsFinal));
  add(defaultResolver, const DnsServerHold(DnsHoldKind.defaultDomainResolver));
  return refs;
}

/// §681 — включённые пресеты [routingRules], раскрытые по шаблону
/// [presets]: `preset_id` → серверы и DNS-правила пресета. Узлов обхода нет
/// (`for_each_node` даёт `<узел>-dns`, тегов каталога у него не бывает).
/// — pure.
Map<String, ({List<Map<String, dynamic>> servers, List<Map<String, dynamic>> rules})>
    activePresetDns(List<CustomRule> routingRules, List<SelectableRule> presets) {
  final byId = {for (final p in presets) p.presetId: p};
  final out = <String,
      ({List<Map<String, dynamic>> servers, List<Map<String, dynamic>> rules})>{};
  for (final cr in routingRules) {
    if (cr is! CustomRulePreset || !cr.enabled || cr.presetId.isEmpty) continue;
    final match = byId[cr.presetId];
    if (match == null || out.containsKey(cr.presetId)) continue;
    final fragments = expandPreset(cr, match);
    out[cr.presetId] = (servers: fragments.dnsServers, rules: fragments.dnsRules);
  }
  return out;
}

/// §681 — теги, которые сборка эмитит независимо от `enabled` (§117 №7,
/// [dnsServerRefEmitted]): серверы включённых пресетов и цели активных
/// DNS-опций маршрутных правил. — pure.
Set<String> dnsForcedTags(
  List<CustomRule> routingRules,
  Map<String, ({List<Map<String, dynamic>> servers, List<Map<String, dynamic>> rules})>
      presetDns,
) =>
    {
      for (final p in presetDns.values)
        for (final s in p.servers)
          if (s['tag'] case final String tag when tag.isNotEmpty) tag,
      for (final cr in routingRules)
        if (cr.dnsMirrorActive) cr.dns!.serverTag,
    };

/// §681 — первая удерживающая ссылка на каждый тег состояния (словарь
/// `used_by`, BACKUP.md §9 п. 5): tag → ссылка; тега без ссылок в карте нет.
///
/// Источники по словарю:
/// - `final` / `default_domain_resolver` — [dnsFinal] / [defaultResolver]
///   (значения после импорта, пустое — умолчание шаблона уже подставлено
///   вызывающим);
/// - `dns_rule:<server>` — DNS-правило списка [dnsRules] (`server` у
///   пользовательского и `srs`; ссылки `preset` — через пресет ниже,
///   `template` — правила шаблона, у LxBox их нет);
/// - `rule:<name>` — объект `dns` маршрутного правила [routingRules]
///   (`serverTag`; правило без имени — `rule`);
/// - `group:<tag>` / `server:<tag>` — ссылки самого списка
///   ([dnsServerListHolds]);
/// - `preset:<id>` — сервер включённого пресета под тем же тегом, член его
///   группы, его `domain_resolver` или `server` его DNS-правила;
/// - `required` — `required: true` у обёртки сервера в шаблоне
///   ([templateByTag]); в шаблоне LxBox такого нет, правило одно на обе
///   стороны.
///
/// Тела серверов [servers]: inline — `body`, template — обёртка шаблона с
/// подставленными `vars`, preset — тело из раскрытого пресета. — pure.
Map<String, DnsServerHold> dnsServerFirstHolds({
  required List<DnsServerRef> servers,
  required List<DnsRuleRef> dnsRules,
  required Map<String, Map<String, dynamic>> templateByTag,
  List<CustomRule> routingRules = const [],
  Map<String, ({List<Map<String, dynamic>> servers, List<Map<String, dynamic>> rules})>
      presetDns = const {},
  String dnsFinal = '',
  String defaultResolver = '',
}) {
  final all = <String, List<DnsServerHold>>{};
  void add(String? target, DnsServerHold hold) {
    if (target == null || target.isEmpty) return;
    all.putIfAbsent(target, () => []).add(hold);
  }

  final presetBodies = <String, Map<String, dynamic>>{
    for (final p in presetDns.values)
      for (final s in p.servers)
        if (s['tag'] case final String tag when tag.isNotEmpty) tag: s,
  };
  final bodies = <({String tag, Map<String, dynamic> body})>[
    for (final s in servers)
      if (s.tag.isNotEmpty)
        if (switch (s) {
          DnsServerInline(:final body) => body,
          DnsServerTemplate(:final tag, :final varValues) =>
            switch (templateByTag[tag]) {
              final t? => resolveTemplateDnsServerBody(t, varValues: varValues),
              null => null,
            },
          DnsServerPreset(:final tag) => presetBodies[tag],
        }
            case final body?)
          (tag: s.tag, body: body),
  ];
  for (final e in dnsServerListHolds(bodies,
          dnsFinal: dnsFinal, defaultResolver: defaultResolver)
      .entries) {
    for (final h in e.value) {
      add(e.key, h);
    }
  }

  for (final r in dnsRules) {
    final server = switch (r) {
      DnsRuleInline(:final rule) => rule['server'],
      DnsRuleSrs(:final server, :final body, :final rule) =>
        server ?? body?['server'] ?? rule?['server'],
      DnsRuleTemplate() || DnsRulePreset() => null,
    };
    if (server is String) add(server, DnsServerHold(DnsHoldKind.dnsRule, server));
  }

  for (final cr in routingRules) {
    final tag = cr.dns?.serverTag ?? '';
    add(tag, DnsServerHold(DnsHoldKind.rule, cr.name.isNotEmpty ? cr.name : 'rule'));
  }

  for (final e in presetDns.entries) {
    final hold = DnsServerHold(DnsHoldKind.preset, e.key);
    for (final s in e.value.servers) {
      add(s['tag']?.toString(), hold);
      if (s['type'] == 'group') {
        for (final m in (s['servers'] as List<dynamic>? ?? const [])) {
          add(m?.toString(), hold);
        }
      }
      final dr = s['domain_resolver'];
      add(dr is Map ? dr['server']?.toString() : dr?.toString(), hold);
    }
    for (final r in e.value.rules) {
      if (r['server'] case final String server) add(server, hold);
    }
  }

  for (final e in templateByTag.entries) {
    if (e.value['required'] == true) {
      add(e.key, const DnsServerHold(DnsHoldKind.required));
    }
  }

  return {
    for (final e in all.entries)
      e.key: e.value.reduce((a, b) => b.kind.index < a.kind.index ? b : a),
  };
}
