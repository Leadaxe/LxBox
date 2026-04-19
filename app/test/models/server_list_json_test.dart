import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/subscription_meta.dart';

void main() {
  group('ServerList JSON round-trip', () {
    test('SubscriptionServers → JSON → SubscriptionServers', () {
      final original = SubscriptionServers(
        id: 'sub-1',
        name: 'My Sub',
        enabled: true,
        tagPrefix: '🌐',
        detourPolicy: const DetourPolicy(overrideDetour: 'jump-1'),
        url: 'https://example.com/sub?token=test',
        meta: const SubscriptionMeta(
          uploadBytes: 100,
          downloadBytes: 2000,
          totalBytes: 107374182400,
          profileTitle: 'Test Profile',
        ),
        lastUpdated: DateTime.utc(2026, 4, 18, 10, 0),
        updateIntervalHours: 12,
        lastNodeCount: 42,
      );

      final roundtripped =
          ServerList.fromJson(original.toJson()) as SubscriptionServers;

      expect(roundtripped.id, original.id);
      expect(roundtripped.name, original.name);
      expect(roundtripped.tagPrefix, original.tagPrefix);
      expect(roundtripped.detourPolicy, original.detourPolicy);
      expect(roundtripped.url, original.url);
      expect(roundtripped.meta, original.meta);
      expect(roundtripped.lastUpdated, original.lastUpdated);
      expect(roundtripped.updateIntervalHours, 12);
      expect(roundtripped.lastNodeCount, 42);
    });

    test('UserServer → JSON → UserServer', () {
      final original = UserServer(
        id: 'user-1',
        name: 'Pasted',
        enabled: true,
        tagPrefix: '🔗',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.utc(2026, 4, 18),
        rawBody: 'vless://...',
      );

      final j = original.toJson();
      expect(j['type'], 'user');

      final rt = ServerList.fromJson(j) as UserServer;
      expect(rt.origin, UserSource.paste);
      expect(rt.createdAt, original.createdAt);
      expect(rt.rawBody, original.rawBody);
    });

    test('DetourPolicy defaults round-trip', () {
      final j = DetourPolicy.defaults.toJson();
      expect(DetourPolicy.fromJson(j), DetourPolicy.defaults);
    });

    test('fromJson throws on unknown type', () {
      expect(
        () => ServerList.fromJson({'type': 'invalid', 'id': 'x'}),
        throwsFormatException,
      );
    });

    test('copyWith preserves id', () {
      final s = SubscriptionServers(
        id: 'keep',
        name: 'A',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://x',
      );
      final updated = s.copyWith(name: 'B', lastNodeCount: 5);
      expect(updated.id, 'keep');
      expect(updated.name, 'B');
      expect(updated.lastNodeCount, 5);
      expect(updated.url, 'https://x');
    });
  });
}
