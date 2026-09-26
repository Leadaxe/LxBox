import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_replace.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/builder/source_replace_build.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import '../parser/engine_test_setup.dart';

/// Фича 565 фаза B (контракт 1.1.78 §74) — свёртка подписки/папки в группу на
/// сборке: группы по режиму, двойник `<tag>-auto`, узлы уходят из пула
/// Направлений, ноль узлов — групп нет, правило на выпавшую свёртку не роняет
/// конфиг.
void main() {
  setUpAll(loadEngineSections);

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

  const uriA = 'vless://u1@h1.com:443?type=ws&security=tls&sni=h1.com#A';
  const uriB = 'vless://u2@h2.com:443?type=ws&security=tls&sni=h2.com#B';
  const uriC = 'vless://u3@h3.com:443?type=ws&security=tls&sni=h3.com#C';

  SubscriptionServers sub(
    SourceReplace? replace, {
    Map<String, DateTime> disabled = const {},
  }) =>
      SubscriptionServers(
        id: 's1',
        name: 'Provider',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example-1.com/sub',
        disabledHashes: disabled,
        replace: replace,
        nodes: [parseUri(uriA)!, parseUri(uriB)!],
      );

  UserServer loose() => UserServer(
        id: 'u1',
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        nodes: [parseUri(uriC)!],
      );

  Future<BuildResult> build(
    List<ServerList> lists, {
    List<CustomRule> rules = const [],
    String routeFinal = '',
  }) =>
      buildConfig(
        lists: lists,
        template: template(),
        settings: BuildSettings(
          directions: const [
            Direction(tag: 'vpn-1', label: 'VPN', auto: DirectionAuto()),
          ],
          customRules: rules,
          routeFinal: routeFinal,
        ),
      );

  List<Map<String, dynamic>> outs(BuildResult r) =>
      (r.config['outbounds'] as List).cast<Map<String, dynamic>>();
  Map<String, dynamic>? byTag(BuildResult r, String tag) =>
      outs(r).where((o) => o['tag'] == tag).firstOrNull;

  const both = SourceReplace(
    mode: ReplaceMode.both,
    tag: 'Pick',
    auto: DirectionAuto(interval: '15m', tolerance: 50),
  );

  test('both: автовыбор <tag>-auto, затем селектор tag с двойником первым',
      () async {
    final r = await build([sub(both), loose()]);
    expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
    final tags = [for (final o in outs(r)) o['tag']];
    expect(tags.indexOf('Pick-auto'), lessThan(tags.indexOf('Pick')),
        reason: 'внутри источника автовыбор раньше селектора');
    expect(tags.indexOf('A'), lessThan(tags.indexOf('Pick-auto')),
        reason: 'узлы раньше групп свёртки');
    expect(tags.indexOf('Pick'), lessThan(tags.indexOf('vpn-1')),
        reason: 'Направления после свёрток');

    final auto = byTag(r, 'Pick-auto')!;
    expect(auto['type'], 'urltest');
    expect(auto['outbounds'], ['A', 'B']);
    expect(auto['interval'], '15m');
    final sel = byTag(r, 'Pick')!;
    expect(sel['type'], 'selector');
    expect(sel['outbounds'], ['Pick-auto', 'A', 'B']);
    expect(sel['default'], 'Pick-auto');
    expect(sel['interrupt_exist_connections'], true);

    // Пул Направления: вместо узлов подписки — один кандидат `tag`.
    final vpn = byTag(r, 'vpn-1')!;
    expect(vpn['outbounds'], containsAll(['Pick', 'C']));
    expect(vpn['outbounds'], isNot(contains('A')));
    expect(vpn['outbounds'], isNot(contains('Pick-auto')));
    expect(byTag(r, 'vpn-1-auto')!['outbounds'], ['C'],
        reason: 'двойник Направления групп не берёт');
  });

  test('manual: только селектор tag, без default', () async {
    final r = await build(
        [sub(const SourceReplace(mode: ReplaceMode.manual, tag: 'Pick'))]);
    expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
    final sel = byTag(r, 'Pick')!;
    expect(sel['outbounds'], ['A', 'B']);
    expect(sel.containsKey('default'), isFalse);
    expect(byTag(r, 'Pick-auto'), isNull);
  });

  test('auto: автовыбор под самим tag', () async {
    final r = await build(
        [sub(const SourceReplace(mode: ReplaceMode.auto, tag: 'Pick'))]);
    expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
    expect(byTag(r, 'Pick')!['type'], 'urltest');
    expect(byTag(r, 'vpn-1')!['outbounds'], contains('Pick'));
  });

  test('все узлы выключены: групп нет, правило на свёртку — в route.final',
      () async {
    final off = DateTime.utc(2026, 9, 26);
    final r = await build(
      [sub(both, disabled: {'A': off, 'B': off}), loose()],
      rules: [
        CustomRuleInline(
          id: 'r1',
          name: 'Via Pick',
          domainSuffixes: const ['.example-2.com'],
          outbound: 'Pick',
        ),
      ],
      routeFinal: 'vpn-1',
    );
    expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
    expect(byTag(r, 'Pick'), isNull);
    expect(byTag(r, 'Pick-auto'), isNull);
    final rules = (r.config['route']['rules'] as List).cast<Map>();
    expect(rules.where((x) => x['outbound'] == 'Pick'), isEmpty);
    expect(r.emitWarnings.where((w) => w.contains('"Pick"')), isNotEmpty,
        reason: 'выпавшая группа называется, а не молчит');
  });

  // ── §570 (§568 хвосты, контракт 1.1.80) ──────────────────────────────────

  test('ноль узлов: один replace_group_empty на свёртку, у both тоже', () async {
    final off = DateTime.utc(2026, 9, 26);
    final r = await build([sub(both, disabled: {'A': off, 'B': off}), loose()]);
    final codes = r.buildCodes.where((w) => w.code == 'replace_group_empty');
    expect(codes, hasLength(1));
    expect(codes.single.params, {'tag': 'Pick', 'mode': 'both'});
  });

  test('тег свёртки = Направление: replace_tag_conflict, источник не свёрнут',
      () async {
    final r = await build([
      sub(const SourceReplace(mode: ReplaceMode.manual, tag: 'vpn-1')),
    ]);
    expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
    final c = r.buildCodes.singleWhere((w) => w.code == 'replace_tag_conflict');
    expect(c.params, {'tag': 'vpn-1', 'other': 'direction'});
    final vpn = byTag(r, 'vpn-1')!;
    expect(vpn['type'], 'selector');
    expect(vpn['outbounds'], containsAll(['A', 'B']),
        reason: 'узлы несвёрнутого источника идут в Направление сами');
    expect(outs(r).where((o) => o['tag'] == 'vpn-1'), hasLength(1));
  });

  test('конфликт имён: свёртка выше по списку и тег шаблона', () {
    SubscriptionServers s(String id, String tag) => SubscriptionServers(
          id: id,
          name: id,
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          url: 'https://example-1.com/$id',
          replace: SourceReplace(mode: ReplaceMode.manual, tag: tag),
        );
    final got = findReplaceTagConflicts(
      [s('a', 'X'), s('b', 'X'), s('c', 'block')],
      directionNames: const {},
      systemNames: const {'block'},
    );
    expect([for (final c in got) (c.listId, c.warning.params['other'])],
        [('b', 'replace'), ('c', 'system')]);
  });

  test('@имя в auto свёртки — переменная шаблона, без значения — умолчание',
      () {
    const a = DirectionAuto(url: '@u', interval: '@i', idleTimeout: '@none');
    final r = resolveAutoVars(a, (n) => {'u': 'https://e.example/204', 'i': '2m'}[n]);
    expect(r.url, 'https://e.example/204');
    expect(r.interval, '2m');
    expect(r.idleTimeout, const DirectionAuto().idleTimeout);
  });

  test('правило в логическом теле с целью-свёрткой — рекурсивно', () {
    final route = <String, dynamic>{
      'final': 'vpn-1',
      'rules': [
        {
          'type': 'logical',
          'mode': 'or',
          'rules': [
            {'domain': ['a.example.com'], 'outbound': 'Gone'},
            {'domain': ['b.example.com'], 'outbound': 'direct-out'},
          ],
          'outbound': 'Gone',
        },
        {
          'type': 'logical',
          'mode': 'and',
          'rules': [
            {'domain': ['c.example.com'], 'outbound': 'Gone'},
          ],
          'outbound': 'direct-out',
        },
      ],
    };
    final lines = retargetRulesOffDroppedReplaces(route, {'Gone'},
        liveFinals: {'vpn-1'});
    final rules = route['rules'] as List;
    expect(rules, hasLength(2));
    final first = rules[0] as Map;
    expect(first['outbound'], 'vpn-1');
    expect([for (final x in first['rules'] as List) (x as Map)['outbound']],
        ['vpn-1', 'direct-out']);
    expect((rules[1] as Map)['rules'], [
      {'domain': ['c.example.com'], 'outbound': 'vpn-1'},
    ]);
    expect(lines, hasLength(3));
  });

  test('detour на свёртку, опустевшую после отбраковок: носитель выпадает',
      () async {
    // Члены свёртки выпадают на втором проходе ссылок (их detour в никуда),
    // когда имя свёртки уже зарегистрировано корневой целью.
    final folded = SubscriptionServers(
      id: 's1',
      name: 'Provider',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults
          .copyWith(overrideDetour: const NodeLink(tag: 'nowhere')),
      url: 'https://example-1.com/sub',
      replace: both,
      nodes: [parseUri(uriA)!, parseUri(uriB)!],
    );
    final carrier = UserServer(
      id: 'u1',
      name: '',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults
          .copyWith(overrideDetour: const NodeLink(tag: 'Pick')),
      origin: UserSource.paste,
      nodes: [parseUri(uriC)!],
    );
    final r = await build([folded, carrier]);
    expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
    expect(byTag(r, 'Pick'), isNull);
    expect(byTag(r, 'C'), isNull,
        reason: 'носитель не идёт напрямую (fail-closed)');
    expect(r.emitWarnings.any((w) => w.contains('replace group "Pick"')),
        isTrue);
  });

  test('провайдерская группа в селекторе свёртки — на своём месте в модели',
      () async {
    final withGroup = SubscriptionServers(
      id: 's1',
      name: 'Provider',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      url: 'https://example-1.com/sub',
      replace: both,
      nodes: [
        parseUri(uriA)!,
        AutoSelectSpec(
          id: 'g1',
          tag: 'G',
          label: 'G',
          membership: const RuleMembers(include: '.'),
        ),
        parseUri(uriB)!,
      ],
    );
    final r = await build([withGroup]);
    expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
    expect(byTag(r, 'Pick')!['outbounds'], ['Pick-auto', 'A', 'G', 'B']);
    expect(byTag(r, 'Pick-auto')!['outbounds'], ['A', 'B'],
        reason: 'группа в автовыбор не идёт');
  });
}
