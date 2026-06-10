/// §033: pure helper — formats a DNS rule body into a compact one-line preview
/// for the rule tile subtitle.
String formatRulePreview(Map<String, dynamic>? body, {required String kind}) {
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
