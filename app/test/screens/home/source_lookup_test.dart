import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/screens/home/source_lookup.dart';

/// §091/§235 — Unit tests для prefix-based `sourcesOfTag` (бывш.
/// `subscriptionsOfTag`; §235 — источник = подписка ИЛИ папка §234).
/// Принадлежность ноды источнику = `tag.startsWith('$prefix ')`; пустой
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

SubscriptionEntry _folder({
  required String id,
  String tagPrefix = '',
  bool enabled = true,
}) {
  final list = FolderServers(
    id: id,
    name: id,
    enabled: enabled,
    tagPrefix: tagPrefix,
    detourPolicy: DetourPolicy.defaults,
    members: [
      FolderMember(raw: 'vless://u1@h1.example:443?type=ws&security=tls#M1'),
    ],
  );
  return SubscriptionEntry(list: list);
}

void main() {
  group('prefix match', () {
    test('tag начинается с "\$prefix " → {entry.id}', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺 RU')];
      expect(sourcesOfTag('🇷🇺 RU M1', entries), {'s1'});
    });

    test('пустой префикс → НЕ участвует (нет поиска), даже для своей ноды', () {
      final entries = [_sub(id: 's1', tagPrefix: '', nodes: ['M1'])];
      expect(sourcesOfTag('M1', entries), isEmpty);
    });

    test('tag не начинается с префикса → empty', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺')];
      expect(sourcesOfTag('Other', entries), isEmpty);
    });

    test('префикс без последующего пробела → НЕ матчит', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺')];
      expect(sourcesOfTag('🇷🇺M1', entries), isEmpty);
    });
  });

  group('suffix-agnostic (§091 — больше нет collision-эвристики)', () {
    final entries = [_sub(id: 's1', tagPrefix: '🇷🇺')];

    test('любой суффикс после "\$prefix " матчит', () {
      // Раньше (reverse-map) различал digit-only collision-suffix; теперь
      // принадлежность определяется ровно префиксом.
      expect(sourcesOfTag('🇷🇺 M1', entries), {'s1'});
      expect(sourcesOfTag('🇷🇺 M1-1', entries), {'s1'}); // collision
      expect(sourcesOfTag('🇷🇺 M1-X', entries), {'s1'}); // non-digit
      expect(sourcesOfTag('🇷🇺 M1 extra', entries), {'s1'});
      expect(sourcesOfTag('🇷🇺 что угодно', entries), {'s1'});
    });
  });

  group('ambiguity / разные префиксы', () {
    test('две подписки с одинаковым префиксом → tag матчит ОБЕ', () {
      final entries = [
        _sub(id: 'A', tagPrefix: '🇷🇺'),
        _sub(id: 'B', tagPrefix: '🇷🇺'),
      ];
      expect(sourcesOfTag('🇷🇺 M1', entries), {'A', 'B'});
    });

    test('разные префиксы → узкий мэтч', () {
      final entries = [
        _sub(id: 'A', tagPrefix: '🇷🇺'),
        _sub(id: 'B', tagPrefix: '🇩🇪'),
      ];
      expect(sourcesOfTag('🇷🇺 M1', entries), {'A'});
      expect(sourcesOfTag('🇩🇪 M1', entries), {'B'});
    });

    test('префикс A — префикс другого B (prefix-of-prefix) разводится пробелом', () {
      // 'RU' и 'RU2': tag 'RU2 M1' начинается с 'RU2 ', но НЕ с 'RU '
      // (после 'RU' идёт '2', не пробел) → только B.
      final entries = [
        _sub(id: 'A', tagPrefix: 'RU'),
        _sub(id: 'B', tagPrefix: 'RU2'),
      ];
      expect(sourcesOfTag('RU2 M1', entries), {'B'});
      expect(sourcesOfTag('RU M1', entries), {'A'});
    });
  });

  group('§235 — папки как источники', () {
    test('папка с префиксом участвует наравне с подпиской', () {
      final entries = [_folder(id: 'f1', tagPrefix: 'pr')];
      expect(sourcesOfTag('pr M1', entries), {'f1'});
    });

    test('папка без префикса → НЕ участвует', () {
      final entries = [_folder(id: 'f1', tagPrefix: '')];
      expect(sourcesOfTag('M1', entries), isEmpty);
    });

    test('disabled папка пропущена', () {
      final entries = [_folder(id: 'f1', tagPrefix: 'pr', enabled: false)];
      expect(sourcesOfTag('pr M1', entries), isEmpty);
    });

    test('подписка и папка с одним префиксом → tag матчит обе', () {
      final entries = [
        _sub(id: 's1', tagPrefix: 'X'),
        _folder(id: 'f1', tagPrefix: 'X'),
      ];
      expect(sourcesOfTag('X M1', entries), {'s1', 'f1'});
    });
  });

  group('UserServer / disabled / empty', () {
    test('UserServer (одиночный) → empty (→ custom)', () {
      final entries = [_user(id: 'u1', tagPrefix: 'X')];
      expect(sourcesOfTag('X M1', entries), isEmpty);
    });

    test('disabled SubscriptionServers пропущена', () {
      final entries = [
        _sub(id: 'A', tagPrefix: '🇷🇺', enabled: true),
        _sub(id: 'B', tagPrefix: '🇷🇺', enabled: false),
      ];
      expect(sourcesOfTag('🇷🇺 M1', entries), {'A'});
    });

    test('пустой список entries → empty', () {
      expect(sourcesOfTag('M1', const []), isEmpty);
    });

    test('mix: prefixed sub + UserServer', () {
      final entries = [
        _sub(id: 's1', tagPrefix: '🇷🇺'),
        _user(id: 'u1', nodes: ['Custom1']),
      ];
      expect(sourcesOfTag('🇷🇺 M1', entries), {'s1'});
      expect(sourcesOfTag('Custom1', entries), isEmpty);
    });
  });

  // §255 — ownerOfTag: суперсет sourcesOfTag для навигации к владельцу
  // culprit-ноды (ловит и UserServer без префикса, и члена папки).
  // Возвращает TagOwner(entryIndex, memberIndex?).
  group('ownerOfTag', () {
    test('prefixed subscription node → entryIndex, memberIndex null', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺', nodes: ['Node A'])];
      final o = ownerOfTag('🇷🇺 Node A', entries)!;
      expect(o.entryIndex, 0);
      expect(o.memberIndex, isNull);
    });

    test('bare UserServer node (без префикса) → entryIndex', () {
      // sourcesOfTag сюда бы вернул empty (UserServer не участвует); ownerOfTag
      // — суперсет, ловит по bare-тегу.
      final entries = [_user(id: 'u1', nodes: ['MyServer'])];
      expect(ownerOfTag('MyServer', entries)?.entryIndex, 0);
    });

    test('folder member → entryIndex + memberIndex', () {
      // Папка _folder имеет члена с raw #M1 → node.tag == 'M1' (member 0).
      final entries = [
        _sub(id: 's0', tagPrefix: 'x', nodes: ['zzz']),
        _folder(id: 'f1', tagPrefix: 'pr'),
      ];
      final o = ownerOfTag('pr M1', entries)!;
      expect(o.entryIndex, 1);
      expect(o.memberIndex, 0);
    });

    test('dedup-суффикс: culprit "…-1", bare-нода без суффикса → owner', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺', nodes: ['Node A'])];
      expect(ownerOfTag('🇷🇺 Node A-1', entries)?.entryIndex, 0);
    });

    test('bare-тег легитимно кончается на -2 → unsuffixed кандидат выигрывает',
        () {
      final entries = [_user(id: 'u1', nodes: ['WARP-2'])];
      expect(ownerOfTag('WARP-2', entries)?.entryIndex, 0);
    });

    test('нет владельца (custom-тег) → null', () {
      final entries = [_sub(id: 's1', tagPrefix: '🇷🇺', nodes: ['M1'])];
      expect(ownerOfTag('Unknown Tag', entries), isNull);
    });

    test('первый матч выигрывает при коллизии', () {
      final entries = [
        _sub(id: 'A', tagPrefix: '🇷🇺', nodes: ['M1']),
        _sub(id: 'B', tagPrefix: '🇷🇺', nodes: ['M1']),
      ];
      expect(ownerOfTag('🇷🇺 M1', entries)?.entryIndex, 0);
    });
  });
}
