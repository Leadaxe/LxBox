import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/models/validation.dart';
import 'package:lxbox/services/builder/core_chain_capability.dart'
    show coreSupportsDnsGroupHosts;
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/builder/validator.dart';

/// §312 — DNS-группы (kernel SPEC 033): эмиссионный фильтр членов +
/// validator (EmptyDnsGroup / BadDnsGroupMember / DnsGroupCycle).
void main() {
  DnsServerRef inlineRef(String tag, Map<String, dynamic> body,
          {bool enabled = true}) =>
      DnsServerInline(enabled: enabled, tag: tag, body: body);

  Map<String, dynamic> groupBody(List<String> members,
          {String? mode, String? errorTtl}) =>
      {
        'type': 'group',
        'servers': members,
        'mode': ?mode,
        'error_ttl': ?errorTtl,
      };

  List<Map<String, dynamic>> emit(List<DnsServerRef> refs,
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

    // §319 — жалоба 4PDA: «группа работает только с direct; переключишь на
    // proxy — start падает с ошибкой». У группы нет своего транспорта:
    // запросы несут участники. Ядро принимает у `type: group` ровно
    // {servers, mode, error_ttl, win_ttl} (SPEC 033) и роняет конфиг на
    // лишнем ключе. Чистим на билде, а не только в форме: у пострадавших
    // detour уже лежит в storage.
    test('§319 detour у группы вычищается из эмиссии', () {
      final out = emit([
        inlineRef('a', {'type': 'udp', 'server': '1.1.1.1'}),
        inlineRef('grp', {
          ...groupBody(['a']),
          'detour': 'vpn-1',
        }),
      ]);
      final grp = out.firstWhere((b) => b['tag'] == 'grp');
      expect(grp.containsKey('detour'), isFalse,
          reason: 'ядро падает на unknown field у type: group');
      expect(grp['servers'], ['a'], reason: 'остальное не тронуто');
    });

    test('§319 у обычного сервера detour остаётся', () {
      final out = emit([
        inlineRef('a', {
          'type': 'udp',
          'server': '1.1.1.1',
          'detour': 'vpn-1',
        }),
      ]);
      expect(out.single['detour'], 'vpn-1');
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

  // §671 — превью JSON-вкладки редактора: тот же критерий, что у сборки.
  group('§671 превью состава группы', () {
    const six = ['a', 'b', 'c', 'd', 'e', 'f'];
    Map<String, bool> allOn() => {for (final t in six) t: true};

    test('один член выключен → 5 в превью, он в «skipped»', () {
      final r = previewDnsGroupMembers(six,
          selfTag: 'shield', emittedByTag: {...allOn(), 'c': false});
      expect(r.kept, ['a', 'b', 'd', 'e', 'f']);
      expect(r.disabled, ['c']);
    });

    test('все включены → 6, «skipped» пуст', () {
      final r = previewDnsGroupMembers(six,
          selfTag: 'shield', emittedByTag: allOn());
      expect(r.kept, six);
      expect(r.disabled, isEmpty);
    });

    test('выключенный, но реферимый правилом/пресетом — остаётся, как у '
        'сборки', () {
      final emitted = {
        ...allOn(),
        'c': dnsServerRefEmitted(enabled: false, ruleReferenced: true),
        'd': dnsServerRefEmitted(enabled: false, presetReferenced: true),
        'e': dnsServerRefEmitted(enabled: false),
      };
      final r = previewDnsGroupMembers(six,
          selfTag: 'shield', emittedByTag: emitted);
      expect(r.kept, ['a', 'b', 'c', 'd', 'f']);
      expect(r.disabled, ['e']);

      // Паритет со сборкой: c — выключен, но под правилом; e — выключен.
      final warnings = <String>[];
      final out = resolveDnsServersBodies(
        resolved: [
          for (final t in six)
            inlineRef(t, {'type': 'udp', 'server': '1.1.1.1'},
                enabled: t != 'c' && t != 'e'),
          inlineRef('shield', groupBody(six, mode: 'fastest')),
        ],
        templateByTag: const {},
        presetServersByTag: const {},
        ruleReferencedTags: const {'c'},
        warningsOut: warnings,
      );
      final grp = out.firstWhere((b) => b['tag'] == 'shield');
      expect(grp['servers'], ['a', 'b', 'c', 'd', 'f']);
      expect(warnings, contains("DNS group 'shield': member 'e' dropped "
          '(disabled)'));
    });

    // §695 правило 6 — сборка ничего не форсирует ради пикеров: выключенная
    // группа не эмитится (выбранное в пикере включено нормализацией).
    test('§695 выключенная группа и её выключенные члены не эмитятся', () {
      final out = emit([
        inlineRef('a', {'type': 'udp', 'server': '1.1.1.1'}),
        inlineRef('b', {'type': 'udp', 'server': '8.8.8.8'}, enabled: false),
        inlineRef('shield', groupBody(['a', 'b']), enabled: false),
      ]);
      expect([for (final b in out) b['tag']], ['a']);
    });

    test('незнакомый редактору член не судится, self/повтор снимаются', () {
      final r = previewDnsGroupMembers(['a', 'x', 'a', 'shield'],
          selfTag: 'shield', emittedByTag: {'a': true});
      expect(r.kept, ['a', 'x']);
      expect(r.disabled, isEmpty);
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

  // §384 — тот же запрет ядра, но для resolver-ссылок: ядро отвечает
  // `initialize DNS server: default server cannot be fakeip` (device-verified).
  group('§384 resolver type gate', () {
    Map<String, dynamic> cfg({
      String? dnsFinal,
      String? resolver,
    }) => {
          'outbounds': [
            {'tag': 'vpn-1', 'type': 'selector', 'outbounds': ['direct-out']},
            {'tag': 'direct-out', 'type': 'direct'},
          ],
          'route': {
            'final': 'vpn-1',
            'default_domain_resolver': ?resolver,
          },
          'dns': {
            'final': ?dnsFinal,
            'servers': [
              {'tag': 'fakeip', 'type': 'fakeip'},
              {'tag': 'h', 'type': 'hosts'},
              {'tag': 'a', 'type': 'udp', 'server': '1.1.1.1'},
            ],
          },
        };

    test('dns.final = fakeip → fatal', () {
      final r = validateConfig(cfg(dnsFinal: 'fakeip'));
      expect(
          r.issues,
          contains(
              const BadResolverServerType('dns.final', 'fakeip', 'fakeip')));
      expect(r.issues.first.severity, Severity.fatal);
    });

    test('default_domain_resolver = hosts → fatal', () {
      final r = validateConfig(cfg(resolver: 'h'));
      expect(
          r.issues,
          contains(const BadResolverServerType(
              'route.default_domain_resolver', 'h', 'hosts')));
    });

    test('обычный сервер под обеими ссылками — чисто', () {
      final r = validateConfig(cfg(dnsFinal: 'a', resolver: 'a'));
      expect(r.issues.whereType<BadResolverServerType>(), isEmpty);
    });

    test('пустые/отсутствующие ссылки не репортятся', () {
      final r = validateConfig(cfg(dnsFinal: '', resolver: null));
      expect(r.issues.whereType<BadResolverServerType>(), isEmpty);
    });

    test('dangling-тег остаётся DanglingDnsServerRef, не тип-issue', () {
      final r = validateConfig(cfg(dnsFinal: 'ghost'));
      expect(r.issues.whereType<BadResolverServerType>(), isEmpty);
      expect(r.issues,
          contains(const DanglingDnsServerRef('dns.final', 'ghost')));
    });
  });

  // §695 правило 5 — на что есть ссылка, то включено.
  group('§695 нормализация ссылок', () {
    final tpl = <String, Map<String, dynamic>>{
      'safe': {
        'vars': [
          {'name': 'dom_resolver', 'type': 'dns_servers',
            'default_value': 'gdoh'},
        ],
        'server': {'type': 'tls', 'tag': 'safe', 'server': 'x.example',
          'domain_resolver': '@dom_resolver'},
      },
    };

    test('выключенная группа под пикерами и её члены включаются', () {
      final r = normalizeReferencedDnsServers([
        inlineRef('a', {'type': 'udp', 'server': '1.1.1.1'}, enabled: false),
        inlineRef('b', {'type': 'udp', 'server': '8.8.8.8'}, enabled: false),
        inlineRef('free', {'type': 'udp', 'server': '9.9.9.9'},
            enabled: false),
        inlineRef('shield', groupBody(['a', 'b']), enabled: false),
      ], templateByTag: const {}, dnsFinal: 'shield',
          defaultResolver: 'shield');
      expect({for (final s in r.list) s.tag: s.enabled},
          {'a': true, 'b': true, 'free': false, 'shield': true});
      expect(r.enabled['shield'], ['final', 'default_domain_resolver']);
      expect(r.enabled['a'], ['group:shield']);
      expect(r.enabled.containsKey('free'), isFalse);
    });

    test('domain_resolver шаблона (дефолт var) и правило держат; сервер '
        'пресета — нет (его выключатель хранится)',
        () {
      final r = normalizeReferencedDnsServers([
        const DnsServerTemplate(enabled: false, tag: 'safe'),
        inlineRef('gdoh', {'type': 'https', 'server': '8.8.8.8'},
            enabled: false),
        inlineRef('p:x', {'type': 'udp', 'server': '1.1.1.1'},
            enabled: false),
        inlineRef('r', {'type': 'udp', 'server': '1.0.0.1'}, enabled: false),
      ], templateByTag: tpl, presetServersByTag: const {
        'p:x': {'type': 'udp', 'server': '1.1.1.1'},
      }, ruleReferencedTags: const {'r'});
      expect({for (final s in r.list) s.tag: s.enabled},
          {'safe': false, 'gdoh': true, 'p:x': false, 'r': true});
      expect(r.enabled['gdoh'], ['server:safe']);
    });

    test('консистентный список не меняется', () {
      final refs = [
        inlineRef('a', {'type': 'udp', 'server': '1.1.1.1'}),
        inlineRef('free', {'type': 'udp', 'server': '9.9.9.9'},
            enabled: false),
      ];
      final r = normalizeReferencedDnsServers(refs,
          templateByTag: const {}, dnsFinal: 'a', defaultResolver: 'gone');
      expect(r.list, refs);
      expect(r.enabled, isEmpty);
    });

    test('§699 сервер из hosts группы держит: включается, used_by group',
        () {
      final r = normalizeReferencedDnsServers([
        inlineRef('a', {'type': 'udp', 'server': '1.1.1.1'}),
        inlineRef('h', {'type': 'hosts', 'predefined': <String, dynamic>{}},
            enabled: false),
        inlineRef('shield', {
          ...groupBody(['a']),
          'hosts': ['h'],
        }),
      ], templateByTag: const {});
      expect(r.list.firstWhere((s) => s.tag == 'h').enabled, isTrue);
      expect(r.enabled['h'], ['group:shield']);
    });
  });

  group('§699 ключ hosts группы — сборка', () {
    Map<String, dynamic> hostsBody() => {
          'type': 'hosts',
          'predefined': {
            'wg.home': ['203.0.113.10', '2001:db8::10'],
          },
        };

    List<Map<String, dynamic>> emitWith(List<DnsServerRef> refs,
            {List<String>? warnings, String coreVersion = ''}) =>
        resolveDnsServersBodies(
          resolved: refs,
          templateByTag: const {},
          presetServersByTag: const {},
          warningsOut: warnings,
          coreVersion: coreVersion,
        );

    test('чистка: выключен, не найден, не hosts, дубль, сама группа, член',
        () {
      final warnings = <String>[];
      final out = emitWith([
        inlineRef('a', {'type': 'udp', 'server': '1.1.1.1'}),
        inlineRef('b', {'type': 'udp', 'server': '8.8.8.8'}),
        inlineRef('h1', hostsBody()),
        inlineRef('h2', hostsBody()),
        inlineRef('off', hostsBody(), enabled: false),
        inlineRef('grp', {
          ...groupBody(['a', 'h2']),
          'hosts': ['off', 'missing', 'b', 'h1', 'h1', 'grp', 'h2'],
        }),
      ], warnings: warnings);
      final grp = out.firstWhere((b) => b['tag'] == 'grp');
      expect(grp['hosts'], ['h1']);
      expect(
          warnings,
          containsAll([
            "DNS group 'grp': hosts 'off' dropped (disabled)",
            "DNS group 'grp': hosts 'missing' dropped (unknown)",
            "DNS group 'grp': hosts 'b' dropped (not hosts)",
            "DNS group 'grp': hosts 'h1' dropped (duplicate)",
            "DNS group 'grp': hosts 'grp' dropped (itself)",
            "DNS group 'grp': hosts 'h2' dropped (also a member)",
          ]));
    });

    test('всё выпало — ключ снят; строка (Listable) пишется списком', () {
      final out = emitWith([
        inlineRef('a', {'type': 'udp', 'server': '1.1.1.1'}),
        inlineRef('h1', hostsBody()),
        inlineRef('g1', {
          ...groupBody(['a']),
          'hosts': ['ghost'],
        }),
        inlineRef('g2', {
          ...groupBody(['a']),
          'hosts': 'h1',
        }),
        inlineRef('g3', {
          ...groupBody(['a']),
          'hosts': <String>[],
        }),
      ]);
      Map<String, dynamic> byTag(String t) =>
          out.firstWhere((b) => b['tag'] == t);
      expect(byTag('g1').containsKey('hosts'), isFalse);
      expect(byTag('g2')['hosts'], ['h1']);
      expect(byTag('g3').containsKey('hosts'), isFalse);
    });

    test('гейт ядра: lx.25 — ключ снят с warning; lx.26 и неизвестная — есть',
        () {
      List<DnsServerRef> refs() => [
            inlineRef('a', {'type': 'udp', 'server': '1.1.1.1'}),
            inlineRef('h1', hostsBody()),
            inlineRef('grp', {
              ...groupBody(['a']),
              'hosts': ['h1'],
            }),
          ];
      Map<String, dynamic> grpOf(List<Map<String, dynamic>> out) =>
          out.firstWhere((b) => b['tag'] == 'grp');

      final old = <String>[];
      final outOld =
          emitWith(refs(), warnings: old, coreVersion: '1.14.4-lx.25');
      expect(grpOf(outOld).containsKey('hosts'), isFalse);
      expect(old, [
        'DNS group "grp": hosts need core 1.14.4-lx.26 or newer',
      ]);

      for (final v in ['1.14.4-lx.26', 'v1.14.5-lx.1-rc.2', '', 'garbage']) {
        final w = <String>[];
        final out = emitWith(refs(), warnings: w, coreVersion: v);
        expect(grpOf(out)['hosts'], ['h1'], reason: v);
        expect(w, isEmpty, reason: v);
      }
      expect(coreSupportsDnsGroupHosts('1.14.4-lx.25'), isFalse);
      expect(coreSupportsDnsGroupHosts('1.14.4-lx.26'), isTrue);
    });

    test('detour у сервера hosts снимается, сервер не выпадает', () {
      final out = resolveDnsServersBodies(
        resolved: [
          inlineRef('h1', {...hostsBody(), 'detour': 'vpn-gone'}),
        ],
        templateByTag: const {},
        presetServersByTag: const {},
        knownOutboundTags: const {'direct-out'},
      );
      expect(out.single.containsKey('detour'), isFalse);
    });
  });

  group('§699 validator — BadDnsGroupHosts', () {
    Map<String, dynamic> cfg(List<Map<String, dynamic>> servers) => {
          'outbounds': [
            {'tag': 'vpn-1', 'type': 'selector', 'outbounds': ['direct-out']},
            {'tag': 'direct-out', 'type': 'direct'},
          ],
          'route': {'final': 'vpn-1'},
          'dns': {'servers': servers},
        };

    test('правила ядра SPEC 143 для ключа hosts', () {
      final r = validateConfig(cfg([
        {'tag': 'a', 'type': 'udp', 'server': '1.1.1.1'},
        {'tag': 'h', 'type': 'hosts'},
        {
          'tag': 'grp',
          'type': 'group',
          'servers': ['a'],
          'hosts': ['grp', 'a', 'h', 'h', 'missing', 'fake'],
        },
        {'tag': 'fake', 'type': 'fakeip'},
      ]));
      final issues = r.issues.whereType<BadDnsGroupHosts>().toList();
      expect(issues, [
        const BadDnsGroupHosts('grp', 'grp', DnsGroupHostsProblem.itself),
        const BadDnsGroupHosts('grp', 'a', DnsGroupHostsProblem.alsoMember),
        const BadDnsGroupHosts('grp', 'h', DnsGroupHostsProblem.duplicate),
        const BadDnsGroupHosts('grp', 'missing', DnsGroupHostsProblem.notFound),
        const BadDnsGroupHosts(
            'grp', 'fake', DnsGroupHostsProblem.notHosts, 'fakeip'),
      ]);
      expect(issues.every((i) => i.severity == Severity.fatal), isTrue);
    });

    test('здоровый ключ (список и строка) — без замечаний', () {
      for (final hosts in [
        ['h'],
        'h',
      ]) {
        final r = validateConfig(cfg([
          {'tag': 'a', 'type': 'udp', 'server': '1.1.1.1'},
          {'tag': 'h', 'type': 'hosts'},
          {'tag': 'grp', 'type': 'group', 'servers': ['a'], 'hosts': hosts},
        ]));
        expect(r.issues.whereType<BadDnsGroupHosts>(), isEmpty);
        expect(r.issues.whereType<BadDnsGroupMember>(), isEmpty);
      }
    });
  });
}
