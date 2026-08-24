import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §125 F1/F2/F3 — билдер собирает outbound-группы из BuildSettings.directions:
/// per-direction regex node-set, direct/auto-членство из галок, auto-двойник,
/// default-regex. Проверяем через настоящий buildConfig (directions !== пусто →
/// идёт по новому пути, минуя template-fallback).
void main() {
  // template без preset-групп: Направления целиком из settings.directions.
  //
  // Служебные outbound'ы — ОБА, как их эмитит боевой `wizard_template.json`
  // (`magic_nodes.direct` = direct-out, `magic_nodes.block` = block). Раньше
  // здесь стоял один `direct-out`, и фикстура была неверна: `includeBlock` и
  // block-fallback пишут в состав селектора тег `block`, записи которого в
  // конфиге не было. Граф-санитайзер (§393 A4) считает живость по ФАКТУ
  // записи — ровно как `validator.dart` (`allTags`), — и такой `block`
  // законно вылетал из состава как призрак.
  WizardTemplate template() => WizardTemplate(
        parserConfig: ParserConfigBlock(),
        groupTemplates: GroupTemplates(),
        vars: const [],
        varSections: const [],
        config: {
          'outbounds': [
            {'tag': 'direct-out', 'type': 'direct'},
            {'tag': 'block', 'type': 'block'},
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

  Future<List<Map<String, dynamic>>> build(List<Direction> directions,
      {bool passiveCheck = false}) async {
    final r = await buildConfig(
      lists: [await nodes()],
      template: template(),
      settings: BuildSettings(directions: directions, passiveCheck: passiveCheck),
    );
    expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
    return (r.config['outbounds'] as List).cast<Map<String, dynamic>>();
  }

  Map<String, dynamic> byTag(List<Map<String, dynamic>> outs, String tag) =>
      outs.firstWhere((o) => o['tag'] == tag);

  // §200 — полный BuildResult (для проверки emitWarnings).
  Future<List<String>> warningsFor(List<Direction> directions) async {
    final r = await buildConfig(
      lists: [await nodes()],
      template: template(),
      settings: BuildSettings(directions: directions),
    );
    return r.emitWarnings;
  }

  group('F1 — членство direct/auto/interrupt из галок', () {
    test('includeDirect=false → нет direct-out в selector', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'X', includeDirect: false),
      ]);
      final vpn1 = byTag(outs, 'vpn-1');
      expect(vpn1['outbounds'], isNot(contains('direct-out')));
      expect(vpn1['interrupt_exist_connections'], true);
    });

    test('includeDirect=true → direct-out опцией', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'X', includeDirect: true),
      ]);
      expect(byTag(outs, 'vpn-1')['outbounds'], contains('direct-out'));
    });

    test('§201 — includeBlock=true → block опцией селектора', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'X', includeBlock: true),
      ]);
      expect(byTag(outs, 'vpn-1')['outbounds'], contains('block'));
    });

    test('§201 — includeBlock=false → нет block', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'X'),
      ]);
      expect(byTag(outs, 'vpn-1')['outbounds'], isNot(contains('block')));
    });

    test('interruptExistConnections=false проброшен', () async {
      final outs = await build([
        const Direction(
            tag: 'vpn-1', label: 'X', interruptExistConnections: false),
      ]);
      expect(byTag(outs, 'vpn-1')['interrupt_exist_connections'], false);
    });

    test('disabled Направление не эмитится (vpn-1 всё равно required)', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'X'),
        const Direction(tag: 'vpn-2', label: 'Y', enabled: false),
      ]);
      expect(outs.any((o) => o['tag'] == 'vpn-1'), true);
      expect(outs.any((o) => o['tag'] == 'vpn-2'), false);
    });
  });

  group('F1 — auto-двойник', () {
    test('§322 — узел автовыбора в selector Направления есть, в двойнике нет',
        () async {
      // urltest внутри urltest мерил бы уже выбранный группой узел.
      final r = await buildConfig(
        lists: [await nodesWithAutoGroup()],
        template: template(),
        settings: const BuildSettings(directions: [
          Direction(tag: 'vpn-1', label: 'X', auto: DirectionAuto()),
        ]),
      );
      expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
      final outs = (r.config['outbounds'] as List).cast<Map<String, dynamic>>();

      // Группа собралась и попала в selector — выбрать её руками можно.
      expect(outs.any((o) => o['tag'] == 'Auto DE'), isTrue);
      expect(byTag(outs, 'vpn-1')['outbounds'], contains('Auto DE'));

      // …но НЕ в urltest-двойник Направления.
      expect(byTag(outs, 'vpn-1-auto')['outbounds'],
          isNot(contains('Auto DE')));
      // Обычные узлы в двойнике остались.
      expect(byTag(outs, 'vpn-1-auto')['outbounds'], contains('🇩🇪 Berlin'));
    });

    test('auto != null → эмит <tag>-auto urltest по нодам Направления', () async {
      final outs = await build([
        const Direction(
          tag: 'vpn-1',
          label: 'X',
          includeDirect: true,
          auto: DirectionAuto(
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
        const Direction(tag: 'vpn-1', label: 'X'),
      ]);
      expect(outs.any((o) => o['tag'] == 'vpn-1-auto'), false);
    });

    // §272 — passive_check (ядро SPEC 019): пишется в auto-двойник только при
    // включённой настройке; выключено → поля нет (апстрим-поведение, и старое
    // ядро без поля не падает на unknown field).
    test('§272 passiveCheck=true → passive_check в auto-двойнике', () async {
      final outs = await build(
        [const Direction(tag: 'vpn-1', label: 'X', auto: DirectionAuto())],
        passiveCheck: true,
      );
      expect(byTag(outs, 'vpn-1-auto')['passive_check'], true);
    });

    test('§272 passiveCheck=false (дефолт) → поля нет', () async {
      final outs = await build(
        [const Direction(tag: 'vpn-1', label: 'X', auto: DirectionAuto())],
      );
      expect(
          byTag(outs, 'vpn-1-auto').containsKey('passive_check'), false);
    });

    // §208 — балансировщик round_robin
    test('leastTest (дефолт) → НЕТ mode/balancer (бит-в-бит апстрим)', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'X', auto: DirectionAuto()),
      ]);
      final auto = byTag(outs, 'vpn-1-auto');
      expect(auto.containsKey('mode'), false);
      expect(auto.containsKey('balancer'), false);
    });

    test('round_robin → mode + balancer{pool,pool_tolerance,sticky_hash}',
        () async {
      final outs = await build([
        const Direction(
          tag: 'vpn-1',
          label: 'X',
          auto: DirectionAuto(
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
        const Direction(
          tag: 'vpn-1',
          label: 'X',
          auto: DirectionAuto(
            mode: UrltestMode.roundRobin,
            stickyHash: <StickyHashKey>[],
          ),
        ),
      ]);
      final bal = byTag(outs, 'vpn-1-auto')['balancer'] as Map<String, dynamic>;
      expect(bal['sticky_hash'], ['none']);
    });
  });

  group('F2 — per-direction regex node-filter', () {
    test('nodeFilter по эмодзи-флагу → только matched ноды', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'DE/NL', nodeFilter: '🇩🇪|🇳🇱'),
      ]);
      final ob = byTag(outs, 'vpn-1')['outbounds'] as List;
      expect(ob, containsAll(['🇩🇪 Berlin', '🇩🇪 Premium', '🇳🇱 Amsterdam']));
      expect(ob, isNot(contains('🇺🇸 NYC')));
    });

    test('два Направления с разными regex → разные наборы', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'DE', nodeFilter: '🇩🇪'),
        const Direction(tag: 'vpn-2', label: 'US', nodeFilter: '🇺🇸'),
      ]);
      expect((byTag(outs, 'vpn-1')['outbounds'] as List), hasLength(2));
      final us = byTag(outs, 'vpn-2')['outbounds'] as List;
      expect(us, ['🇺🇸 NYC']);
    });

    test('§301 — nodeFilter регистронезависим: фильтр в другом регистре, '
        'чем теги, всё равно матчит (раньше — пустой набор)', () async {
      final outs = await build([
        // теги: `🇩🇪 Berlin`, `🇺🇸 NYC` — фильтр нарочно в другом регистре.
        const Direction(tag: 'vpn-1', label: 'lower', nodeFilter: 'berlin'),
        const Direction(tag: 'vpn-2', label: 'lower', nodeFilter: 'nyc'),
      ]);
      expect((byTag(outs, 'vpn-1')['outbounds'] as List), ['🇩🇪 Berlin']);
      expect((byTag(outs, 'vpn-2')['outbounds'] as List), ['🇺🇸 NYC']);
    });

    test('пустой nodeFilter → все ноды', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'all'),
      ]);
      expect((byTag(outs, 'vpn-1')['outbounds'] as List), hasLength(4));
    });

    test('§197 — nodeFilterInvert: исключить matched (все КРОМЕ 🇺🇸)', () async {
      final outs = await build([
        const Direction(
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
        const Direction(tag: 'vpn-1', label: 'x', nodeFilterInvert: true),
      ]);
      expect((byTag(outs, 'vpn-1')['outbounds'] as List), hasLength(4));
    });

    test('§197/§201 — invert исключает ВСЁ → fallback [block, direct-out]',
        () async {
      // regex матчит всё (.) + invert → ничего не остаётся → block+direct
      // fallback, default=block (§201).
      final outs = await build([
        const Direction(
            tag: 'vpn-1', label: 'x', nodeFilter: '.', nodeFilterInvert: true),
      ]);
      final vpn1 = byTag(outs, 'vpn-1');
      expect(vpn1['outbounds'], ['block', 'direct-out']);
      expect(vpn1['default'], 'block');
    });

    test('невалидный regex → fallback на все ноды (не падает)', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'bad', nodeFilter: '[unclosed'),
      ]);
      expect((byTag(outs, 'vpn-1')['outbounds'] as List), hasLength(4));
    });

    test('§201 — regex без совпадений → fallback [block, direct-out] default block',
        () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'none', nodeFilter: 'NOMATCH'),
      ]);
      final vpn1 = byTag(outs, 'vpn-1');
      expect(vpn1['outbounds'], ['block', 'direct-out']);
      expect(vpn1['default'], 'block');
    });

    test('пустой node-set → auto-двойник НЕ эмитится', () async {
      final outs = await build([
        const Direction(
          tag: 'vpn-1',
          label: 'none',
          nodeFilter: 'NOMATCH',
          auto: DirectionAuto(),
        ),
      ]);
      expect(outs.any((o) => o['tag'] == 'vpn-1-auto'), false);
      expect(byTag(outs, 'vpn-1')['outbounds'], ['block', 'direct-out']);
    });
  });

  group('§200 — warning при пустом фильтре Направления', () {
    test('фильтр отсёк все ноды → warning (blocked)', () async {
      final w = await warningsFor([
        const Direction(tag: 'vpn-1', label: 'Germany', nodeFilter: 'NOMATCH'),
      ]);
      expect(
          w.any((s) => s.contains('Germany') && s.contains('blocked')),
          true);
    });

    test('invert исключает всё → тоже warning', () async {
      final w = await warningsFor([
        const Direction(
            tag: 'vpn-1', label: 'x', nodeFilter: '.', nodeFilterInvert: true),
      ]);
      expect(w.any((s) => s.contains('vpn-1') && s.contains('blocked')), true);
    });

    test('пустой фильтр (все ноды) → НЕ варним', () async {
      final w = await warningsFor([
        const Direction(tag: 'vpn-1', label: 'x'),
      ]);
      expect(w.any((s) => s.contains('blocked')), false);
    });

    test('фильтр матчит хотя бы одну ноду → НЕ варним', () async {
      final w = await warningsFor([
        const Direction(tag: 'vpn-1', label: 'x', nodeFilter: '🇩🇪'),
      ]);
      expect(w.any((s) => s.contains('blocked')), false);
    });
  });

  group('F3 — default-regex', () {
    test('defaultFilter → первая matched нода как default', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'X', defaultFilter: 'Premium'),
      ]);
      expect(byTag(outs, 'vpn-1')['default'], '🇩🇪 Premium');
    });

    test('§301 — defaultFilter регистронезависим (тег `Premium`, фильтр '
        '`premium`)', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'X', defaultFilter: 'premium'),
      ]);
      expect(byTag(outs, 'vpn-1')['default'], '🇩🇪 Premium');
    });

    test('первая по порядку при нескольких совпадениях', () async {
      // обе 🇩🇪-ноды матчат '🇩🇪' — берём первую (Berlin идёт раньше)
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'X', defaultFilter: '🇩🇪'),
      ]);
      expect(byTag(outs, 'vpn-1')['default'], '🇩🇪 Berlin');
    });

    test('нет совпадений → default не выставляется', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'X', defaultFilter: 'NOPE'),
      ]);
      expect(byTag(outs, 'vpn-1').containsKey('default'), false);
    });

    test('пустой defaultFilter → нет default', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'X'),
      ]);
      expect(byTag(outs, 'vpn-1').containsKey('default'), false);
    });

    test('невалидный default-regex → нет default (не падает)', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'X', defaultFilter: '[bad'),
      ]);
      expect(byTag(outs, 'vpn-1').containsKey('default'), false);
    });

    test('default обязан быть в node-set (не direct-out)', () async {
      // фильтр оставляет 🇩🇪, но default-regex матчит 🇺🇸 (вне набора) → нет default
      final outs = await build([
        const Direction(
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
        const Direction(tag: 'vpn-1', label: 'X', auto: DirectionAuto()),
      ]);
      expect(outs.any((o) => o['tag'] == kAutoOutboundTag), false);
    });
  });

  group('F4.5 — деградация dangling route_final → vpn-1', () {
    Future<Map<String, dynamic>> buildWith(
        List<Direction> directions, String routeFinal) async {
      final r = await buildConfig(
        lists: [await nodes()],
        template: template(),
        settings: BuildSettings(directions: directions, routeFinal: routeFinal),
      );
      expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
      return r.config;
    }

    test('route_final на удалённое Направление → vpn-1', () async {
      final cfg = await buildWith(
        [const Direction(tag: 'vpn-1', label: 'X')],
        'vpn-7', // не существует
      );
      expect((cfg['route'] as Map)['final'], 'vpn-1');
    });

    test('legacy ✨auto-ссылка → vpn-1', () async {
      final cfg = await buildWith(
        [const Direction(tag: 'vpn-1', label: 'X')],
        kAutoOutboundTag,
      );
      expect((cfg['route'] as Map)['final'], 'vpn-1');
    });

    test('валидный route_final (своё Направление) не трогается', () async {
      final cfg = await buildWith(
        [
          const Direction(tag: 'vpn-1', label: 'X'),
          const Direction(tag: 'vpn-2', label: 'Y'),
        ],
        'vpn-2',
      );
      expect((cfg['route'] as Map)['final'], 'vpn-2');
    });

    test('route_final на свой auto-двойник валиден', () async {
      final cfg = await buildWith(
        [const Direction(tag: 'vpn-1', label: 'X', auto: DirectionAuto())],
        'vpn-1-auto',
      );
      expect((cfg['route'] as Map)['final'], 'vpn-1-auto');
    });

    // §219 — auto-двойник НЕ эмитится, если node-filter Направления отсёк все ноды
    // (`auto != null`, но `nodes.isEmpty`). Раньше `<tag>-auto` безусловно
    // попадал в validFinals → route_final на него давал висячую ссылку (fatal).
    // Теперь validFinals = фактически эмитированные outbounds → деградация.
    test('route_final на auto-двойник с пустым node-set → vpn-1', () async {
      final cfg = await buildWith(
        [
          const Direction(
            tag: 'vpn-1',
            label: 'X',
            auto: DirectionAuto(),
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
        [const Direction(tag: 'vpn-1', label: 'X')],
        'direct-out',
      );
      expect((cfg['route'] as Map)['final'], 'direct-out');
    });
  });

  group('§393 A3 — include[]: другие Направления опциями селектора', () {
    test('ссылка ВВЕРХ попадает в состав, warning'"'"'а нет', () async {
      final directions = [
        const Direction(tag: 'vpn-1', label: 'A'),
        const Direction(tag: 'vpn-2', label: 'B', include: ['vpn-1']),
      ];
      final outs = await build(directions);
      expect(byTag(outs, 'vpn-2')['outbounds'], contains('vpn-1'));
      expect(await warningsFor(directions), isEmpty);
    });

    test('ссылка ВНИЗ не эмитится + warning (forward-ref ядро не примет)',
        () async {
      final directions = [
        const Direction(tag: 'vpn-1', label: 'A', include: ['vpn-2']),
        const Direction(tag: 'vpn-2', label: 'B'),
      ];
      final outs = await build(directions);
      expect(byTag(outs, 'vpn-1')['outbounds'], isNot(contains('vpn-2')));
      final w = await warningsFor(directions);
      expect(w, hasLength(1));
      expect(w.single, contains('vpn-2'));
      expect(w.single, contains('listed above'));
    });

    test('reorder-сценарий: Направление переехало ВЫШЕ своей цели → '
        'деградация с warning, конфиг валиден', () async {
      // vpn-2 ссылался на vpn-1, пока стоял ниже; пользователь перетащил его
      // наверх — ссылка стала forward-ref. Данные НЕ санитайзятся (лаунчер
      // на reorder тоже только меняет порядок), деградирует ВЫХЛОП.
      final reordered = [
        const Direction(tag: 'vpn-2', label: 'B', include: ['vpn-1']),
        const Direction(tag: 'vpn-1', label: 'A'),
      ];
      final r = await buildConfig(
        lists: [await nodes()],
        template: template(),
        settings: BuildSettings(directions: reordered),
      );
      expect(r.validation.isOk, true,
          reason: r.validation.issues.join('\n'));
      final outs = (r.config['outbounds'] as List).cast<Map<String, dynamic>>();
      expect(byTag(outs, 'vpn-2')['outbounds'], isNot(contains('vpn-1')));
      expect(r.emitWarnings, hasLength(1));
      expect(r.emitWarnings.single, contains('vpn-1'));
    });

    test('ВЫКЛЮЧЕННОЕ Направление не эмитится → ссылка на него дропается '
        'с warning (dangling ref не даёт ядру стартовать)', () async {
      final directions = [
        const Direction(tag: 'vpn-1', label: 'A'),
        const Direction(tag: 'vpn-2', label: 'B', enabled: false),
        const Direction(tag: 'vpn-3', label: 'C', include: ['vpn-1', 'vpn-2']),
      ];
      final outs = await build(directions);
      final members = byTag(outs, 'vpn-3')['outbounds'] as List;
      expect(members, contains('vpn-1'));
      expect(members, isNot(contains('vpn-2')));
      final w = await warningsFor(directions);
      expect(w, hasLength(1));
      expect(w.single, contains('vpn-2'));
    });

    test('несуществующий тег дропается с warning', () async {
      final directions = [
        const Direction(tag: 'vpn-1', label: 'A', include: ['ghost']),
      ];
      final outs = await build(directions);
      expect(byTag(outs, 'vpn-1')['outbounds'], isNot(contains('ghost')));
      expect((await warningsFor(directions)).single, contains('ghost'));
    });

    test('самоссылка дропается (кольцо на одном узле)', () async {
      final directions = [
        const Direction(tag: 'vpn-1', label: 'A', include: ['vpn-1']),
      ];
      final outs = await build(directions);
      final members = byTag(outs, 'vpn-1')['outbounds'] as List;
      expect(members.where((t) => t == 'vpn-1'), isEmpty);
      expect(await warningsFor(directions), hasLength(1));
    });

    test('auto-двойник include-теги НЕ наследует (паритет с '
        'direction_twins.go: twin не получает AddOutbounds)', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'A'),
        const Direction(
            tag: 'vpn-2',
            label: 'B',
            include: ['vpn-1'],
            auto: DirectionAuto()),
      ]);
      expect(byTag(outs, 'vpn-2')['outbounds'], contains('vpn-1'));
      // urltest внутри urltest мерил бы выбор группы, а не сервер (§322).
      expect(byTag(outs, 'vpn-2-auto')['outbounds'], isNot(contains('vpn-1')));
    });

    test('include живёт рядом с includeDirect/includeBlock, не вместо них',
        () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'A'),
        const Direction(
            tag: 'vpn-2',
            label: 'B',
            include: ['vpn-1'],
            includeDirect: true,
            includeBlock: true),
      ]);
      final members = byTag(outs, 'vpn-2')['outbounds'] as List;
      expect(members, containsAll(['vpn-1', 'direct-out', 'block']));
    });

    test('пустое по фильтру Направление с include не уходит в block-fallback',
        () async {
      // Ссылка на другое Направление — это тоже опция: селектор не пуст,
      // значит fallback `[block, direct-out]` не нужен.
      final directions = [
        const Direction(tag: 'vpn-1', label: 'A'),
        const Direction(
            tag: 'vpn-2', label: 'B', nodeFilter: 'zzz', include: ['vpn-1']),
      ];
      final outs = await build(directions);
      final vpn2 = byTag(outs, 'vpn-2');
      expect(vpn2['outbounds'], ['vpn-1']);
      expect(vpn2.containsKey('default'), false);
      // Про пустой фильтр всё равно предупреждаем, но исход — не «blocked».
      final w = await warningsFor(directions);
      expect(w.single, contains('falls back to "vpn-1"'));
    });

    test('дубли в include схлопываются', () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'A'),
        const Direction(tag: 'vpn-2', label: 'B', include: ['vpn-1', 'vpn-1']),
      ]);
      final members = byTag(outs, 'vpn-2')['outbounds'] as List;
      expect(members.where((t) => t == 'vpn-1'), hasLength(1));
    });
  });

  group('§393 A3 — ПОРЯДОК состава: служебное и include ПЕРЕД узлами', () {
    // Первый элемент состава = неявный default sing-box (селектор без поля
    // `default` стартует на первой опции), поэтому порядок здесь —
    // семантика, а не косметика. Норматив — corpus/direction.

    test('corpus include_earlier_direction: include-тег перед узлами', () async {
      // Байт-в-байт состав из
      // contract/corpus/direction/include_earlier_direction.expected.json
      // (теги узлов подогнаны под узлы этого файла).
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'A', nodeFilter: '🇩🇪 Berlin'),
        const Direction(
            tag: 'vpn-2',
            label: 'B',
            nodeFilter: '🇩🇪 Berlin',
            include: ['vpn-1']),
      ]);
      expect(byTag(outs, 'vpn-1')['outbounds'], ['🇩🇪 Berlin']);
      expect(byTag(outs, 'vpn-2')['outbounds'], ['vpn-1', '🇩🇪 Berlin']);
    });

    test('corpus include_direct_and_block: direct-out, block, узлы', () async {
      // contract/corpus/direction/include_direct_and_block.expected.json:
      // служебные опции первыми, direct раньше block.
      final outs = await build([
        const Direction(
            tag: 'vpn-1',
            label: 'A',
            nodeFilter: '🇩🇪 Berlin',
            includeDirect: true,
            includeBlock: true),
      ]);
      expect(byTag(outs, 'vpn-1')['outbounds'],
          ['direct-out', 'block', '🇩🇪 Berlin']);
    });

    test('обе категории сразу: auto, direct, block, include, узлы '
        '(тай-брейк по лаунчеру — AddOutbounds одним списком)', () async {
      // Кейса с include И служебными опциями в корпусе нет; порядок взят у
      // лаунчера: форма собирает AddOutbounds как direct → block → прочие
      // теги (edit_dialog.go), auto-двойник встаёт впереди
      // (direction_twins.go prependUnique), и весь список эмитится ДО узлов
      // (outbound_generator.go «Add addOutbounds first»).
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'A'),
        const Direction(
          tag: 'vpn-2',
          label: 'B',
          nodeFilter: '🇩🇪 Berlin',
          include: ['vpn-1'],
          includeDirect: true,
          includeBlock: true,
          auto: DirectionAuto(),
        ),
      ]);
      expect(byTag(outs, 'vpn-2')['outbounds'],
          ['vpn-2-auto', 'direct-out', 'block', 'vpn-1', '🇩🇪 Berlin']);
    });

    test('узел подписки не становится неявным умолчанием Направления, '
        'состоящего из ссылок', () async {
      // Регресс порядка: пока узлы шли первыми, `outbounds.first` был
      // произвольный сервер подписки — ядро выбирало его умолчанием, хотя
      // пользователь включил direct-опцию/ссылку осознанно.
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'A'),
        const Direction(
            tag: 'vpn-2', label: 'B', include: ['vpn-1'], includeDirect: true),
      ]);
      expect((byTag(outs, 'vpn-2')['outbounds'] as List).first, 'direct-out');
    });

    test('порядок УЗЛОВ внутри состава — порядок конфига, не алфавит',
        () async {
      final outs = await build([
        const Direction(tag: 'vpn-1', label: 'A', includeDirect: true),
      ]);
      expect(byTag(outs, 'vpn-1')['outbounds'], [
        'direct-out',
        '🇩🇪 Berlin',
        '🇩🇪 Premium',
        '🇳🇱 Amsterdam',
        '🇺🇸 NYC',
      ]);
    });
  });

  group('§393 A3 — резерв тегов ВСЕХ Направлений, включая выключенные', () {
    test('узел-тёзка ВЫКЛЮЧЕННОГО Направления получает суффикс, а include '
        'на него не резолвится в узел', () async {
      // Дыра до фикса: reservedTags строился по `enabled || isRequired`, тег
      // выключенного vpn-2 не резервировался, узел подписки с меткой `vpn-2`
      // занимал literal-тег — и ссылка `include: ['vpn-2']` находила в
      // `emittedAbove`… нет, но узел с этим именем уже лежал в составе от
      // nodesFor, так что пользователь видел «vpn-2» опцией, ведущей в
      // чужой сервер вместо выключенного Направления.
      final specs = [
        parseUri('vless://u7@h7.com:443?type=ws&security=tls#vpn-2')!,
      ];
      final list = UserServer(
        id: 'u3',
        name: 'N3',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: specs,
      );
      final r = await buildConfig(
        lists: [list],
        template: template(),
        settings: BuildSettings(directions: const [
          Direction(tag: 'vpn-1', label: 'A'),
          Direction(tag: 'vpn-2', label: 'B', enabled: false),
          Direction(tag: 'vpn-3', label: 'C', include: ['vpn-2']),
        ]),
      );
      expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
      final outs = (r.config['outbounds'] as List).cast<Map<String, dynamic>>();
      final tags = outs.map((o) => o['tag']).toList();
      expect(tags, contains('vpn-2-1'),
          reason: 'узел-тёзка выключенного Направления переехал на суффикс');
      expect(outs.any((o) => o['tag'] == 'vpn-2'), false,
          reason: 'выключенное Направление не эмитится, и тег никем не занят');
      final members = byTag(outs, 'vpn-3')['outbounds'] as List;
      expect(members, isNot(contains('vpn-2')),
          reason: 'ни Направления, ни узла под этим именем в составе нет');
      expect(r.emitWarnings.where((w) => w.contains('vpn-2')), hasLength(1));
    });

    test('auto-двойник выключенного Направления тоже зарезервирован', () async {
      final specs = [
        parseUri('vless://u6@h6.com:443?type=ws&security=tls#vpn-2-auto')!,
      ];
      final list = UserServer(
        id: 'u4',
        name: 'N4',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: specs,
      );
      final r = await buildConfig(
        lists: [list],
        template: template(),
        settings: BuildSettings(directions: const [
          Direction(tag: 'vpn-1', label: 'A'),
          Direction(tag: 'vpn-2', label: 'B', enabled: false),
        ]),
      );
      expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
      final tags = (r.config['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .map((o) => o['tag'])
          .toList();
      expect(tags, contains('vpn-2-auto-1'));
    });
  });

  group('§393 A3 — гейт directionsWithoutNodes (SnackBar)', () {
    Future<List<String>> withoutNodesFor(List<Direction> directions) async {
      final r = await buildConfig(
        lists: [await nodes()],
        template: template(),
        settings: BuildSettings(directions: directions),
      );
      return r.directionsWithoutNodes;
    }

    test('пустой фильтр + include с рабочей целью → warning-текст есть, '
        'в списке «без узлов» Направления НЕТ', () async {
      // Состав НЕ деградировал: трафик идёт узлами цели, чинить нечего —
      // SnackBar «Направления без узлов» звал бы к ложной тревоге.
      final directions = [
        const Direction(tag: 'vpn-1', label: 'A'),
        const Direction(
            tag: 'vpn-2', label: 'B', nodeFilter: 'zzz', include: ['vpn-1']),
      ];
      final w = await warningsFor(directions);
      expect(w.single, contains('falls back to "vpn-1"'));
      expect(await withoutNodesFor(directions), isEmpty);
    });

    test('block-fallback → Направление в списке «без узлов»', () async {
      final directions = [
        const Direction(tag: 'vpn-1', label: 'A', nodeFilter: 'zzz'),
      ];
      expect(await withoutNodesFor(directions), ['A']);
    });

    test('единственный direct-out (без нод и без include) → в списке',
        () async {
      final directions = [
        const Direction(
            tag: 'vpn-1', label: 'A', nodeFilter: 'zzz', includeDirect: true),
      ];
      expect(await withoutNodesFor(directions), ['A']);
    });

    test('direct+block без нод и без include → в списке', () async {
      final directions = [
        const Direction(
            tag: 'vpn-1',
            label: 'A',
            nodeFilter: 'zzz',
            includeDirect: true,
            includeBlock: true),
      ];
      expect(await withoutNodesFor(directions), ['A']);
    });

    test('include + direct: цель рабочая → НЕ в списке (direct лишь опция)',
        () async {
      final directions = [
        const Direction(tag: 'vpn-1', label: 'A'),
        const Direction(
            tag: 'vpn-2',
            label: 'B',
            nodeFilter: 'zzz',
            include: ['vpn-1'],
            includeDirect: true),
      ];
      expect(await withoutNodesFor(directions), isEmpty);
    });
  });

  group('§351 — теги Направлений зарезервированы в аллокаторе', () {
    test('узлы-тёзки vpn-1 / vpn-1-auto получают суффикс, дублей нет',
        () async {
      // До §351 селектор Направления эмитился с фиксированным `c.tag` МИМО
      // allocateTag — узел подписки с меткой `vpn-1` давал два outbound
      // с одним тегом → отказ ядра на старте.
      final specs = [
        parseUri('vless://u9@h9.com:443?type=ws&security=tls#vpn-1')!,
        parseUri('vless://u8@h8.com:443?type=ws&security=tls#vpn-1-auto')!,
      ];
      final list = UserServer(
        id: 'u2',
        name: 'N2',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: specs,
      );
      final r = await buildConfig(
        lists: [list],
        template: template(),
        settings: BuildSettings(
          directions: [const Direction(tag: 'vpn-1', label: 'X')],
        ),
      );
      expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
      final outs = (r.config['outbounds'] as List).cast<Map<String, dynamic>>();
      final tags = outs.map((o) => o['tag']).toList();
      expect(tags.toSet().length, tags.length,
          reason: 'дубль тега = отказ ядра на старте: $tags');
      expect(byTag(outs, 'vpn-1')['type'], 'selector',
          reason: 'vpn-1 — Направление, не узел');
      expect(tags, contains('vpn-1-1'),
          reason: 'узел-тёзка селектора переехал на суффикс');
      expect(tags, contains('vpn-1-auto-1'),
          reason: 'autoTag зарезервирован даже без эмита двойника');
    });
  });
}
