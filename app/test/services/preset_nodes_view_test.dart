import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/preset_nodes_view.dart';

/// §578/§643 — узлы для пресетов с обходом узлов на экранах, обслуживаемые узлы
/// строки пресета и видимость переключателя `Skip Tailscale presets`.
void main() {
  final shipped = jsonDecode(
          File('assets/wizard_template.json').readAsStringSync())
      as Map<String, dynamic>;
  final presets = [
    for (final r in (shipped['selectable_rules'] as List)
        .cast<Map<String, dynamic>>())
      SelectableRule.fromJson(r),
  ];
  final tsPreset = presets.singleWhere((p) => p.presetId == 'tailscale');
  final rule = CustomRulePreset(
      name: 'Tailscale networks', presetId: 'tailscale', orderNum: 945);

  TailscaleSpec ts(String tag) => TailscaleSpec(
        id: 'ts-$tag',
        tag: tag,
        label: tag,
        body: {'auth_key': 'tskey'},
      );

  UserServer user(NodeSpec node, {bool enabled = true, bool skip = false}) =>
      UserServer(
        id: 'u-${node.tag}',
        name: '',
        enabled: enabled,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: node.toUri(),
        skipTailscalePresets: skip,
        nodes: [node],
      );

  FolderServers folder(List<FolderMember> members, {bool enabled = true}) =>
      FolderServers(
        id: 'f1',
        name: 'F',
        enabled: enabled,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        members: members,
      );

  SubscriptionServers sub(List<NodeSpec> nodes,
          {Map<String, DateTime> disabled = const {}}) =>
      SubscriptionServers(
        id: 's1',
        name: 'S',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        url: 'https://example.com/sub',
        disabledHashes: disabled,
        nodes: nodes,
      );

  const types = {'tailscale'};

  group('presetNodesForView', () {
    test('свой сервер, член папки, подписка — порядок источников', () {
      final nodes = presetNodesForView([
        user(ts('home-ts')),
        folder([FolderMember(raw: ts('work-ts').toUri())]),
        sub([ts('sub-ts')]),
      ], nodeTypes: types);
      expect([for (final n in nodes) n.tag], ['home-ts', 'work-ts', 'sub-ts']);
      expect(nodes.every((n) => n.body['type'] == 'tailscale'), isTrue);
    });

    test('выключенные источник, член, узел подписки не входят', () {
      final subNodes = [ts('sub-a'), ts('sub-b')];
      final idA = sourceNodeIdentities(subNodes)[subNodes.first]!;
      final nodes = presetNodesForView([
        user(ts('off-ts'), enabled: false),
        folder([FolderMember(raw: ts('m-ts').toUri(), enabled: false)]),
        folder([FolderMember(raw: ts('f-ts').toUri())], enabled: false),
        sub(subNodes, disabled: {idA: DateTime(2026)}),
      ], nodeTypes: types);
      expect([for (final n in nodes) n.tag], ['sub-b']);
    });

    test('skip_presets из записи; у подписки всегда false', () {
      final nodes = presetNodesForView([
        user(ts('home-ts'), skip: true),
        folder([
          FolderMember(raw: ts('work-ts').toUri(), skipTailscalePresets: true),
        ]),
        sub([ts('sub-ts')]),
      ], nodeTypes: types);
      expect([for (final n in nodes) n.skipTailscalePresets], [true, true, false]);
    });

    test('финальный тег последней сборки побеждает отображаемый', () {
      final node = ts('home-ts');
      final nodes = presetNodesForView([user(node)],
          nodeTypes: types, lastEmittedTagMap: {'home-ts-1': node});
      expect(nodes.single.tag, 'home-ts-1');
    });

    test('нет пресетов с обходом — пусто; null — узлы любого типа', () {
      expect(presetNodesForView([user(ts('a'))], nodeTypes: const {}),
          isEmpty);
      expect(presetNodesForView([user(ts('a'))], nodeTypes: null)
          .map((n) => n.tag), ['a']);
    });

    test('типы шаблона — сужение #filter пресетов tailscale и tunnel-ingress',
        () {
      // §656 — `tunnel-ingress` обходит wireguard / openvpn-client /
      // openconnect.
      expect(presetLoopNodeTypes(presets),
          {...types, 'wireguard', 'openvpn-client', 'openconnect'});
      expect(
          presetLoopNodeTypes([
            for (final p in presets)
              if (p.nodeLoop == null) p
          ]),
          isEmpty);
    });
  });

  group('presetServedTags', () {
    test('узлы пресета: skip_presets отсекает, прочие типы не входят', () {
      final nodes = presetNodesForView([
        user(ts('home-ts')),
        user(ts('skip-ts'), skip: true),
        user(ts('work-ts')),
      ], nodeTypes: types);
      expect(presetServedTags(rule, tsPreset, nodes), ['home-ts', 'work-ts']);
    });

    test('узлов нет — пустой список; пресет без обхода — null', () {
      expect(presetServedTags(rule, tsPreset, const []), isEmpty);
      final plain = presets.firstWhere((p) => p.nodeLoop == null);
      final plainRule = CustomRulePreset(
          name: plain.label, presetId: plain.presetId, orderNum: 1);
      expect(presetServedTags(plainRule, plain, const []), isNull);
    });
  });

  // §643 — видимость: есть пресет с обходом, чей `#filter` истинен для узла
  // при `skip_presets = false`.
  const tsBody = {'type': 'tailscale', 'tag': 'a'};
  const vlessBody = {'type': 'vless', 'tag': 'v', 'server': 'v.example'};
  const wgBody = {'type': 'wireguard', 'tag': 'w'};

  group('skipTailscalePresetsToggleVisible', () {
    test('свой сервер и член папки, #filter принимает узел — виден', () {
      expect(
          skipTailscalePresetsToggleVisible(
              list: user(ts('a')),
              isMember: false,
              nodeTag: 'a',
              nodeBody: tsBody,
              presets: presets),
          isTrue);
      expect(
          skipTailscalePresetsToggleVisible(
              list: folder([FolderMember(raw: ts('a').toUri())]),
              isMember: true,
              nodeTag: 'a',
              nodeBody: tsBody,
              presets: presets),
          isTrue);
    });

    test('подписка, узел вне #filter, шаблон без обхода — не виден', () {
      expect(
          skipTailscalePresetsToggleVisible(
              list: sub([ts('a')]),
              isMember: false,
              nodeTag: 'a',
              nodeBody: tsBody,
              presets: presets),
          isFalse);
      expect(
          skipTailscalePresetsToggleVisible(
              list: user(ts('a')),
              isMember: false,
              nodeTag: 'v',
              nodeBody: vlessBody,
              presets: presets),
          isFalse);
      expect(
          skipTailscalePresetsToggleVisible(
              list: user(ts('a')),
              isMember: false,
              nodeTag: 'a',
              nodeBody: tsBody,
              presets: [
                for (final p in presets)
                  if (p.nodeLoop == null) p
              ]),
          isFalse);
    });

    test('§656: WireGuard (его берёт tunnel-ingress) — не виден', () {
      expect(
          skipTailscalePresetsToggleVisible(
              list: user(ts('a')),
              isMember: false,
              nodeTag: 'w',
              nodeBody: wgBody,
              presets: presets),
          isFalse);
    });
  });

  // §656 — блок `Incoming connections from this tunnel`: свой сервер и член
  // папки с типом из трёх; у подписки и у tailscale — нет.
  group('tunnelIngressTogglesVisible', () {
    test('wireguard / openvpn-client / openconnect у своей записи — виден', () {
      for (final type in ['wireguard', 'openvpn-client', 'openconnect']) {
        expect(
            tunnelIngressTogglesVisible(
                list: user(ts('a')),
                isMember: false,
                nodeBody: {'type': type}),
            isTrue,
            reason: type);
        expect(
            tunnelIngressTogglesVisible(
                list: folder([FolderMember(raw: ts('a').toUri())]),
                isMember: true,
                nodeBody: {'type': type}),
            isTrue,
            reason: type);
      }
    });

    test('подписка, tailscale, vless — не виден', () {
      expect(
          tunnelIngressTogglesVisible(
              list: sub([ts('a')]), isMember: false, nodeBody: wgBody),
          isFalse);
      expect(
          tunnelIngressTogglesVisible(
              list: user(ts('a')), isMember: false, nodeBody: tsBody),
          isFalse);
      expect(
          tunnelIngressTogglesVisible(
              list: user(ts('a')), isMember: false, nodeBody: vlessBody),
          isFalse);
    });
  });
}
