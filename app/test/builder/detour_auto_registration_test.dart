import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/builder/server_list_build.dart';

import '../parser/engine_test_setup.dart';

/// §670 — галка «Register detour in auto group»: звено цепочки в
/// `<tag>-auto` Направления только вместе с «Register detour servers».
/// Проверяется итоговый конфиг `buildConfig`, а не вызовы `addToAutoList`.
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

  // Папка: `exit` ходит через `hop` — член той же папки, значит `hop` —
  // звено цепочки (isChainLink).
  FolderServers chainFolder(DetourPolicy policy) => FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: policy,
        members: [
          FolderMember(raw: 'vless://u1@h1.com:443?type=ws&security=tls#hop'),
          FolderMember(
              raw: 'vless://u2@h2.com:443?type=ws&security=tls#exit',
              detour: const NodeLink(folderId: 'f1', tag: 'hop')),
        ],
      );

  Future<Map<String, List<String>>> groups(DetourPolicy policy) async {
    final r = await buildConfig(
      lists: [chainFolder(policy)],
      template: template(),
      settings: const BuildSettings(directions: [
        Direction(tag: 'vpn-1', label: 'Main', auto: DirectionAuto()),
      ]),
    );
    expect(r.validation.isOk, true, reason: r.validation.issues.join('\n'));
    final outs = (r.config['outbounds'] as List).cast<Map<String, dynamic>>();
    List<String> members(String tag) => [
          for (final o in outs)
            if (o['tag'] == tag) ...(o['outbounds'] as List).cast<String>(),
        ];
    return {'vpn-1': members('vpn-1'), 'vpn-1-auto': members('vpn-1-auto')};
  }

  group('матрица register-галок → vpn-1 / vpn-1-auto', () {
    test('off/off — звено только хоп', () async {
      final g = await groups(const DetourPolicy());
      expect(g['vpn-1'], isNot(contains('hop')));
      expect(g['vpn-1'], contains('exit'));
      expect(g['vpn-1-auto'], ['exit']);
    });

    test('on/off — в селекторе, не в -auto', () async {
      final g = await groups(const DetourPolicy(registerDetourServers: true));
      expect(g['vpn-1'], containsAll(['hop', 'exit']));
      expect(g['vpn-1-auto'], ['exit']);
    });

    test('on/on — в обоих', () async {
      final g = await groups(const DetourPolicy(
          registerDetourServers: true, registerDetourInAuto: true));
      expect(g['vpn-1'], containsAll(['hop', 'exit']));
      expect(g['vpn-1-auto'], ['hop', 'exit']);
    });

    test('off/on — нет в селекторе, значит и в -auto', () async {
      final g = await groups(const DetourPolicy(registerDetourInAuto: true));
      expect(g['vpn-1'], isNot(contains('hop')));
      expect(g['vpn-1-auto'], ['exit']);
    });
  });

  group('folderHasDetourLinks — показ галок у папки', () {
    test('личный detour на узел вне папки — звена нет', () {
      final f = FolderServers(
        id: 'f1',
        name: 'F',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: [
          FolderMember(
              raw: 'vless://u1@h1.com:443?type=ws&security=tls#a',
              detour: const NodeLink(tag: 'WARP')),
          FolderMember(
              raw: 'vless://u2@h2.com:443?type=ws&security=tls#b',
              detour: const NodeLink(folderId: 'sub1', tag: 'node')),
        ],
      );
      expect(folderHasDetourLinks(f), isFalse);
    });

    test('личный detour на члена этой папки — звено есть', () {
      expect(folderHasDetourLinks(chainFolder(DetourPolicy.defaults)), isTrue);
    });
  });
}
