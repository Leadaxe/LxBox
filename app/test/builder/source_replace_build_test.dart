import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_replace.dart';
import 'package:lxbox/services/builder/build_config.dart';
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
}
