import '../../../models/custom_rule.dart';
import '../../rule_set_downloader.dart';
import '../../template_loader.dart';

/// Serializer для `/state/rules` и `/rules/*` (§030 Custom rules, task 011).
///
/// Sealed-dispatch по `kind`: каждый variant эмитит только релевантные поля.
/// Не публикуем пустые массивы для полей которых у variant'а вообще нет —
/// это шумело в старом API (inline-поля у preset-rules создавали впечатление
/// что у preset есть match-матчеры).
///
/// Для preset-правил читаем шаблон (`TemplateLoader.load()`) чтобы отдать
/// `preset.label` / `remote_rule_sets` с детальным SRS-cache статусом каждого
/// remote-rule_set'а пресета — критично для диагностики «почему правило
/// показывает no-cached-file» без раскрытия UI.
Future<Map<String, Object?>> serializeCustomRule(CustomRule r) async {
  final base = <String, Object?>{
    'id': r.id,
    'name': r.name,
    'enabled': r.enabled,
    'kind': r.kind.name,
  };
  switch (r) {
    case CustomRuleInline():
      return {
        ...base,
        if (r.domains.isNotEmpty) 'domains': r.domains,
        if (r.domainSuffixes.isNotEmpty) 'domain_suffixes': r.domainSuffixes,
        if (r.domainKeywords.isNotEmpty) 'domain_keywords': r.domainKeywords,
        if (r.ipCidrs.isNotEmpty) 'ip_cidrs': r.ipCidrs,
        if (r.ports.isNotEmpty) 'ports': r.ports,
        if (r.portRanges.isNotEmpty) 'port_ranges': r.portRanges,
        if (r.packages.isNotEmpty) 'packages': r.packages,
        if (r.protocols.isNotEmpty) 'protocols': r.protocols,
        if (r.ipIsPrivate) 'ip_is_private': true,
        'outbound': r.outbound,
      };
    case CustomRuleSrs():
      final cachedPath = await RuleSetDownloader.cachedPath(r.id);
      final mtime = await RuleSetDownloader.lastUpdated(r.id);
      return {
        ...base,
        'srs_url': r.srsUrl,
        if (r.ports.isNotEmpty) 'ports': r.ports,
        if (r.portRanges.isNotEmpty) 'port_ranges': r.portRanges,
        if (r.packages.isNotEmpty) 'packages': r.packages,
        if (r.protocols.isNotEmpty) 'protocols': r.protocols,
        if (r.ipIsPrivate) 'ip_is_private': true,
        'outbound': r.outbound,
        'srs': {
          'cached': cachedPath != null,
          'path': cachedPath,
          'mtime': mtime?.toUtc().toIso8601String(),
        },
      };
    case CustomRulePreset():
      final preset = await _lookupPreset(r.presetId);
      final remoteRuleSets = <Map<String, Object?>>[];
      var inlineCount = 0;
      if (preset != null) {
        for (final rs in preset.ruleSets) {
          if (rs['type'] == 'remote') {
            final tag = rs['tag']?.toString() ?? '';
            final url = rs['url']?.toString() ?? '';
            if (tag.isEmpty) continue;
            final cacheId =
                RuleSetDownloader.presetCacheId(r.presetId, tag);
            final path = await RuleSetDownloader.cachedPathForPreset(
              r.presetId,
              tag,
            );
            final mtime = await RuleSetDownloader.lastUpdated(cacheId);
            remoteRuleSets.add({
              'tag': tag,
              'url': url,
              'cached': path != null,
              'path': path,
              'mtime': mtime?.toUtc().toIso8601String(),
            });
          } else {
            inlineCount++;
          }
        }
      }
      return {
        ...base,
        'preset_id': r.presetId,
        if (r.varsValues.isNotEmpty) 'vars_values': r.varsValues,
        'effective_outbound': r.outbound,
        if (preset != null)
          'preset': {
            'label': preset.label,
            'description': preset.description,
            'default_enabled': preset.defaultEnabled,
            'inline_rule_sets': inlineCount,
            'remote_rule_sets': remoteRuleSets,
            'has_dns_rule': preset.dnsRule != null,
            'dns_servers_count': preset.dnsServers.length,
            'vars_count': preset.vars.length,
          },
        // Флаг «готово к build'у?» — все remote rule_set'ы закэшены.
        'ready': remoteRuleSets.every((rs) => rs['cached'] == true),
      };
  }
}

Future<dynamic> _lookupPreset(String presetId) async {
  if (presetId.isEmpty) return null;
  final template = await TemplateLoader.load();
  for (final p in template.selectableRules) {
    if (p.presetId == presetId) return p;
  }
  return null;
}
