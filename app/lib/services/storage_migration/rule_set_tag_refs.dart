/// §757 (контракт 1.1.182, TASKS_LXBOX §185, TEMPLATE_LANG §6.13
/// «перезапись ссылок») — разовая перезапись рукописных ссылок `rule_set` на
/// прежние теги наборов собственных правил.
///
/// Где: тела правил маршрута `rules[]` (`rule_set` простых узлов дерева и
/// verbatim-JSON на любом уровне) и собственные DNS-правила `dns.rules[]`
/// (`body` и `rule` записей `user` | `srs`, на любом уровне `logical`).
///
/// Прежние схемы LxBox (`имя` — база правила `B'` после развода, §6.13 п. 3):
/// - до §757 — первая ссылка `имя`, N-я ссылка `имя-N` (N ≥ 2);
/// - промежуточная 1.1.179–1.1.181 (только develop) — первая ссылка корня
///   `имя`, прочие `имя:<h8>` (`имя:<h16>` при совпадении h8), inline-набор
///   корня со ссылками `имя:inline`.
///
/// Правила: тег N-й ссылки → нынешний тег N-й ссылки; `имя:inline` → `имя`;
/// голый `имя` остаётся, если у правила есть свой inline-набор корня (теперь
/// это его тег), иначе уходит на нынешний тег первой ссылки дерева. Тег,
/// совпадающий с нынешним тегом какого-либо набора (правила, шаблона,
/// пресета), не трогается; чужие теги — тоже. Повторный прогон ничего не
/// меняет, кроме голого `имя` правила без своего inline-набора — поэтому
/// вызывающий держит маркер «выполнено» (`rule_set_tags_migrated`).
library;

import '../../models/codec/rule_record.dart';
import '../../models/custom_rule.dart';
import '../../models/parser_config.dart' show SelectableRule;
import '../builder/post_steps.dart' show customRuleAxisTags;
import '../builder/rule_tree_tags.dart';
import '../settings_storage_keys.dart';

/// §757 — карта «прежний тег → нынешний» по правилам оси [rules] (порядок
/// оси — как у сборки). Теги шаблона [takenTags] и наборов [presets] заняты,
/// как в сборке.
Map<String, String> legacyRuleSetTagMap(
  List<CustomRule> rules, {
  required Iterable<String> takenTags,
  required List<SelectableRule> presets,
}) {
  final axis = customRuleAxisTags(
    rules,
    takenTags: takenTags,
    presets: presets,
  );
  // Нынешние теги наборов — не трогаются никогда.
  final current = <String>{
    ...takenTags,
    for (final cr in rules)
      if (cr is CustomRulePreset)
        for (final p in presets)
          if (p.presetId == cr.presetId)
            for (final rs in p.ruleSets)
              if (rs['tag'] case final String tag when tag.isNotEmpty) tag,
    for (final t in axis.values) ...[
      ...t.refTags.values,
      ...t.inlineTags.values,
    ],
  };

  // Голое имя главнее `имя-N` чужого правила (`X-2` — база правила «X-2»).
  final bare = <String, String>{};
  final derived = <String, String>{};
  for (final r in rules) {
    if (r is! CustomRuleTree) continue;
    final tags = axis[r.id];
    if (tags == null) continue;
    final base = tags.base;
    final refs = r.allRefs.map((e) => e.trim()).toList();
    if (refs.isEmpty) continue;
    final hasRootInline = tags.inlineTags.containsKey('');
    // Первая ссылка — первая в обходе дерева: у записи старой формы с
    // корнем `logical` ссылки ушли в лист `and`-обёртки (§182 п. 1.2).
    if (!hasRootInline) {
      final first = tags.tagOfRef(refs.first);
      if (first != null) bare.putIfAbsent(base, () => first);
    }
    if (hasRootInline) derived.putIfAbsent('$base:inline', () => base);
    for (var i = 0; i < refs.length; i++) {
      final now = tags.tagOfRef(refs[i]);
      if (now == null) continue;
      if (i > 0) derived.putIfAbsent('$base-${i + 1}', () => now);
      derived.putIfAbsent('$base:${ruleRefHash(refs[i])}', () => now);
      derived.putIfAbsent(
          '$base:${ruleRefHash(refs[i], length: 16)}', () => now);
    }
  }
  final out = <String, String>{...derived, ...bare};
  out.removeWhere((old, now) => old == now || current.contains(old));
  return out;
}

/// §757 — перезапись ссылок в документе хранения [doc] на месте; итог —
/// число заменённых тегов. Записи разбираются кодеком хранения
/// ([ruleFromRecord] с `unknownAsVerbatim`), битые пропускаются.
int migrateRuleSetTagRefs(
  Map<String, dynamic> doc, {
  required Iterable<String> takenTags,
  required List<SelectableRule> presets,
  List<CustomRule> Function(List<CustomRule>)? order,
}) {
  final records = doc[kRulesKey];
  final dns = doc[kDnsKey];
  final dnsRules = dns is Map ? dns[kDnsRulesKey] : null;
  if (records is! List) return 0;
  final rules = <CustomRule>[
    for (final rec in records)
      if (rec is Map)
        if (ruleFromRecord(rec.cast<String, dynamic>(), unknownAsVerbatim: true)
            .value
            case final CustomRule r)
          r,
  ];
  final map = legacyRuleSetTagMap(
    order == null ? rules : order(rules),
    takenTags: takenTags,
    presets: presets,
  );
  if (map.isEmpty) return 0;
  var n = 0;
  for (final rec in records) {
    if (rec is! Map) continue;
    final kind = rec['kind'];
    if (kind != 'inline' && kind != 'srs') continue;
    n += _rewrite(rec['body'], map);
  }
  if (dnsRules is List) {
    for (final rec in dnsRules) {
      if (rec is! Map) continue;
      final kind = rec['kind'];
      if (kind != 'user' && kind != 'srs') continue;
      n += _rewrite(rec['body'], map) + _rewrite(rec['rule'], map);
    }
  }
  return n;
}

/// `rule_set` узла [node] и его `rules` (logical) — по [map]; итог — число
/// замен.
int _rewrite(Object? node, Map<String, String> map) {
  if (node is! Map) return 0;
  var n = 0;
  final rs = node['rule_set'];
  if (rs is String) {
    final now = map[rs];
    if (now != null) {
      node['rule_set'] = now;
      n++;
    }
  } else if (rs is List) {
    for (var i = 0; i < rs.length; i++) {
      final now = map[rs[i]];
      if (now != null) {
        rs[i] = now;
        n++;
      }
    }
  }
  final children = node['rules'];
  if (children is List) {
    for (final c in children) {
      n += _rewrite(c, map);
    }
  }
  return n;
}
