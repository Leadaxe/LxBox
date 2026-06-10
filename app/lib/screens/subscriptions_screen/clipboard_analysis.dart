import 'dart:convert';

import '../../services/subscription/input_helpers.dart';

/// Result of analyzing clipboard text before adding it as a server/sub.
class ClipboardAnalysis {
  ClipboardAnalysis({
    required this.type,
    required this.title,
    required this.subtitle,
  });
  final String type;
  final String title;
  final String subtitle;
}

ClipboardAnalysis analyzeClipboard(String text) {
  if (isSubscriptionUrl(text)) {
    final uri = Uri.tryParse(text);
    return ClipboardAnalysis(
      type: 'subscription',
      title: 'Subscription URL',
      subtitle: uri?.host ?? text,
    );
  }
  if (isWireGuardConfig(text)) {
    final lines = text.split('\n');
    final endpoint = lines
        .where((l) => l.trim().toLowerCase().startsWith('endpoint'))
        .map((l) => l.split('=').last.trim())
        .firstOrNull ?? '';
    return ClipboardAnalysis(
      type: 'wireguard_config',
      title: 'WireGuard config',
      subtitle: endpoint.isNotEmpty ? endpoint : '[Interface] + [Peer]',
    );
  }
  if (isDirectLink(text)) {
    final uri = Uri.tryParse(text);
    final scheme = text.split('://').first.toUpperCase();
    final label = uri?.fragment ?? '';
    final server = uri != null ? '${uri.host}:${uri.port}' : '';
    return ClipboardAnalysis(
      type: 'direct',
      title: '$scheme link',
      subtitle: '${label.isNotEmpty ? "$label\n" : ""}$server',
    );
  }
  // JSON outbound
  if ((text.startsWith('{') || text.startsWith('[')) && text.contains('"type"')) {
    try {
      final parsed = jsonDecode(text);
      if (parsed is Map<String, dynamic>) {
        final type = parsed['type'] ?? 'unknown';
        final tag = parsed['tag'] ?? '';
        return ClipboardAnalysis(
          type: 'json_outbound',
          title: 'Outbound JSON',
          subtitle: '$type${tag.toString().isNotEmpty ? " — $tag" : ""}',
        );
      }
      if (parsed is List) {
        final types = parsed
            .whereType<Map<String, dynamic>>()
            .map((o) => o['type']?.toString() ?? '?')
            .toList();
        return ClipboardAnalysis(
          type: 'json_outbound',
          title: 'Outbound JSON',
          subtitle: '${parsed.length} outbounds (${types.join(" + ")})',
        );
      }
    } catch (_) {}
  }
  return ClipboardAnalysis(type: 'unknown', title: 'Unknown', subtitle: '');
}
