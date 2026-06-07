import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/screens/home/subscription_lookup.dart';

/// §077 — Unit tests для pure helper'а `subscriptionsOfTag`.
/// Покрывают: prefix reconstruction, collision-suffix (digit-only),
/// ambiguity-aware multi-match, UserServer empty Set, disabled subs skip.

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
  required List<String> nodes,
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
  required List<String> nodes,
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
  group('subscriptionsOfTag — prefix reconstruction', () {
    test('non-empty prefix: display-tag matches → returns {entry.id}', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺 RU', nodes: ['M1'])];
      expect(subscriptionsOfTag('🇷🇺 RU M1', entries), {'s1'});
    });

    test('empty prefix: base == n.tag (regression check для §077 default case)', () {
      final entries = [_sub(id: 's1', tagPrefix: '', nodes: ['M1'])];
      expect(subscriptionsOfTag('M1', entries), {'s1'});
    });

    test('non-matching tag → empty Set', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺', nodes: ['M1'])];
      expect(subscriptionsOfTag('Other', entries), isEmpty);
    });

    test('prefix без последующего пробела — НЕ матчит (sanity check формата _withPrefix)', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺', nodes: ['M1'])];
      // _withPrefix формирует "RU M1" (space-separated), не "RUM1".
      expect(subscriptionsOfTag('🇷🇺M1', entries), isEmpty);
    });
  });

  group('subscriptionsOfTag — collision-suffix', () {
    test('"base-1" suffix матчит (одна цифра)', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺', nodes: ['M1'])];
      expect(subscriptionsOfTag('🇷🇺 M1-1', entries), {'s1'});
    });

    test('"base-23" suffix матчит (несколько цифр)', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺', nodes: ['M1'])];
      expect(subscriptionsOfTag('🇷🇺 M1-23', entries), {'s1'});
    });

    test('"base-X" (non-digit suffix) НЕ матчит', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺', nodes: ['M1'])];
      expect(subscriptionsOfTag('🇷🇺 M1-X', entries), isEmpty);
    });

    test('"base-1a" (mixed) НЕ матчит', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺', nodes: ['M1'])];
      expect(subscriptionsOfTag('🇷🇺 M1-1a', entries), isEmpty);
    });

    test('"base-" (empty digits part) НЕ матчит', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺', nodes: ['M1'])];
      expect(subscriptionsOfTag('🇷🇺 M1-', entries), isEmpty);
    });

    test('space instead of "-" НЕ матчит', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺', nodes: ['M1'])];
      expect(subscriptionsOfTag('🇷🇺 M1 1', entries), isEmpty);
    });
  });

  group('subscriptionsOfTag — ambiguity-aware (multi-match)', () {
    test('две подписки одного prefix+name → tag мэтчит ОБЕ', () {
      // Builder реально дал бы "🇷🇺 M1" одной и "🇷🇺 M1-1" второй,
      // но lookup не знает кто получил suffix → возвращает обе.
      final entries = [
        _sub(id: 'A', tagPrefix: '🇷🇺', nodes: ['M1']),
        _sub(id: 'B', tagPrefix: '🇷🇺', nodes: ['M1']),
      ];
      expect(subscriptionsOfTag('🇷🇺 M1', entries), {'A', 'B'});
      expect(subscriptionsOfTag('🇷🇺 M1-1', entries), {'A', 'B'});
    });

    test('пересечение через разные форматы prefix+name → тоже multi-match', () {
      // Sub A: prefix='' node='🇷🇺 M1' → base='🇷🇺 M1'
      // Sub B: prefix='🇷🇺' node='M1' → base='🇷🇺 M1'
      // Одинаковая base строка.
      final entries = [
        _sub(id: 'A', tagPrefix: '', nodes: ['🇷🇺 M1']),
        _sub(id: 'B', tagPrefix: '🇷🇺', nodes: ['M1']),
      ];
      expect(subscriptionsOfTag('🇷🇺 M1', entries), {'A', 'B'});
      expect(subscriptionsOfTag('🇷🇺 M1-1', entries), {'A', 'B'});
    });

    test('коллизия не между всеми подписками — узкий мэтч', () {
      final entries = [
        _sub(id: 'A', tagPrefix: '🇷🇺', nodes: ['M1']),
        _sub(id: 'B', tagPrefix: '🇩🇪', nodes: ['M1']),
      ];
      expect(subscriptionsOfTag('🇷🇺 M1', entries), {'A'});
      expect(subscriptionsOfTag('🇩🇪 M1', entries), {'B'});
    });
  });

  group('subscriptionsOfTag — UserServer / disabled', () {
    test('UserServer (не SubscriptionServers) → empty Set', () {
      final entries = [_user(id: 'u1', nodes: ['M1'])];
      expect(subscriptionsOfTag('M1', entries), isEmpty);
    });

    test('mix: SubscriptionServers + UserServer', () {
      final entries = [
        _sub(id: 's1', tagPrefix: '🇷🇺', nodes: ['M1']),
        _user(id: 'u1', nodes: ['Custom1']),
      ];
      expect(subscriptionsOfTag('🇷🇺 M1', entries), {'s1'});
      expect(subscriptionsOfTag('Custom1', entries), isEmpty);
    });

    test('disabled SubscriptionServers пропущена (§077 audit finding #15)', () {
      // Disabled subs не эмитят node-ы через ServerListBuild.build,
      // поэтому в state.nodes их display-tag-ов нет. Lookup тоже не
      // должен их рассматривать — иначе false-positive в chip filter.
      final entries = [
        _sub(id: 'A', tagPrefix: '🇷🇺', nodes: ['M1'], enabled: true),
        _sub(id: 'B', tagPrefix: '🇷🇺', nodes: ['M1'], enabled: false),
      ];
      expect(subscriptionsOfTag('🇷🇺 M1', entries), {'A'});
      expect(subscriptionsOfTag('🇷🇺 M1-1', entries), {'A'});
    });
  });

  group('subscriptionsOfTag — empty input', () {
    test('пустой список entries → empty Set', () {
      expect(subscriptionsOfTag('M1', []), isEmpty);
    });

    test('подписка с empty nodes → empty Set', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺', nodes: [])];
      expect(subscriptionsOfTag('🇷🇺 M1', entries), isEmpty);
    });
  });
}
