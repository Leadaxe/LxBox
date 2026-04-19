import '../../models/server_list.dart';
import '../../models/subscription_meta.dart';
import '../parser/uri_utils.dart' show newUuidV4;

/// Одноразовая миграция `ProxySource` (v1) → `ServerList` (v2).
///
/// Правило: `source` non-empty URL → `SubscriptionServers`; иначе
/// (inline-вставка через `connections`) → `UserServers` с `origin=paste`.
/// Nodes **не переносятся** — они пересчитаются при первом рефреше/парсе.
///
/// Вход: `List<Map<String, dynamic>>` из shared_preferences ключа
/// `proxy_sources`. Выход: `List<ServerList>` готовый к persist через
/// `ServerList.toJson` + сериализацию обратно.
List<ServerList> migrateProxySources(List<Map<String, dynamic>> rawSources) {
  final out = <ServerList>[];
  for (final s in rawSources) {
    final id = (s['id'] as String?) ?? newUuidV4();
    final name = (s['name'] as String?) ?? '';
    final enabled = (s['enabled'] as bool?) ?? true;
    final tagPrefix = (s['tag_prefix'] as String?) ?? '';
    final policy = DetourPolicy(
      registerDetourServers:
          (s['register_detour_servers'] as bool?) ?? true,
      registerDetourInAuto:
          (s['register_detour_in_auto'] as bool?) ?? false,
      useDetourServers: (s['use_detour_servers'] as bool?) ?? true,
      overrideDetour: (s['override_detour'] as String?) ?? '',
    );

    final source = (s['source'] as String?) ?? '';
    final connections = (s['connections'] as List?)?.cast<String>() ?? const [];

    if (source.isNotEmpty &&
        (source.startsWith('http://') || source.startsWith('https://'))) {
      final upload = (s['upload_bytes'] as num?)?.toInt() ?? 0;
      final download = (s['download_bytes'] as num?)?.toInt() ?? 0;
      final total = (s['total_bytes'] as num?)?.toInt() ?? 0;
      final expire = (s['expire_timestamp'] as num?)?.toInt();
      final meta = (upload == 0 &&
              download == 0 &&
              total == 0 &&
              expire == null &&
              (s['support_url'] == null) &&
              (s['web_page_url'] == null))
          ? null
          : SubscriptionMeta(
              uploadBytes: upload,
              downloadBytes: download,
              totalBytes: total,
              expireTimestamp: expire,
              supportUrl: s['support_url'] as String?,
              webPageUrl: s['web_page_url'] as String?,
            );

      out.add(SubscriptionServers(
        id: id,
        name: name,
        enabled: enabled,
        tagPrefix: tagPrefix,
        detourPolicy: policy,
        url: source,
        meta: meta,
        lastUpdated: DateTime.tryParse((s['last_updated'] as String?) ?? ''),
        updateIntervalHours:
            (s['update_interval_hours'] as num?)?.toInt() ?? 24,
        lastNodeCount: (s['last_node_count'] as num?)?.toInt() ?? 0,
      ));
    } else {
      out.add(UserServers(
        id: id,
        name: name,
        enabled: enabled,
        tagPrefix: tagPrefix,
        detourPolicy: policy,
        origin: UserSource.paste,
        createdAt: DateTime.tryParse((s['last_updated'] as String?) ?? '') ??
            DateTime.now(),
        rawBody: connections.join('\n'),
      ));
    }
  }
  return out;
}
