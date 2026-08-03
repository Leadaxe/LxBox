import '../../services/parser/body_decoder.dart';
import '../../services/parser/parse_all.dart';
import '../../services/subscription/input_helpers.dart';

/// Result of analyzing clipboard text before adding it as a server/sub.
class ClipboardAnalysis {
  ClipboardAnalysis({
    required this.type,
    required this.title,
    required this.subtitle,
    this.notImported = const [],
  });
  final String type;
  final String title;
  final String subtitle;

  /// §368 §8 — секции конфига, которые мы не переносим (`route`, `dns`,
  /// `inbounds`). Только фактически присутствовавшие: в конфиге без `dns`
  /// упоминать `dns` незачем. Пусто — предупреждать не о чем.
  final List<String> notImported;
}

/// §368 — верхнеуровневые секции, которые импорт не переносит: наша модель
/// генерирует их сама из своих настроек (§6).
const _kIgnoredConfigSections = ['route', 'dns', 'inbounds'];

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
  // §110 — Amnezia vpn://: декодим сразу, чтобы показать endpoint и число
  // контейнеров. Битая ссылка → unknown (юзер увидит стандартный диалог).
  if (isAmneziaVpnLink(text)) {
    final decoded = decode(text);
    if (decoded is AmneziaConfig) {
      final endpoint = decoded.iniTexts.first
          .split('\n')
          .where((l) => l.trim().toLowerCase().startsWith('endpoint'))
          .map((l) => l.split('=').last.trim())
          .firstOrNull ?? '';
      final n = decoded.iniTexts.length;
      return ClipboardAnalysis(
        type: 'amnezia_vpn',
        title: 'Amnezia VPN config',
        subtitle: '${endpoint.isNotEmpty ? endpoint : "WG/AWG"}'
            '${n > 1 ? " × $n" : ""}',
      );
    }
    return ClipboardAnalysis(type: 'unknown', title: 'Unknown', subtitle: '');
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

  // §368 §7.2 — JSON-формы: превью читает ТОТ ЖЕ результат, что и импорт.
  // Раньше здесь была своя эвристика (`startsWith('{') && contains('"type"')`),
  // третья по счёту, и она разошлась с гейтом контроллера: превью обещало
  // «Outbound JSON» там, где импорт отказывал.
  final decoded = decode(text);
  if (decoded is JsonConfig) {
    final analysis = _analyzeJson(decoded);
    if (analysis != null) return analysis;
  }

  return ClipboardAnalysis(type: 'unknown', title: 'Unknown', subtitle: '');
}

/// §368 §7.2 — превью JSON-формы. Счётчики берём сухим прогоном парсера, а не
/// повторной эвристикой: то, что показано, и есть то, что приедет.
ClipboardAnalysis? _analyzeJson(JsonConfig j) {
  switch (j.flavor) {
    case JsonFlavor.singboxOutbound:
      final map = j.value is Map<String, dynamic>
          ? j.value as Map<String, dynamic>
          : const <String, dynamic>{};
      final type = map['type']?.toString() ?? 'unknown';
      final tag = map['tag']?.toString() ?? '';
      return ClipboardAnalysis(
        type: 'json_outbound',
        title: 'Outbound JSON',
        subtitle: '$type${tag.isNotEmpty ? " — $tag" : ""}',
      );

    case JsonFlavor.singboxArray:
      final list = j.value is List ? j.value as List : const [];
      final types = list
          .whereType<Map<String, dynamic>>()
          .map((o) => o['type']?.toString() ?? '?')
          .toList();
      return ClipboardAnalysis(
        type: 'json_outbound',
        title: 'Outbound JSON',
        subtitle: '${list.length} outbounds (${types.join(" + ")})',
      );

    case JsonFlavor.singboxConfig:
    case JsonFlavor.singboxMulti:
      final configs = j.flavor == JsonFlavor.singboxConfig
          ? [
              if (j.value is Map<String, dynamic>)
                j.value as Map<String, dynamic>,
            ]
          : (j.value is List ? j.value as List : const [])
              .whereType<Map<String, dynamic>>()
              .toList();
      final nodes = parseAll(JsonConfig(j.value, j.flavor));
      final groups = nodes.where((n) => n.isGroup).length;
      final chained = nodes.where((n) => n.chained != null).length;

      final ignored = <String>[
        for (final s in _kIgnoredConfigSections)
          if (configs.any((c) => c.containsKey(s))) s,
      ];

      return ClipboardAnalysis(
        type: 'singbox_config',
        title: 'sing-box config',
        subtitle: [
          '${nodes.length - groups} nodes',
          if (groups > 0) '$groups groups',
          if (chained > 0) '$chained chained',
        ].join(' · '),
        notImported: ignored,
      );

    case JsonFlavor.xrayArray:
      final list = j.value is List ? j.value as List : const [];
      return ClipboardAnalysis(
        type: 'json_outbound',
        title: 'Xray config',
        subtitle: '${list.length} elements',
      );

    case JsonFlavor.clashYaml:
    case JsonFlavor.unknown:
      return null;
  }
}
