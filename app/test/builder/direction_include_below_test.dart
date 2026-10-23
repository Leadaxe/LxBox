import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import '../parser/engine_test_setup.dart';

/// §673 — последний гард сборщика. UI и Debug API порядок или `include`,
/// ставящие ссылку «Other directions» на Направление НИЖЕ, не пропускают;
/// такие данные приходят только из старого бэкапа. Сборка на них не
/// роняется: ссылку не эмитит (UX-правило 026 «только выше»; ядру порядок
/// безразличен), пишет предупреждение, остальной состав цел.
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
          parseUri('vless://u2@h2.com:443?type=ws&security=tls#🇳🇱 Amsterdam')!,
        ],
      );

  test('include на Направление ниже: сборка цела, ссылка снята с предупреждением',
      () async {
    // vpn-2 стоит выше своей цели vpn-1 — как в старом бэкапе.
    final r = await buildConfig(
      lists: [nodes()],
      template: template(),
      settings: const BuildSettings(directions: [
        Direction(tag: 'vpn-2', label: 'DE', include: ['vpn-1']),
        Direction(tag: 'vpn-1', label: 'Main'),
      ]),
    );
    expect(r.validation.isOk, isTrue, reason: r.validation.issues.join('\n'));
    final outs = (r.config['outbounds'] as List).cast<Map<String, dynamic>>();
    final tags = [for (final o in outs) o['tag']];
    // Порядок групп в конфиге — новый порядок списка.
    expect(tags.indexOf('vpn-2'), lessThan(tags.indexOf('vpn-1')));
    final vpn2 = outs.firstWhere((o) => o['tag'] == 'vpn-2');
    expect(vpn2['outbounds'], isNot(contains('vpn-1')));
    expect(vpn2['outbounds'], hasLength(2), reason: 'узлы остались в составе');
    expect(
      r.emitWarnings,
      contains(contains('option "vpn-1" dropped — it must be another '
          'direction listed above this one')),
    );
  });

  test('та же ссылка вверх — эмитится без предупреждения', () async {
    final r = await buildConfig(
      lists: [nodes()],
      template: template(),
      settings: const BuildSettings(directions: [
        Direction(tag: 'vpn-1', label: 'Main'),
        Direction(tag: 'vpn-2', label: 'DE', include: ['vpn-1']),
      ]),
    );
    final outs = (r.config['outbounds'] as List).cast<Map<String, dynamic>>();
    final vpn2 = outs.firstWhere((o) => o['tag'] == 'vpn-2');
    expect(vpn2['outbounds'], contains('vpn-1'));
    expect(r.emitWarnings.where((w) => w.contains('dropped')), isEmpty);
  });
}
