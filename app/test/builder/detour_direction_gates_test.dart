import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/validation.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §248/§274 — detour-Направления в билдере. §274 сменил семантику isDetour с
/// «роли» на «разрешение»: block-опция совместима с detour, route_final и
/// custom-rule могут целиться в detour-Направление, fallback пустого Направления един
/// для всех — [block, direct-out] c default=block (§201/§274). Остались:
/// autoTag-алиас, AWG→WG advisory.
/// §254 — detour-циклы рвал не билдер, а детектор в validateConfig: fatal
/// DetourCycle с минимальным набором виновников. §393 A4 сменил политику на
/// лаунчерную: финальный граф-санитайзер (`sanitizeOutboundGraph`) ЧИНИТ граф
/// ДО валидатора — деградирует один элемент с warning, §254-fatal остаётся
/// последним рубежом на неразруленное (группа тестов «§254/§393 A4»).
/// Harness — как в direction_groups_test.dart (настоящий buildConfig,
/// directions из settings).
void main() {
  // Служебные outbound'ы — ОБА, как в боевом `wizard_template.json`
  // (`magic_nodes.direct`/`magic_nodes.block`): `includeBlock` и пустой
  // block-fallback кладут в состав селектора тег `block`, и без его записи
  // фикстура описывала бы конфиг, которого билдер не собирает. Граф-санитайзер
  // (§393 A4) считает живость по ФАКТУ записи — как `validator.dart`.
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

  // Одиночный UserServer с VLESS-нодами [names] и общей detour-политикой.
  UserServer vlessServer({
    required String id,
    required List<String> names,
    DetourPolicy policy = DetourPolicy.defaults,
  }) =>
      UserServer(
        id: id,
        name: id,
        enabled: true,
        tagPrefix: '',
        detourPolicy: policy,
        origin: UserSource.paste,
        createdAt: DateTime.now(),
        nodes: [
          for (final n in names)
            parseUri('vless://u-$id@h-$id.com:443?type=ws&security=tls#$n')!,
        ],
      );

  Future<BuildResult> build(List<ServerList> lists, List<Direction> directions,
      {String routeFinal = ''}) async {
    final r = await buildConfig(
      lists: lists,
      template: template(),
      settings: BuildSettings(directions: directions, routeFinal: routeFinal),
    );
    expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
    return r;
  }

  List<Map<String, dynamic>> outs(BuildResult r) =>
      (r.config['outbounds'] as List).cast<Map<String, dynamic>>();

  Map<String, dynamic> byTag(BuildResult r, String tag) =>
      outs(r).firstWhere((o) => o['tag'] == tag);

  group('§274 — block-опция и пустой fallback', () {
    test('block эмитится у detour-Направления при includeBlock=true', () async {
      // §274 — запрет detour×includeBlock снят (isDetour = разрешение, не
      // роль): block-опция эмитится в селектор detour-Направления как у обычного.
      final r = await build([
        vlessServer(id: 'u', names: ['A']),
      ], [
        const Direction(tag: 'vpn-1', label: 'Main'),
        const Direction(
            tag: 'vpn-2', label: 'Relay', isDetour: true, includeBlock: true),
      ]);
      expect(byTag(r, 'vpn-2')['outbounds'], contains('block'));
      // У всех Направлений есть ноды → список пустых Направлений пуст.
      expect(r.directionsWithoutNodes, isEmpty);
    });

    test('пустое detour-Направление → [block, direct-out] c default=block + warning',
        () async {
      // §274 — detour-исключение §248 Q1 ([direct-out], «нет хопа») снято:
      // fallback пустого Направления единый для всех — блокировать по умолчанию,
      // direct остаётся доступной опцией.
      final r = await build([
        vlessServer(id: 'u', names: ['A']),
      ], [
        const Direction(tag: 'vpn-1', label: 'Main'),
        const Direction(
            tag: 'vpn-2',
            label: 'Relay',
            isDetour: true,
            nodeFilter: 'no-such-node'),
      ]);
      final vpn2 = byTag(r, 'vpn-2');
      expect(vpn2['outbounds'], ['block', 'direct-out']);
      expect(vpn2['default'], 'block');
      // Единый текст warning'а; displayLabel detour-Направления — с ⚙-префиксом.
      expect(
          r.emitWarnings,
          contains(contains(
              'Direction "⚙ Relay" (vpn-2): node filter matched no nodes')));
      // §274 — display-имя попадает в directionsWithoutNodes (SnackBar на
      // Home); Направление с нодами (Main) в список не попадает.
      expect(r.directionsWithoutNodes, ['⚙ Relay']);
    });

    test('пустой ОБЫЧНЫЙ Направление — прежний §201 [block, direct-out]', () async {
      final r = await build([
        vlessServer(id: 'u', names: ['A']),
      ], [
        const Direction(tag: 'vpn-1', label: 'Main'),
        const Direction(tag: 'vpn-2', label: 'X', nodeFilter: 'no-such-node'),
      ]);
      final vpn2 = byTag(r, 'vpn-2');
      expect(vpn2['outbounds'], ['block', 'direct-out']);
      expect(vpn2['default'], 'block');
      // §274 — display-имя пустого Направления в directionsWithoutNodes.
      expect(r.directionsWithoutNodes, ['X']);
      // Warning говорит правду: emptyFallback → default=block.
      expect(r.emitWarnings,
          contains(contains('traffic is blocked (default)')));
    });

    test(
        'include_direct × 0 нод: первая опция direct-out, warning честен '
        '(«goes direct», НЕ «blocked»)', () async {
      // Адверсарное ревью §274: [direct-out] непуст → emptyFallback НЕ
      // срабатывает, default не ставится, ядро берёт первую опцию =
      // direct-out. Текст warning обязан отражать фактический исход.
      final r = await build([
        vlessServer(id: 'u', names: ['A']),
      ], [
        const Direction(tag: 'vpn-1', label: 'Main'),
        const Direction(
            tag: 'vpn-2',
            label: 'X',
            includeDirect: true,
            nodeFilter: 'no-such-node'),
      ]);
      final vpn2 = byTag(r, 'vpn-2');
      expect(vpn2['outbounds'], ['direct-out']);
      expect(vpn2.containsKey('default'), isFalse);
      expect(r.emitWarnings,
          contains(contains('traffic goes direct (no VPN hop)')));
      expect(r.emitWarnings,
          isNot(contains(contains('traffic is blocked'))));
      expect(r.directionsWithoutNodes, ['X']);
    });

    test('негативные кейсы directionsWithoutNodes: не вина фильтра — не варним',
        () async {
      // (а) Пустой фильтр + есть ноды подписки → Направление берёт все ноды.
      final withNodes = await build([
        vlessServer(id: 'u', names: ['A']),
      ], [
        const Direction(tag: 'vpn-1', label: 'Main'),
      ]);
      expect(withNodes.directionsWithoutNodes, isEmpty);
      // (б) Непустой фильтр, но подписок нет вовсе (selectorTags пуст) —
      // 0 нод не вина фильтра, SnackBar не показываем.
      final noSubs = await build(<ServerList>[], [
        const Direction(tag: 'vpn-1', label: 'Main', nodeFilter: 'anything'),
      ]);
      expect(noSubs.directionsWithoutNodes, isEmpty);
      // (в) Пустой фильтр и нет подписок — тоже тишина.
      final emptyAll = await build(<ServerList>[], [
        const Direction(tag: 'vpn-1', label: 'Main'),
      ]);
      expect(emptyAll.directionsWithoutNodes, isEmpty);
    });
  });

  group('§254/§393 A4 — detour-циклы: разрывает санитайзер, не валидатор', () {
    // §254 ввёл fatal DetourCycle с минимальным набором виновников: билдер
    // цикл НЕ рвал, конфиг не собирался, юзер устранял причину сам.
    // §393 A4 привёл политику к лаунчеру (`outbound_graph_sanitize.go`):
    // финальный граф-санитайзер ЧИНИТ граф ДО валидатора — деградирует один
    // элемент с warning, а не отдаёт ядру конфиг, который оно отвергнет.
    // §254-fatal остался ПОСЛЕДНИМ рубежом на неразруленное: в сценариях ниже
    // он уже не срабатывает, `validation.isOk` — true.
    //
    // Что сохранилось от §254 — МИНИМАЛЬНОСТЬ: рвётся ровно то ребро, что
    // развязывает кольцо, невиновные соседи не страдают. «Минимальный набор
    // виновников» превратился в минимальность разорванных рёбер.
    //
    // Разделение труда внутри санитайзера:
    //   • правило 4 (`detour_group_cycle.go`) — узел, чей detour ведёт в
    //     группу, в состав которой он сам входит: ВОН ИЗ СОСТАВА, detour
    //     сохранён (fail-open);
    //   • правило 5 (`breakDependencyCycle`) — всё прочее кольцо: снимается
    //     detour у ноды с максимальным «весом» ребра.

    Future<BuildResult> buildRaw(
            List<ServerList> lists, List<Direction> directions) =>
        buildConfig(
          lists: lists,
          template: template(),
          settings: BuildSettings(directions: directions),
        );

    List<DetourCycle> cyclesOf(BuildResult r) =>
        r.validation.fatal.whereType<DetourCycle>().toList();

    test('прямой цикл: member.detour=C → член вон из состава, detour цел',
        () async {
      // §254 показывал fatal с culprit=[Relay Berlin]. Теперь тот же виновник
      // деградирует правилом 4: он выпадает из состава vpn-2, а detour —
      // осознанное решение пользователя — остаётся.
      final r = await buildRaw([
        vlessServer(
            id: 'u',
            names: ['Relay Berlin'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
      ], [
        const Direction(tag: 'vpn-1', label: 'Main'),
        const Direction(
            tag: 'vpn-2', label: 'Relay', isDetour: true, nodeFilter: 'Relay'),
      ]);
      expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
      expect(cyclesOf(r), isEmpty, reason: '§254-fatal больше не нужен');
      expect(byTag(r, 'Relay Berlin')['detour'], 'vpn-2',
          reason: 'fail-open: detour пользователя сохранён');
      expect(
          r.emitWarnings,
          contains(contains(
              'Outbound "Relay Berlin" detours through group "vpn-2" it '
              'belongs to')));
      // Единственный член ушёл → Направление в block-fallback (§201/§274).
      expect(byTag(r, 'vpn-2')['outbounds'], ['block', 'direct-out']);
      expect(byTag(r, 'vpn-2')['default'], 'block');
    });

    test('цикл через auto-двойник (detour=<tag>-auto) — тот же разрыв',
        () async {
      // Двойник держит те же ноды, что и селектор: узел выпадает из состава
      // двойника, тот пустеет и дропается, а висячий detour снимается
      // правилом 1 на следующей итерации фикспойнта — каскад, а не fatal.
      final r = await buildRaw([
        vlessServer(
            id: 'u',
            names: ['Relay Berlin'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2-auto')),
      ], [
        const Direction(tag: 'vpn-1', label: 'Main'),
        const Direction(
            tag: 'vpn-2',
            label: 'Relay',
            isDetour: true,
            nodeFilter: 'Relay',
            auto: DirectionAuto()),
      ]);
      expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
      expect(cyclesOf(r), isEmpty);
      expect(outs(r).any((o) => o['tag'] == 'vpn-2-auto'), isFalse,
          reason: 'опустевший двойник дропнут');
      expect(byTag(r, 'Relay Berlin').containsKey('detour'), isFalse,
          reason: 'detour на дропнутый двойник снят каскадом');
      expect(r.emitWarnings, contains(contains('Detour removed')));
      // Сам узел уцелел и остался опцией Направления.
      expect(byTag(r, 'vpn-2')['outbounds'], ['Relay Berlin']);
    });

    test('транзитивный цикл через промежуточный узел — рвётся ОДНО ребро',
        () async {
      // Client ∈ vpn-2; Client→Mid→vpn-2. Кольцо идёт через detour ЧУЖОГО
      // узла (Mid), поэтому правило 4 сюда не лезет — работает правило 5.
      // Оба ребра развязывают цикл (равный score), тай-брейк
      // лексикографический даёт Client.
      final r = await buildRaw([
        vlessServer(
            id: 'c',
            names: ['Client'],
            policy: const DetourPolicy(overrideDetour: 'Mid')),
        vlessServer(
            id: 'm',
            names: ['Mid'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
      ], [
        const Direction(tag: 'vpn-1', label: 'Main'),
        const Direction(
            tag: 'vpn-2',
            label: 'Relay',
            isDetour: true,
            nodeFilter: 'Client'),
      ]);
      expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
      expect(cyclesOf(r), isEmpty);
      expect(
          r.emitWarnings,
          contains(contains(
              'Dependency cycle through detour "Client" → "Mid"')));
      expect(byTag(r, 'Client').containsKey('detour'), isFalse);
      // Минимальность: второе ребро (Mid→vpn-2) не тронуто, состав цел.
      expect(byTag(r, 'Mid')['detour'], 'vpn-2');
      expect(byTag(r, 'vpn-2')['outbounds'], ['Client']);
    });

    test('цикл между Направлениями: A∈C1→C2, B∈C2→C1 — одно разорванное ребро',
        () async {
      final r = await buildRaw([
        vlessServer(
            id: 'a',
            names: ['Node A'],
            policy: const DetourPolicy(overrideDetour: 'vpn-3')),
        vlessServer(
            id: 'b',
            names: ['Node B'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
      ], [
        const Direction(tag: 'vpn-1', label: 'Main'),
        const Direction(
            tag: 'vpn-2', label: 'C1', isDetour: true, nodeFilter: 'Node A'),
        const Direction(
            tag: 'vpn-3', label: 'C2', isDetour: true, nodeFilter: 'Node B'),
      ]);
      expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
      expect(cyclesOf(r), isEmpty);
      // Кольцо одно (A→C2→B→C1→A): рвётся РОВНО одно ребро (какое — тай-брейк,
      // оба симметричны), состав обоих Направлений уцелел.
      final broken = r.emitWarnings
          .where((w) => w.contains('Dependency cycle'))
          .toList();
      expect(broken, hasLength(1));
      expect(byTag(r, 'vpn-2')['outbounds'], ['Node A']);
      expect(byTag(r, 'vpn-3')['outbounds'], ['Node B']);
    });

    test('ссылка на ОБЫЧНОЕ Направление (Debug API-сценарий) — тот же разрыв',
        () async {
      final r = await buildRaw([
        vlessServer(
            id: 'u',
            names: ['Node X'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
      ], [
        const Direction(tag: 'vpn-1', label: 'Main'),
        const Direction(tag: 'vpn-2', label: 'Plain', nodeFilter: 'Node X'),
      ]);
      expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
      expect(cyclesOf(r), isEmpty);
      expect(
          r.emitWarnings,
          contains(contains(
              'Outbound "Node X" detours through group "vpn-2" it belongs '
              'to')));
      expect(byTag(r, 'Node X')['detour'], 'vpn-2');
    });

    test('флагман §248: relay в той же подписке под overrideDetour=C — '
        'вон из состава relay, клиенты невиновны', () async {
      // §254 отдавал это fatal'ом с culprit=relay; §393 A4 вернул
      // автоматическое выпутывание, но БЕЗ старого edge-strip'а: relay
      // выпадает из состава (и из auto-двойника), detour у всех троих цел.
      final r = await buildRaw([
        vlessServer(
            id: 'u',
            names: ['Relay Berlin', 'Client A', 'Client B'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
      ], [
        const Direction(tag: 'vpn-1', label: 'Main'),
        const Direction(
            tag: 'vpn-2',
            label: 'Relay',
            isDetour: true,
            nodeFilter: 'Relay',
            auto: DirectionAuto()),
      ]);
      expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
      expect(cyclesOf(r), isEmpty);
      // Виновник — только relay (единственный ЧЛЕН Направления); клиенты в
      // состав не входили и ничего не потеряли.
      // §393 A4 фикс 4 — агрегация правила 4 по УЗЛУ: relay выброшен и из
      // селектора Направления, и из его auto-двойника, но warning ОДИН, со
      // списком обеих групп (а не два одинаковых про одну ноду).
      final cyclicLines = r.emitWarnings
          .where((w) => w.contains('it belongs to — excluded'))
          .toList();
      expect(cyclicLines, hasLength(1));
      expect(cyclicLines.single, contains('"Relay Berlin"'));
      expect(cyclicLines.single, contains('"vpn-2"'));
      expect(cyclicLines.single, contains('"vpn-2-auto"'));
      for (final tag in ['Relay Berlin', 'Client A', 'Client B']) {
        expect(byTag(r, tag)['detour'], 'vpn-2', reason: '$tag: detour цел');
      }
      expect(byTag(r, 'vpn-2')['outbounds'], ['block', 'direct-out'],
          reason: 'состав опустел → block-fallback (§201/§274)');
    });

    test('реальный кейс §254: флот∈C1→C2, одна нода∈C2→C1 — рвётся ребро '
        'ровно у неё, флот цел', () async {
      // Миниатюра device-кейса: 3 «BL»-ноды в vpn-2 детурят в vpn-3
      // (WARP IN); внутри vpn-3 одна AWG-нода по ошибке детурит обратно в
      // vpn-2, две MASQUE-ноды чисты. Это МЕРА МИНИМАЛЬНОСТИ, ради которой
      // §254 вообще появился: наивный «первое замыкающее ребро из DFS»
      // эталона отобрал бы detour у двух чистых BL-нод вместо одной виноватой
      // AWG, а транзитивное правило 4 выбросило бы весь флот из состава vpn-2
      // и увело бы Направление в block. Верный исход — один снятый detour.
      // §301 — фильтры case-insensitive: `BL Helsinki` содержал "in" и попал
      // бы и в vpn-3 (nodeFilter 'IN'), потому берём `BL Varna`.
      final r = await buildRaw([
        vlessServer(
            id: 'bl',
            names: ['BL Sofia', 'BL Zagreb', 'BL Varna'],
            policy: const DetourPolicy(overrideDetour: 'vpn-3')),
        vlessServer(id: 'in1', names: ['IN Masque A']),
        vlessServer(id: 'in2', names: ['IN Masque B']),
        vlessServer(
            id: 'awg',
            names: ['IN Awg'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
      ], [
        const Direction(tag: 'vpn-1', label: 'Main'),
        const Direction(
            tag: 'vpn-2', label: 'BL', isDetour: true, nodeFilter: 'BL'),
        const Direction(
            tag: 'vpn-3', label: 'WARP IN', isDetour: true, nodeFilter: 'IN'),
      ]);
      expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
      expect(cyclesOf(r), isEmpty);
      // Ровно одна деградация, и та — у виноватой ноды.
      final degraded =
          r.emitWarnings.where((w) => w.contains('Dependency cycle')).toList();
      expect(degraded, hasLength(1));
      expect(degraded.single, contains('"IN Awg"'));
      expect(byTag(r, 'IN Awg').containsKey('detour'), isFalse);
      // Флот не тронут: ни detour'ы, ни состав vpn-2, ни упоминание в логе.
      for (final tag in ['BL Sofia', 'BL Zagreb', 'BL Varna']) {
        expect(byTag(r, tag)['detour'], 'vpn-3', reason: '$tag невиновен');
      }
      expect(byTag(r, 'vpn-2')['outbounds'],
          ['BL Sofia', 'BL Zagreb', 'BL Varna']);
      expect(degraded.single, isNot(contains('BL Sofia')));
    });

    test('линейная цепочка Направлений C1→C2→C3 без замыкания → ok', () async {
      // Регрессия device-кейса ПОСЛЕ устранения виновника: [BL]→WARP IN→
      // наружу, WARP OUT→[BL] — ацикличная цепочка, санитайзер молчит.
      final r = await build([
        vlessServer(
            id: 'out',
            names: ['OUT Warp'],
            policy: const DetourPolicy(overrideDetour: 'vpn-3')),
        vlessServer(
            id: 'bl',
            names: ['BL Sofia', 'BL Zagreb'],
            policy: const DetourPolicy(overrideDetour: 'vpn-4')),
        vlessServer(id: 'in1', names: ['IN Masque'])
      ], [
        const Direction(tag: 'vpn-1', label: 'Main'),
        const Direction(
            tag: 'vpn-2', label: 'OUT', isDetour: true, nodeFilter: 'OUT'),
        const Direction(
            tag: 'vpn-3', label: 'BL', isDetour: true, nodeFilter: 'BL'),
        const Direction(
            tag: 'vpn-4', label: 'WARP IN', isDetour: true, nodeFilter: 'IN'),
      ]);
      expect(byTag(r, 'BL Sofia')['detour'], 'vpn-4');
      expect(byTag(r, 'OUT Warp')['detour'], 'vpn-3');
      expect(r.emitWarnings, isNot(contains(contains('Dependency cycle'))));
      expect(r.emitWarnings,
          isNot(contains(contains('it belongs to — excluded'))));
    });

    test('два независимых кольца → два разрыва, по одному на кольцо', () async {
      // Смысл сценария §254 («два issue, по culprit на каждое») сохранён:
      // независимые кольца обрабатываются независимо, ни одно не глотает
      // другое — просто мера теперь в разорванных рёбрах, а не в issue.
      final r = await buildRaw([
        vlessServer(
            id: 'x',
            names: ['Node X'],
            policy: const DetourPolicy(overrideDetour: 'vpn-2')),
        vlessServer(
            id: 'y',
            names: ['Node Y'],
            policy: const DetourPolicy(overrideDetour: 'vpn-3')),
      ], [
        const Direction(tag: 'vpn-1', label: 'Main'),
        const Direction(
            tag: 'vpn-2', label: 'C1', isDetour: true, nodeFilter: 'Node X'),
        const Direction(
            tag: 'vpn-3', label: 'C2', isDetour: true, nodeFilter: 'Node Y'),
      ]);
      expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
      expect(cyclesOf(r), isEmpty);
      // По одному разрыву на кольцо — оба узла названы, ни один не пропущен.
      final degraded = r.emitWarnings
          .where((w) => w.contains('it belongs to — excluded'))
          .toList();
      expect(degraded, hasLength(2));
      expect(degraded.join('\n'), contains('"Node X"'));
      expect(degraded.join('\n'), contains('"Node Y"'));
      // Оба Направления опустели → block-fallback, оба уцелели как цели правил.
      for (final tag in ['vpn-2', 'vpn-3']) {
        expect(byTag(r, tag)['outbounds'], ['block', 'direct-out']);
        expect(byTag(r, tag)['default'], 'block');
      }
    });
  });

  group('§274/§248 — custom-rule на detour-Направление и омонимия', () {
    test('custom-rule на detour-Направление → конфиг валиден (штатно, §274)',
        () async {
      // §274 — isDetour это разрешение, не роль: detour-Направление остаётся
      // валидной целью custom-rule outbound. Селектор vpn-2 в конфиге
      // существует, валидатор доволен, ссылку никто не «чинит».
      final r = await buildConfig(
        lists: [vlessServer(id: 'u', names: ['A'])],
        template: template(),
        settings: BuildSettings(
          directions: const [
            Direction(tag: 'vpn-1', label: 'Main'),
            Direction(tag: 'vpn-2', label: 'Relay', isDetour: true),
          ],
          customRules: [
            CustomRuleInline(
                name: 'Pin', domains: const ['x.com'], outbound: 'vpn-2'),
          ],
        ),
      );
      expect(r.validation.isOk, true,
          reason: r.validation.issues.join('\n'));
    });

    test('омоним: member.detour=тёзка Направления → интра-ребро на члена', () async {
      // Член папки носит bare-тег 'vpn-2' — тёзка detour-Направления. Ссылка
      // member B detour='vpn-2' внутри ТОЙ ЖЕ папки означает ЧЛЕНА
      // (приоритет bareIndex FolderDetourPlan): резолв в display-form
      // 'hm- vpn-2', Направление ни при чём — edge-strip рёбер не трогает.
      final folder = FolderServers(
        id: 'f1',
        name: 'Homonym',
        enabled: true,
        tagPrefix: 'hm-',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember(raw: 'vless://u@h.com:443?type=ws&security=tls#vpn-2'),
          FolderMember(
              raw: 'vless://u2@h2.com:443?type=ws&security=tls#node-b',
              detour: 'vpn-2'),
        ],
      );
      final r = await build([
        folder,
        vlessServer(id: 'x', names: ['Exit Node']),
      ], [
        const Direction(tag: 'vpn-1', label: 'Main'),
        const Direction(
            tag: 'vpn-2', label: 'Relay', isDetour: true, nodeFilter: 'Exit'),
      ]);
      expect(byTag(r, 'hm- node-b')['detour'], 'hm- vpn-2');
      expect(r.emitWarnings, isNot(contains(contains('removed detour'))));
      expect(r.emitWarnings, isNot(contains(contains('routing loop'))));
    });
  });

  group('§274 — route_final может быть detour-Направлением', () {
    test('route_final=detour-Направление остаётся, warning отсутствует', () async {
      // §274 — вычитание detour-тегов из validFinals снято: detour-Направление —
      // валидная rules-мишень, route.final не переключается на vpn-1.
      final r = await build(
        [vlessServer(id: 'u', names: ['A'])],
        [
          const Direction(tag: 'vpn-1', label: 'Main'),
          const Direction(tag: 'vpn-2', label: 'Relay', isDetour: true),
        ],
        routeFinal: 'vpn-2',
      );
      expect((r.config['route'] as Map)['final'], 'vpn-2');
      expect(
          r.emitWarnings, isNot(contains(contains('is a detour direction'))));
      expect(
          r.emitWarnings, isNot(contains(contains('switched to vpn-1'))));
    });

    test('route_final=auto-двойник detour-Направления остаётся (двойник эмитится)',
        () async {
      // auto включён и ноды есть → 'vpn-2-auto' реально эмитится (§219) и
      // потому валидная мишень.
      final r = await build(
        [vlessServer(id: 'u', names: ['A'])],
        [
          const Direction(tag: 'vpn-1', label: 'Main'),
          const Direction(
              tag: 'vpn-2',
              label: 'Relay',
              isDetour: true,
              auto: DirectionAuto()),
        ],
        routeFinal: 'vpn-2-auto',
      );
      expect((r.config['route'] as Map)['final'], 'vpn-2-auto');
      expect(
          r.emitWarnings, isNot(contains(contains('is a detour direction'))));
    });

    test('route_final=НЕэмитящийся auto-двойник (0 нод) → vpn-1 + warning',
        () async {
      // §219 — auto-двойник без нод не эмитится, ссылка на него висячая:
      // деградация «no longer exists — switched to vpn-1» осталась (§274
      // снял только detour-запрет, не гейт по фактическим outbounds).
      final r = await build(
        [vlessServer(id: 'u', names: ['A'])],
        [
          const Direction(tag: 'vpn-1', label: 'Main'),
          const Direction(
              tag: 'vpn-2',
              label: 'Relay',
              isDetour: true,
              nodeFilter: 'no-such-node',
              auto: DirectionAuto()),
        ],
        routeFinal: 'vpn-2-auto',
      );
      expect((r.config['route'] as Map)['final'], 'vpn-1');
      expect(
          r.emitWarnings,
          contains(contains(
              'Route final "vpn-2-auto" no longer exists — switched to '
              'vpn-1')));
    });

    test('route_final=обычное Направление остаётся как есть', () async {
      final r = await build(
        [vlessServer(id: 'u', names: ['A'])],
        [
          const Direction(tag: 'vpn-1', label: 'Main'),
          const Direction(tag: 'vpn-2', label: 'Plain'),
        ],
        routeFinal: 'vpn-2',
      );
      expect((r.config['route'] as Map)['final'], 'vpn-2');
    });
  });
}
