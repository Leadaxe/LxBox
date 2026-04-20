import '../../../models/custom_rule.dart';
import '../../rule_set_downloader.dart';

/// Одно пользовательское правило (§030 Custom rules) для `/state/rules`.
/// Асинхронный — читает mtime/наличие `.srs` с диска для srs-правил.
Future<Map<String, Object?>> serializeCustomRule(CustomRule r) async {
  final cachedPath = await RuleSetDownloader.cachedPath(r.id);
  final mtime = await RuleSetDownloader.lastUpdated(r.id);
  return {
    'id': r.id,
    'name': r.name,
    'enabled': r.enabled,
    'kind': r.kind.name,
    'domains': r.domains,
    'domain_suffixes': r.domainSuffixes,
    'domain_keywords': r.domainKeywords,
    'ip_cidrs': r.ipCidrs,
    'ports': r.ports,
    'port_ranges': r.portRanges,
    'packages': r.packages,
    'protocols': r.protocols,
    'ip_is_private': r.ipIsPrivate,
    'srs_url': r.srsUrl,
    'target': r.target,
    'srs_cached': cachedPath != null,
    'srs_path': cachedPath,
    'srs_mtime': mtime?.toUtc().toIso8601String(),
  };
}
