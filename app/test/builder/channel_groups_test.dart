import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/channel.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §125 F1/F2/F3 — билдер собирает outbound-группы из BuildSettings.channels:
/// per-channel regex node-set, direct/auto-членство из галок, auto-двойник,
/// default-regex. Проверяем через настоящий buildConfig (channels !== пусто →
/// идёт по новому пути, минуя template-fallback).
void main() {
  // template без preset-групп: каналы целиком из settings.channels.
  WizardTemplate template() => WizardTemplate(
        parserConfig: ParserConfigBlock(),
        groupTemplates: GroupTemplates(),
        vars: const [],
        varSections: const [],
        config: {
          'outbounds': [
            {'tag': 'direct-out', 'type': 'direct'},
          ],
          'route': {'rules': []},
        },
        selectableRules: const [],
        dnsOptions: const {},
        pingOptions: const {},
        speedTestOptions: const {},
      );

  // Узлы с разными «флагами» в tag для regex-проверок.
  Future<UserServer> nodes() async {
    final specs = [
      parseUri('vless://u1@h1.com:443?type=ws&security=tls#🇩🇪 Berlin')!,
      parseUri('vless://u2@h2.com:443?type=ws&security=tls#🇩🇪 Premium')!,
      parseUri('vless://u3@h3.com:443?type=ws&security=tls#🇳🇱 Amsterdam')!,
      parseUri('vless://u4@h4.com:443?type=ws&security=tls#🇺🇸 NYC')!,
    ];
    return UserServer(
      id: 'u',
      name: 'N',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.paste,
      createdAt: DateTime.now(),
      nodes: specs,
    );
  }

  /// §322 — те же узлы + узел автовыбора (`autogroup://`) в том же списке.
  Future<UserServer> nodesWithAutoGroup() async {
    final base = await nodes();
    final auto = AutoSelectSpec(
      id: 'ag',
      tag: 'Auto DE',
      label: 'Auto DE',
      membership: const RuleMembers(include: '🇩🇪'),
    );
    return UserServer(
      id: base.id,
      name: base.name,
      enabled: base.enabled,
      tagPrefix: base.tagPrefix,
      detourPolicy: base.detourPolicy,
      origin: UserSource.paste,
      createdAt: DateTime.now(),
      nodes: [...base.nodes, auto],
    );
  }

  Future<List<Map<String, dynamic>>> build(List<Channel> channels,
      {bool passiveCheck = false}) async {
    final r = await buildConfig(
      lists: [await nodes()],
      template: template(),
      settings: BuildSettings(channels: channels, passiveCheck: passiveCheck),
    );
    expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
    return (r.config['outbounds'] as List).cast<Map<String, dynamic>>();
  }

  Map<String, dynamic> byTag(List<Map<String, dynamic>> outs, String tag) =>
      outs.firstWhere((o) => o['tag'] == tag);

  // §200 — полный BuildResult (для проверки emitWarnings).
  Future<List<String>> warningsFor(List<Channel> channels) async {
    final r = await buildConfig(
      lists: [await nodes()],
      template: template(),
      settings: BuildSettings(channels: channels),
    );
    return r.emitWarnings;
  }

  group('F1 — членство direct/auto/interrupt из галок', () {
    test('includeDirect=false → нет direct-out в selector', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'X', includeDirect: false),
      ]);
      final vpn1 = byTag(outs, 'vpn-1');
      expect(vpn1['outbounds'], isNot(contains('direct-out')));
      expect(vpn1['interrupt_exist_connections'], true);
    });

    test('includeDirect=true → direct-out опцией', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'X', includeDirect: true),
      ]);
      expect(byTag(outs, 'vpn-1')['outbounds'], contains('direct-out'));
    });

    test('§201 — includeBlock=true → block опцией селектора', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'X', includeBlock: true),
      ]);
      expect(byTag(outs, 'vpn-1')['outbounds'], contains('block'));
    });

    test('§201 — includeBlock=false → нет block', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'X'),
      ]);
      expect(byTag(outs, 'vpn-1')['outbounds'], isNot(contains('block')));
    });

    test('interruptExistConnections=false проброшен', () async {
      final outs = await build([
        const Channel(
            tag: 'vpn-1', label: 'X', interruptExistConnections: false),
      ]);
      expect(byTag(outs, 'vpn-1')['interrupt_exist_connections'], false);
    });

    test('disabled канал не эмитится (vpn-1 всё равно required)', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'X'),
        const Channel(tag: 'vpn-2', label: 'Y', enabled: false),
      ]);
      expect(outs.any((o) => o['tag'] == 'vpn-1'), true);
      expect(outs.any((o) => o['tag'] == 'vpn-2'), false);
    });
  });

  group('F1 — auto-двойник', () {
    test('§322 — узел автовыбора в selector канала есть, в двойнике нет',
        () async {
      // urltest внутри urltest мерил бы уже выбранный группой узел.
      final r = await buildConfig(
        lists: [await nodesWithAutoGroup()],
        template: template(),
        settings: const BuildSettings(channels: [
          Channel(tag: 'vpn-1', label: 'X', auto: ChannelAuto()),
        ]),
      );
      expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
      final outs = (r.config['outbounds'] as List).cast<Map<String, dynamic>>();

      // Группа собралась и попала в selector — выбрать её руками можно.
      expect(outs.any((o) => o['tag'] == 'Auto DE'), isTrue);
      expect(byTag(outs, 'vpn-1')['outbounds'], contains('Auto DE'));

      // …но НЕ в urltest-двойник канала.
      expect(byTag(outs, 'vpn-1-auto')['outbounds'],
          isNot(contains('Auto DE')));
      // Обычные узлы в двойнике остались.
      expect(byTag(outs, 'vpn-1-auto')['outbounds'], contains('🇩🇪 Berlin'));
    });

    test('auto != null → эмит <tag>-auto urltest по нодам канала', () async {
      final outs = await build([
        const Channel(
          tag: 'vpn-1',
          label: 'X',
          includeDirect: true,
          auto: ChannelAuto(
            url: 'https://t.example/204',
            interval: '4m',
            tolerance: 25,
            idleTimeout: '15m',
            interruptExistConnections: true,
          ),
        ),
      ]);
      final vpn1 = byTag(outs, 'vpn-1');
      expect(vpn1['outbounds'], contains('vpn-1-auto'));

      final auto = byTag(outs, 'vpn-1-auto');
      expect(auto['type'], 'urltest');
      expect(auto['url'], 'https://t.example/204');
      expect(auto['interval'], '4m');
      expect(auto['tolerance'], 25);
      expect(auto['idle_timeout'], '15m');
      expect(auto['interrupt_exist_connections'], true);
      // двойник — чистый urltest: без direct/auto-членов
      expect(auto['outbounds'], isNot(contains('direct-out')));
      expect(auto['outbounds'], isNot(contains('vpn-1-auto')));
      expect((auto['outbounds'] as List).length, 4); // все 4 ноды
    });

    test('auto == null → нет <tag>-auto', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'X'),
      ]);
      expect(outs.any((o) => o['tag'] == 'vpn-1-auto'), false);
    });

    // §272 — passive_check (ядро SPEC 019): пишется в auto-двойник только при
    // включённой настройке; выключено → поля нет (апстрим-поведение, и старое
    // ядро без поля не падает на unknown field).
    test('§272 passiveCheck=true → passive_check в auto-двойнике', () async {
      final outs = await build(
        [const Channel(tag: 'vpn-1', label: 'X', auto: ChannelAuto())],
        passiveCheck: true,
      );
      expect(byTag(outs, 'vpn-1-auto')['passive_check'], true);
    });

    test('§272 passiveCheck=false (дефолт) → поля нет', () async {
      final outs = await build(
        [const Channel(tag: 'vpn-1', label: 'X', auto: ChannelAuto())],
      );
      expect(
          byTag(outs, 'vpn-1-auto').containsKey('passive_check'), false);
    });

    // §208 — балансировщик round_robin
    test('leastTest (дефолт) → НЕТ mode/balancer (бит-в-бит апстрим)', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'X', auto: ChannelAuto()),
      ]);
      final auto = byTag(outs, 'vpn-1-auto');
      expect(auto.containsKey('mode'), false);
      expect(auto.containsKey('balancer'), false);
    });

    test('round_robin → mode + balancer{pool,pool_tolerance,sticky_hash}',
        () async {
      final outs = await build([
        const Channel(
          tag: 'vpn-1',
          label: 'X',
          auto: ChannelAuto(
            mode: UrltestMode.roundRobin,
            pool: 5,
            poolTolerance: 30,
            stickyHash: [StickyHashKey.process, StickyHashKey.domain],
          ),
        ),
      ]);
      final auto = byTag(outs, 'vpn-1-auto');
      expect(auto['mode'], 'round_robin');
      final bal = auto['balancer'] as Map<String, dynamic>;
      expect(bal['pool'], 5);
      expect(bal['pool_tolerance'], 30);
      expect(bal['sticky_hash'], ['process', 'domain']);
      // апстрим-поля urltest остаются (tolerance тоже — ядро игнорит в rr)
      expect(auto['type'], 'urltest');
      expect(auto.containsKey('tolerance'), true);
    });

    test('round_robin + пустой stickyHash → sticky_hash ["none"] (липкость выкл)',
        () async {
      // Контракт ядра rc.15: пустой [] ядро схлопывает в nil (badjson re-marshal)
      // → дефолтит липкость. Выключение ТОЛЬКО через sentinel ["none"].
      final outs = await build([
        const Channel(
          tag: 'vpn-1',
          label: 'X',
          auto: ChannelAuto(
            mode: UrltestMode.roundRobin,
            stickyHash: <StickyHashKey>[],
          ),
        ),
      ]);
      final bal = byTag(outs, 'vpn-1-auto')['balancer'] as Map<String, dynamic>;
      expect(bal['sticky_hash'], ['none']);
    });
  });

  group('F2 — per-channel regex node-filter', () {
    test('nodeFilter по эмодзи-флагу → только matched ноды', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'DE/NL', nodeFilter: '🇩🇪|🇳🇱'),
      ]);
      final ob = byTag(outs, 'vpn-1')['outbounds'] as List;
      expect(ob, containsAll(['🇩🇪 Berlin', '🇩🇪 Premium', '🇳🇱 Amsterdam']));
      expect(ob, isNot(contains('🇺🇸 NYC')));
    });

    test('два канала с разными regex → разные наборы', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'DE', nodeFilter: '🇩🇪'),
        const Channel(tag: 'vpn-2', label: 'US', nodeFilter: '🇺🇸'),
      ]);
      expect((byTag(outs, 'vpn-1')['outbounds'] as List), hasLength(2));
      final us = byTag(outs, 'vpn-2')['outbounds'] as List;
      expect(us, ['🇺🇸 NYC']);
    });

    test('§301 — nodeFilter регистронезависим: фильтр в другом регистре, '
        'чем теги, всё равно матчит (раньше — пустой набор)', () async {
      final outs = await build([
        // теги: `🇩🇪 Berlin`, `🇺🇸 NYC` — фильтр нарочно в другом регистре.
        const Channel(tag: 'vpn-1', label: 'lower', nodeFilter: 'berlin'),
        const Channel(tag: 'vpn-2', label: 'lower', nodeFilter: 'nyc'),
      ]);
      expect((byTag(outs, 'vpn-1')['outbounds'] as List), ['🇩🇪 Berlin']);
      expect((byTag(outs, 'vpn-2')['outbounds'] as List), ['🇺🇸 NYC']);
    });

    test('пустой nodeFilter → все ноды', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'all'),
      ]);
      expect((byTag(outs, 'vpn-1')['outbounds'] as List), hasLength(4));
    });

    test('§197 — nodeFilterInvert: исключить matched (все КРОМЕ 🇺🇸)', () async {
      final outs = await build([
        const Channel(
            tag: 'vpn-1',
            label: 'not-US',
            nodeFilter: '🇺🇸',
            nodeFilterInvert: true),
      ]);
      final ob = byTag(outs, 'vpn-1')['outbounds'] as List;
      expect(ob, containsAll(['🇩🇪 Berlin', '🇩🇪 Premium', '🇳🇱 Amsterdam']));
      expect(ob, isNot(contains('🇺🇸 NYC')));
    });

    test('§197 — invert + пустой фильтр → все ноды (инверсия игнор)', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'x', nodeFilterInvert: true),
      ]);
      expect((byTag(outs, 'vpn-1')['outbounds'] as List), hasLength(4));
    });

    test('§197/§201 — invert исключает ВСЁ → fallback [block, direct-out]',
        () async {
      // regex матчит всё (.) + invert → ничего не остаётся → block+direct
      // fallback, default=block (§201).
      final outs = await build([
        const Channel(
            tag: 'vpn-1', label: 'x', nodeFilter: '.', nodeFilterInvert: true),
      ]);
      final vpn1 = byTag(outs, 'vpn-1');
      expect(vpn1['outbounds'], ['block', 'direct-out']);
      expect(vpn1['default'], 'block');
    });

    test('невалидный regex → fallback на все ноды (не падает)', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'bad', nodeFilter: '[unclosed'),
      ]);
      expect((byTag(outs, 'vpn-1')['outbounds'] as List), hasLength(4));
    });

    test('§201 — regex без совпадений → fallback [block, direct-out] default block',
        () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'none', nodeFilter: 'NOMATCH'),
      ]);
      final vpn1 = byTag(outs, 'vpn-1');
      expect(vpn1['outbounds'], ['block', 'direct-out']);
      expect(vpn1['default'], 'block');
    });

    test('пустой node-set → auto-двойник НЕ эмитится', () async {
      final outs = await build([
        const Channel(
          tag: 'vpn-1',
          label: 'none',
          nodeFilter: 'NOMATCH',
          auto: ChannelAuto(),
        ),
      ]);
      expect(outs.any((o) => o['tag'] == 'vpn-1-auto'), false);
      expect(byTag(outs, 'vpn-1')['outbounds'], ['block', 'direct-out']);
    });
  });

  group('§200 — warning при пустом фильтре канала', () {
    test('фильтр отсёк все ноды → warning (blocked)', () async {
      final w = await warningsFor([
        const Channel(tag: 'vpn-1', label: 'Germany', nodeFilter: 'NOMATCH'),
      ]);
      expect(
          w.any((s) => s.contains('Germany') && s.contains('blocked')),
          true);
    });

    test('invert исключает всё → тоже warning', () async {
      final w = await warningsFor([
        const Channel(
            tag: 'vpn-1', label: 'x', nodeFilter: '.', nodeFilterInvert: true),
      ]);
      expect(w.any((s) => s.contains('vpn-1') && s.contains('blocked')), true);
    });

    test('пустой фильтр (все ноды) → НЕ варним', () async {
      final w = await warningsFor([
        const Channel(tag: 'vpn-1', label: 'x'),
      ]);
      expect(w.any((s) => s.contains('blocked')), false);
    });

    test('фильтр матчит хотя бы одну ноду → НЕ варним', () async {
      final w = await warningsFor([
        const Channel(tag: 'vpn-1', label: 'x', nodeFilter: '🇩🇪'),
      ]);
      expect(w.any((s) => s.contains('blocked')), false);
    });
  });

  group('F3 — default-regex', () {
    test('defaultFilter → первая matched нода как default', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'X', defaultFilter: 'Premium'),
      ]);
      expect(byTag(outs, 'vpn-1')['default'], '🇩🇪 Premium');
    });

    test('§301 — defaultFilter регистронезависим (тег `Premium`, фильтр '
        '`premium`)', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'X', defaultFilter: 'premium'),
      ]);
      expect(byTag(outs, 'vpn-1')['default'], '🇩🇪 Premium');
    });

    test('первая по порядку при нескольких совпадениях', () async {
      // обе 🇩🇪-ноды матчат '🇩🇪' — берём первую (Berlin идёт раньше)
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'X', defaultFilter: '🇩🇪'),
      ]);
      expect(byTag(outs, 'vpn-1')['default'], '🇩🇪 Berlin');
    });

    test('нет совпадений → default не выставляется', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'X', defaultFilter: 'NOPE'),
      ]);
      expect(byTag(outs, 'vpn-1').containsKey('default'), false);
    });

    test('пустой defaultFilter → нет default', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'X'),
      ]);
      expect(byTag(outs, 'vpn-1').containsKey('default'), false);
    });

    test('невалидный default-regex → нет default (не падает)', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'X', defaultFilter: '[bad'),
      ]);
      expect(byTag(outs, 'vpn-1').containsKey('default'), false);
    });

    test('default обязан быть в node-set (не direct-out)', () async {
      // фильтр оставляет 🇩🇪, но default-regex матчит 🇺🇸 (вне набора) → нет default
      final outs = await build([
        const Channel(
            tag: 'vpn-1',
            label: 'X',
            nodeFilter: '🇩🇪',
            defaultFilter: '🇺🇸'),
      ]);
      expect(byTag(outs, 'vpn-1').containsKey('default'), false);
    });
  });

  group('§125 — глобальный ✨auto отсутствует', () {
    test('никакой ✨auto в outbounds', () async {
      final outs = await build([
        const Channel(tag: 'vpn-1', label: 'X', auto: ChannelAuto()),
      ]);
      expect(outs.any((o) => o['tag'] == kAutoOutboundTag), false);
    });
  });

  group('F4.5 — деградация dangling route_final → vpn-1', () {
    Future<Map<String, dynamic>> buildWith(
        List<Channel> channels, String routeFinal) async {
      final r = await buildConfig(
        lists: [await nodes()],
        template: template(),
        settings: BuildSettings(channels: channels, routeFinal: routeFinal),
      );
      expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
      return r.config;
    }

    test('route_final на удалённый канал → vpn-1', () async {
      final cfg = await buildWith(
        [const Channel(tag: 'vpn-1', label: 'X')],
        'vpn-7', // не существует
      );
      expect((cfg['route'] as Map)['final'], 'vpn-1');
    });

    test('legacy ✨auto-ссылка → vpn-1', () async {
      final cfg = await buildWith(
        [const Channel(tag: 'vpn-1', label: 'X')],
        kAutoOutboundTag,
      );
      expect((cfg['route'] as Map)['final'], 'vpn-1');
    });

    test('валидный route_final (свой канал) не трогается', () async {
      final cfg = await buildWith(
        [
          const Channel(tag: 'vpn-1', label: 'X'),
          const Channel(tag: 'vpn-2', label: 'Y'),
        ],
        'vpn-2',
      );
      expect((cfg['route'] as Map)['final'], 'vpn-2');
    });

    test('route_final на свой auto-двойник валиден', () async {
      final cfg = await buildWith(
        [const Channel(tag: 'vpn-1', label: 'X', auto: ChannelAuto())],
        'vpn-1-auto',
      );
      expect((cfg['route'] as Map)['final'], 'vpn-1-auto');
    });

    // §219 — auto-двойник НЕ эмитится, если node-filter канала отсёк все ноды
    // (`auto != null`, но `nodes.isEmpty`). Раньше `<tag>-auto` безусловно
    // попадал в validFinals → route_final на него давал висячую ссылку (fatal).
    // Теперь validFinals = фактически эмитированные outbounds → деградация.
    test('route_final на auto-двойник с пустым node-set → vpn-1', () async {
      final cfg = await buildWith(
        [
          const Channel(
            tag: 'vpn-1',
            label: 'X',
            auto: ChannelAuto(),
            nodeFilter: '____NOMATCH____', // не матчит ни одну ноду
          ),
        ],
        'vpn-1-auto',
      );
      final outbounds = (cfg['outbounds'] as List).cast<Map>();
      // auto-двойник действительно не эмитирован
      expect(outbounds.any((o) => o['tag'] == 'vpn-1-auto'), false);
      // route.final деградировал на неудаляемый vpn-1
      expect((cfg['route'] as Map)['final'], 'vpn-1');
    });

    test('direct-out как route_final валиден', () async {
      final cfg = await buildWith(
        [const Channel(tag: 'vpn-1', label: 'X')],
        'direct-out',
      );
      expect((cfg['route'] as Map)['final'], 'direct-out');
    });
  });
}
