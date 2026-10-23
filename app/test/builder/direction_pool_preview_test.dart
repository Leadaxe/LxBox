import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller/cache_rehydrate.dart'
    show ParseEnvSnapshot;
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/builder/direction_pool_preview.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import '../parser/engine_test_setup.dart';

/// §674 — превью фильтра Направления берёт пул у сборщика, а не у ядра:
/// пул, отфильтрованный фильтром Направления, равен составу `<tag>` в
/// собранном конфиге за вычетом служебных опций (`<tag>-auto`, direct-out,
/// block, ссылки на другие Направления). Туннель для этого не нужен.
void main() {
  setUpAll(loadEngineSections);

  WizardTemplate template() => WizardTemplate(
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

  UserServer nodes() => UserServer(
        id: 'u',
        name: 'N',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.paste,
        nodes: [
          parseUri('vless://u1@h1.com:443?type=ws&security=tls#🇩🇪 Berlin')!,
          parseUri('vless://u2@h2.com:443?type=ws&security=tls#🇩🇪 Premium')!,
          parseUri('vless://u3@h3.com:443?type=ws&security=tls#🇳🇱 Amsterdam')!,
          parseUri('vless://u4@h4.com:443?type=ws&security=tls#🇺🇸 NYC')!,
        ],
      );

  final directions = [
    Direction(tag: 'vpn-1', label: 'Main', includeDirect: true),
    Direction(
      tag: 'vpn-2',
      label: 'DE',
      nodeFilter: '🇩🇪',
      include: const ['vpn-1'],
      auto: const DirectionAuto(),
    ),
    Direction(
      tag: 'vpn-3',
      label: 'Not DE',
      nodeFilter: '🇩🇪',
      nodeFilterInvert: true,
      includeBlock: true,
    ),
  ];

  /// Узлы селектора `<tag>` собранного конфига: состав минус служебные
  /// опции — то, что показывает превью.
  Future<Map<String, List<String>>> selectorNodes() async {
    final r = await buildConfig(
      lists: [nodes()],
      template: template(),
      settings: BuildSettings(directions: directions),
    );
    expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
    final service = {
      'direct-out',
      'block',
      for (final d in directions) ...[d.tag, d.autoTag],
    };
    return {
      for (final o in (r.config['outbounds'] as List)
          .cast<Map<String, dynamic>>())
        if (o['type'] == 'selector' &&
            directions.any((d) => d.tag == o['tag']))
          o['tag'] as String: [
            for (final t in (o['outbounds'] as List).cast<String>())
              if (!service.contains(t)) t,
          ],
    };
  }

  test('пул по фильтру = состав <tag> в собранном конфиге', () async {
    final pool = await buildDirectionPool(
      lists: [nodes()],
      template: template(),
      settings: BuildSettings(directions: directions),
    );
    expect(pool, hasLength(4));
    final built = await selectorNodes();
    for (final d in directions) {
      expect(d.filterNodeTags(pool), built[d.tag], reason: d.tag);
    }
    // Фильтр реально отбирает: DE — два узла, инверсия — остальные два.
    expect(built['vpn-2'], hasLength(2));
    expect(built['vpn-3'], hasLength(2));
  });

  test('пул в isolate совпадает с пулом на main', () async {
    final input = DirectionPoolInput(
      lists: [nodes()],
      settings: BuildSettings(directions: directions),
      template: template(),
    );
    final env = ParseEnvSnapshot.capture();
    final inWorker = await Isolate.run(() async {
      await env.install();
      return input.run();
    });
    expect(inWorker, await input.run());
  });
}
