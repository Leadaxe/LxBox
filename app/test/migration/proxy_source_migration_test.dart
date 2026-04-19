import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/migration/proxy_source_migration.dart';

void main() {
  group('migrateProxySources', () {
    test('URL → SubscriptionServers with meta + policy', () {
      final out = migrateProxySources([
        {
          'id': 'sub-1',
          'source': 'https://example.com/sub',
          'name': 'My Sub',
          'enabled': true,
          'tag_prefix': 'abc',
          'upload_bytes': 100,
          'download_bytes': 200,
          'total_bytes': 1000,
          'expire_timestamp': 1735689600,
          'last_updated': '2026-04-18T10:00:00.000Z',
          'update_interval_hours': 12,
          'last_node_count': 42,
          'override_detour': 'jump-1',
          'register_detour_in_auto': true,
        }
      ]);

      expect(out, hasLength(1));
      final s = out.single as SubscriptionServers;
      expect(s.url, 'https://example.com/sub');
      expect(s.name, 'My Sub');
      expect(s.tagPrefix, 'abc');
      expect(s.updateIntervalHours, 12);
      expect(s.lastNodeCount, 42);
      expect(s.meta?.uploadBytes, 100);
      expect(s.meta?.totalBytes, 1000);
      expect(s.detourPolicy.overrideDetour, 'jump-1');
      expect(s.detourPolicy.registerDetourInAuto, true);
    });

    test('inline connections → UserServers.paste with rawBody', () {
      final out = migrateProxySources([
        {
          'id': 'user-1',
          'source': '',
          'connections': ['vless://a@h:443#x', 'trojan://p@h:443#y'],
          'name': 'Pasted',
        }
      ]);
      final u = out.single as UserServers;
      expect(u.origin, UserSource.paste);
      expect(u.rawBody, contains('vless://'));
      expect(u.rawBody, contains('trojan://'));
    });

    test('preserves detour defaults when absent', () {
      final out = migrateProxySources([
        {'source': 'https://x', 'name': 'n'}
      ]);
      final s = out.single as SubscriptionServers;
      expect(s.detourPolicy.useDetourServers, true);
      expect(s.detourPolicy.registerDetourServers, true);
      expect(s.detourPolicy.registerDetourInAuto, false);
    });

    test('JSON round-trip after migration', () {
      final migrated = migrateProxySources([
        {'source': 'https://x', 'id': 'k', 'name': 'n'}
      ]);
      final j = migrated.single.toJson();
      final back = ServerList.fromJson(j);
      expect(back, isA<SubscriptionServers>());
      expect((back as SubscriptionServers).url, 'https://x');
      expect(back.id, 'k');
    });
  });
}
