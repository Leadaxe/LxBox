import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/validation.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/builder/validator.dart';

/// §312 — DNS-группы (kernel SPEC 033): эмиссионный фильтр членов +
/// validator (EmptyDnsGroup / BadDnsGroupMember / DnsGroupCycle).
void main() {
  Map<String, dynamic> inlineRef(String tag, Map<String, dynamic> body,
          {bool enabled = true}) =>
      {'enabled': enabled, 'kind': 'inline', 'tag': tag, 'body': body};

  Map<String, dynamic> groupBody(List<String> members,
          {String? mode, String? errorTtl}) =>
      {
        'type': 'group',
        'servers': members,
        'mode': ?mode,
        'error_ttl': ?errorTtl,
      };

  List<Map<String, dynamic>> emit(List<Map<String, dynamic>> refs,
          {List<String>? warnings}) =>
      resolveDnsServersBodies(
        resolved: refs,
        templateByTag: const {},
        presetServersByTag: const {},
        warningsOut: warnings,
      );

  group('§312 эмиссия — фильтр членов группы', () {
    test('здоровая группа проходит как есть', () {
      final warnings = <String>[];
      final out = emit([
        inlineRef('a', {'type': 'udp', 'server': '1.1.1.1'}),
        inlineRef('b', {'type': 'udp', 'server': '8.8.8.8'}),
        inlineRef('grp', groupBody(['a', 'b'], mode: 'fastest')),
      ], warnings: warnings);
      final grp = out.firstWhere((b) => b['tag'] == 'grp');
      expect(grp['servers'], ['a', 'b']);
      expect(grp['mode'], 'fastest');
      expect(warnings, isEmpty);
    });

    test('disabled-член выкидывается с warning (drop-семантика №3)', () {
      final warnings = <String>[];
      final out = emit([
        inlineRef('a', {'type': 'udp', 'server': '1.1.1.1'}),
        inlineRef('b', {'type': 'udp', 'server': '8.8.8.8'}, enabled: false),
        inlineRef('grp', groupBody(['a', 'b'])),
      ], warnings: warnings);
      final grp = out.firstWhere((b) => b['tag'] == 'grp');
      expect(grp['servers'], ['a'], reason: 'b выключен → дроп из эмиссии');
      expect(warnings, ["DNS group 'grp': member 'b' dropped (disabled)"]);
      // Storage-ref не мутируется — фильтр только на эмиссии (проверка от
      // регресса «кнопка мутирует молча»).
    });

    test('unknown / self / duplicate — свои причины в warning', () {
      final warnings = <String>[];
      final out = emit([
        inlineRef('a', {'type': 'udp', 'server': '1.1.1.1'}),
        inlineRef('grp', groupBody(['a', 'ghost', 'grp', 'a'])),
      ], warnings: warnings);
      final grp = out.firstWhere((b) => b['tag'] == 'grp');
      expect(grp['servers'], ['a']);
      expect(warnings, [
        "DNS group 'grp': member 'ghost' dropped (unknown)",
        "DNS group 'grp': member 'grp' dropped (itself)",
        "DNS group 'grp': member 'a' dropped (duplicate)",
      ]);
    });

    test('член ниже группы по списку — доступен (пост-проход)', () {
      final out = emit([
        inlineRef('grp', groupBody(['late'])),
        inlineRef('late', {'type': 'udp', 'server': '9.9.9.9'}),
      ]);
      expect(out.firstWhere((b) => b['tag'] == 'grp')['servers'], ['late']);
    });

    test('пустая после фильтра НЕ чинится молча — остаётся пустой', () {
      final warnings = <String>[];
      final out = emit([
        inlineRef('b', {'type': 'udp', 'server': '8.8.8.8'}, enabled: false),
        inlineRef('grp', groupBody(['b'])),
      ], warnings: warnings);
      final grp = out.firstWhere((b) => b['tag'] == 'grp');
      expect(grp['servers'], isEmpty,
          reason: 'validator пометит EmptyDnsGroup (fatal), не эмиссия');
      expect(warnings, hasLength(1));
    });

    test('не-группы фильтр не трогает', () {
      final out = emit([
        inlineRef('a', {'type': 'udp', 'server': '1.1.1.1'}),
      ]);
      expect(out.single['servers'], isNull);
    });
  });

  group('§312 validator', () {
    Map<String, dynamic> cfg(List<Map<String, dynamic>> servers) => {
          'outbounds': [
            {'tag': 'vpn-1', 'type': 'selector', 'outbounds': ['direct-out']},
            {'tag': 'direct-out', 'type': 'direct'},
          ],
          'route': {'final': 'vpn-1'},
          'dns': {'servers': servers},
        };

    test('пустая группа → EmptyDnsGroup (fatal)', () {
      final r = validateConfig(cfg([
        {'tag': 'grp', 'type': 'group', 'servers': <String>[]},
      ]));
      expect(r.issues, contains(const EmptyDnsGroup('grp')));
      expect(r.issues.single.severity, Severity.fatal);
    });

    test('член fakeip/hosts → BadDnsGroupMember', () {
      final r = validateConfig(cfg([
        {'tag': 'fake', 'type': 'fakeip'},
        {'tag': 'h', 'type': 'hosts'},
        {'tag': 'a', 'type': 'udp', 'server': '1.1.1.1'},
        {'tag': 'grp', 'type': 'group', 'servers': ['fake', 'h', 'a']},
      ]));
      expect(
          r.issues,
          containsAll([
            const BadDnsGroupMember('grp', 'fake', 'fakeip'),
            const BadDnsGroupMember('grp', 'h', 'hosts'),
          ]));
    });

    test('цикл групп → DnsGroupCycle, один на кольцо', () {
      final r = validateConfig(cfg([
        {'tag': 'g1', 'type': 'group', 'servers': ['g2']},
        {'tag': 'g2', 'type': 'group', 'servers': ['g1']},
      ]));
      final cycles = r.issues.whereType<DnsGroupCycle>().toList();
      expect(cycles, hasLength(1), reason: 'кольцо репортится один раз');
      expect(cycles.single.cycle.toSet(), {'g1', 'g2'});
    });

    test('самовключение (мимо билдера) → цикл длины 1', () {
      final r = validateConfig(cfg([
        {'tag': 'g', 'type': 'group', 'servers': ['g']},
      ]));
      expect(r.issues.whereType<DnsGroupCycle>().single.cycle, ['g']);
    });

    test('вложенная группа без кольца — валидна', () {
      final r = validateConfig(cfg([
        {'tag': 'a', 'type': 'udp', 'server': '1.1.1.1'},
        {'tag': 'inner', 'type': 'group', 'servers': ['a']},
        {'tag': 'outer', 'type': 'group', 'servers': ['inner', 'a']},
      ]));
      expect(r.issues.whereType<DnsGroupCycle>(), isEmpty);
      expect(r.issues.whereType<EmptyDnsGroup>(), isEmpty);
      expect(r.issues.whereType<BadDnsGroupMember>(), isEmpty);
    });
  });
}
