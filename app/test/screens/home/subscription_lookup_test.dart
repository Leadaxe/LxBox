import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/screens/home/subscription_lookup.dart';

/// §091 — Unit tests для prefix-based `subscriptionsOfTag`.
/// Принадлежность ноды подписке = `tag.startsWith('$prefix ')`; пустой
/// префикс не участвует; suffix после префикса игнорируется (никакого
/// reverse-парсинга / collision-эвристики — класс багов §077/§079/§080 ушёл).

NodeSpec _node(String tag) => VlessSpec(
      id: 'id-$tag',
      tag: tag,
      label: tag,
      server: '1.2.3.4',
      port: 443,
      rawUri: 'vless://stub',
      uuid: '00000000-0000-0000-0000-000000000000',
    );

SubscriptionEntry _sub({
  required String id,
  String name = '',
  String tagPrefix = '',
  bool enabled = true,
  List<String> nodes = const ['M1'],
}) {
  final list = SubscriptionServers(
    id: id,
    name: name.isEmpty ? id : name,
    enabled: enabled,
    tagPrefix: tagPrefix,
    detourPolicy: DetourPolicy.defaults,
    url: 'https://example.com/$id',
    nodes: nodes.map(_node).toList(),
  );
  return SubscriptionEntry(list: list);
}

SubscriptionEntry _user({
  required String id,
  String tagPrefix = '',
  List<String> nodes = const ['M1'],
}) {
  final list = UserServer(
    id: id,
    name: id,
    enabled: true,
    tagPrefix: tagPrefix,
    detourPolicy: DetourPolicy.defaults,
    rawBody: '',
    origin: UserSource.manual,
    createdAt: DateTime.utc(2025, 1, 1),
    nodes: nodes.map(_node).toList(),
  );
  return SubscriptionEntry(list: list);
}

void main() {
  group('prefix match', () {
    test('tag начинается с "\$prefix " → {entry.id}', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺 RU')];
      expect(subscriptionsOfTag('🇷🇺 RU M1', entries), {'s1'});
    });

    test('пустой префикс → НЕ участвует (нет поиска), даже для своей ноды', () {
      final entries = [_sub(id: 's1', tagPrefix: '', nodes: ['M1'])];
      expect(subscriptionsOfTag('M1', entries), isEmpty);
    });

    test('tag не начинается с префикса → empty', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺')];
      expect(subscriptionsOfTag('Other', entries), isEmpty);
    });

    test('префикс без последующего пробела → НЕ матчит', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺')];
      expect(subscriptionsOfTag('🇷🇺M1', entries), isEmpty);
    });
  });

  group('suffix-agnostic (§091 — больше нет collision-эвристики)', () {
    final entries = [_sub(id: 's1', tagPrefix: '🇷🇺')];

    test('любой суффикс после "\$prefix " матчит', () {
      // Раньше (reverse-map) различал digit-only collision-suffix; теперь
      // принадлежность определяется ровно префиксом.
      expect(subscriptionsOfTag('🇷🇺 M1', entries), {'s1'});
      expect(subscriptionsOfTag('🇷🇺 M1-1', entries), {'s1'}); // collision
      expect(subscriptionsOfTag('🇷🇺 M1-X', entries), {'s1'}); // non-digit
      expect(subscriptionsOfTag('🇷🇺 M1 extra', entries), {'s1'});
      expect(subscriptionsOfTag('🇷🇺 что угодно', entries), {'s1'});
    });
  });

  group('ambiguity / разные префиксы', () {
    test('две подписки с одинаковым префиксом → tag матчит ОБЕ', () {
      final entries = [
        _sub(id: 'A', tagPrefix: '🇷🇺'),
        _sub(id: 'B', tagPrefix: '🇷🇺'),
      ];
      expect(subscriptionsOfTag('🇷🇺 M1', entries), {'A', 'B'});
    });

    test('разные префиксы → узкий мэтч', () {
      final entries = [
        _sub(id: 'A', tagPrefix: '🇷🇺'),
        _sub(id: 'B', tagPrefix: '🇩🇪'),
      ];
      expect(subscriptionsOfTag('🇷🇺 M1', entries), {'A'});
      expect(subscriptionsOfTag('🇩🇪 M1', entries), {'B'});
    });

    test('префикс A — префикс другого B (prefix-of-prefix) разводится пробелом', () {
      // 'RU' и 'RU2': tag 'RU2 M1' начинается с 'RU2 ', но НЕ с 'RU '
      // (после 'RU' идёт '2', не пробел) → только B.
      final entries = [
        _sub(id: 'A', tagPrefix: 'RU'),
        _sub(id: 'B', tagPrefix: 'RU2'),
      ];
      expect(subscriptionsOfTag('RU2 M1', entries), {'B'});
      expect(subscriptionsOfTag('RU M1', entries), {'A'});
    });
  });

  group('UserServer / disabled / empty', () {
    test('UserServer (не SubscriptionServers) → empty (→ custom)', () {
      final entries = [_user(id: 'u1', tagPrefix: 'X')];
      expect(subscriptionsOfTag('X M1', entries), isEmpty);
    });

    test('disabled SubscriptionServers пропущена', () {
      final entries = [
        _sub(id: 'A', tagPrefix: '🇷🇺', enabled: true),
        _sub(id: 'B', tagPrefix: '🇷🇺', enabled: false),
      ];
      expect(subscriptionsOfTag('🇷🇺 M1', entries), {'A'});
    });

    test('пустой список entries → empty', () {
      expect(subscriptionsOfTag('M1', const []), isEmpty);
    });

    test('mix: prefixed sub + UserServer', () {
      final entries = [
        _sub(id: 's1', tagPrefix: '🇷🇺'),
        _user(id: 'u1', nodes: ['Custom1']),
      ];
      expect(subscriptionsOfTag('🇷🇺 M1', entries), {'s1'});
      expect(subscriptionsOfTag('Custom1', entries), isEmpty);
    });
  });
}
