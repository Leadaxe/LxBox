// Фича 478 — ревью после v2.25.1, H1: тег между кругами переезжает к тёзке.
//
// Два узла подписки с одним именем получают теги `Dup` и `Dup-1`
// (`allocateTag`). Стоит выключить первого — пересборка отдаёт второму уже
// литеральный `Dup`. Защита от зацикливания по СТРОКЕ тега принимала это за
// «тот же тег повторно» и обрывала прогон на втором же негодном: VPN не
// поднимался, выключался один узел за нажатие Start.
//
// Хост здесь — поддельное ядро поверх НАСТОЯЩЕЙ сборки (`buildConfig`), чтобы
// динамика тегов была та же, что на устройстве, а не придуманная в тесте.
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/config/consts.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart'
    show
        WizardTemplate,
        ParserConfigBlock,
        GroupTemplates,
        DirectionTemplate,
        AutoTemplate,
        DefaultDirection;
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/core_reject/core_reject_guard.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import '../parser/engine_test_setup.dart';

final _template = WizardTemplate(
  parserConfig: ParserConfigBlock(),
  groupTemplates: GroupTemplates(
    direction: DirectionTemplate(
      include: const ['direct', 'auto'],
      options: const {'interrupt_exist_connections': true},
    ),
    auto: AutoTemplate(options: const {'url': 'https://x', 'interval': '30s'}),
    defaultDirections: [
      DefaultDirection(tag: 'vpn-1', label: 'vpn-1', defaultEnabled: true),
    ],
  ),
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

/// Ядро, которое отвергает конфиг, пока в нём есть хоть один негодный узел, и
/// называет его ТЕМ тегом, который выдала текущая сборка.
class _RealBuildCore implements CoreRejectHost {
  _RealBuildCore(this.nodes, this.bad);

  final List<NodeSpec> nodes;

  /// Негодные узлы — по идентичности объекта, не по тегу.
  final Set<NodeSpec> bad;

  final disabled = <NodeSpec>[];
  var realStarts = 0;
  var checks = 0;
  Map<String, NodeSpec> _lastMap = const {};

  late final Map<NodeSpec, String> _identities = sourceNodeIdentities(nodes);

  List<NodeSpec> get _live =>
      nodes.where((n) => !disabled.any((d) => identical(d, n))).toList();

  Future<Map<String, NodeSpec>> _build() async {
    final list = SubscriptionServers(
      id: 's1',
      name: 'Sub',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      url: 'https://example.com/sub',
      nodes: _live,
    );
    final r = await buildConfig(
      lists: [list],
      template: _template,
      settings: const BuildSettings(
        userVars: {'clash_api': '127.0.0.1:9090'},
        enabledGroups: {'vpn-1', kAutoOutboundTag},
      ),
    );
    return _lastMap = r.nodeByEmittedTag;
  }

  Future<String?> _reject() async {
    final map = await _build();
    for (final n in _live) {
      if (!bad.any((b) => identical(b, n))) continue;
      final tag =
          map.entries.firstWhere((e) => identical(e.value, n)).key;
      return 'initialize outbound[0] vless[$tag]: bad ${_identities[n]}';
    }
    return null;
  }

  @override
  Future<CoreAttempt> realStart() async {
    realStarts++;
    final e = await _reject();
    return e == null ? const CoreAttempt.accepted() : CoreAttempt.rejected(e);
  }

  @override
  Future<RebuiltConfig?> rebuild() async {
    final map = await _build();
    return RebuiltConfig(configJson: '{}', tags: map.keys.toSet());
  }

  @override
  Future<CoreAttempt> check(String configJson) async {
    checks++;
    final e = await _reject();
    return e == null ? const CoreAttempt.accepted() : CoreAttempt.rejected(e);
  }

  @override
  Future<CoreRejectNodeRef?> disableNode(String tag, String reason) async {
    final node = _lastMap[tag];
    if (node == null) return null;
    if (!disabled.any((d) => identical(d, node))) disabled.add(node);
    return CoreRejectNodeRef(sourceId: 's1', nodeKey: _identities[node]!);
  }

  @override
  Future<CoreRejectPrompt> askKeepChecking(int n) async =>
      CoreRejectPrompt.stop;

  @override
  void onProgress(
    CoreRejectPhase phase,
    int round, {
    List<DisabledNode> disabledNodes = const [],
  }) {}
}

void main() {
  setUpAll(loadEngineSections);

  NodeSpec dup(String uuid, String host) => parseUri(
      'vless://$uuid@$host:443?type=ws&security=tls#Dup')!;

  test('динамика сборки: Dup/Dup-1, без первого второму достаётся Dup',
      () async {
    final a = dup('11111111-1111-1111-1111-111111111111', 'a.example');
    final b = dup('22222222-2222-2222-2222-222222222222', 'b.example');
    final core = _RealBuildCore([a, b], {});

    final both = await core._build();
    expect(identical(both['Dup'], a), isTrue);
    expect(identical(both['Dup-1'], b), isTrue);

    core.disabled.add(a);
    final onlyB = await core._build();
    expect(identical(onlyB['Dup'], b), isTrue,
        reason: 'тег Dup переехал ко второму узлу — на этом и ломалась '
            'защита по строке тега');
  });

  test('H1: два негодных тёзки → оба выключены за один прогон, VPN поднят',
      () async {
    final a = dup('11111111-1111-1111-1111-111111111111', 'a.example');
    final b = dup('22222222-2222-2222-2222-222222222222', 'b.example');
    final good = parseUri(
        'vless://33333333-3333-3333-3333-333333333333@c.example:443?type=ws&security=tls#Good')!;
    final core = _RealBuildCore([a, b, good], {a, b});

    final run = await CoreRejectGuard(core).run();

    expect(run.outcome, CoreRejectOutcome.startedWithDisabled,
        reason: 'ошибка: ${run.error}');
    expect(core.disabled.length, 2);
    expect(core.disabled.any((n) => identical(n, a)), isTrue);
    expect(core.disabled.any((n) => identical(n, b)), isTrue);
    expect(run.disabled.map((d) => d.tag), ['Dup', 'Dup'],
        reason: 'ядро оба раза назвало литеральный Dup — это разные узлы');
    expect(run.disabled.map((d) => d.ref).toSet().length, 2);
    expect(core.realStarts, 2, reason: 'сигнальный + финальный');
  });
}
