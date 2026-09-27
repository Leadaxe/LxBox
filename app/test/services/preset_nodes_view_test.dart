import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/preset_nodes_view.dart';

/// §578 — узлы для пресетов с `for_each` на экранах, обслуживаемые узлы
/// строки пресета и видимость переключателя `Skip presets`.
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
        skipPresets: skip,
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
          FolderMember(raw: ts('work-ts').toUri(), skipPresets: true),
        ]),
        sub([ts('sub-ts')]),
      ], nodeTypes: types);
      expect([for (final n in nodes) n.skipPresets], [true, true, false]);
    });

    test('финальный тег последней сборки побеждает отображаемый', () {
      final node = ts('home-ts');
      final nodes = presetNodesForView([user(node)],
          nodeTypes: types, lastEmittedTagMap: {'home-ts-1': node});
      expect(nodes.single.tag, 'home-ts-1');
    });

    test('нет типов for_each — пусто', () {
      expect(presetNodesForView([user(ts('a'))], nodeTypes: const {}),
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

    test('узлов нет — пустой список; пресет без for_each — null', () {
      expect(presetServedTags(rule, tsPreset, const []), isEmpty);
      final plain = presets.firstWhere((p) => p.forEach == null);
      final plainRule = CustomRulePreset(
          name: plain.label, presetId: plain.presetId, orderNum: 1);
      expect(presetServedTags(plainRule, plain, const []), isNull);
    });
  });

  group('skipPresetsToggleVisible', () {
    test('свой сервер и член папки с типом пресета — виден', () {
      expect(
          skipPresetsToggleVisible(
              list: user(ts('a')),
              isMember: false,
              nodeType: 'tailscale',
              presets: presets),
          isTrue);
      expect(
          skipPresetsToggleVisible(
              list: folder([FolderMember(raw: ts('a').toUri())]),
              isMember: true,
              nodeType: 'tailscale',
              presets: presets),
          isTrue);
    });

    test('подписка, другой тип, шаблон без for_each — не виден', () {
      expect(
          skipPresetsToggleVisible(
              list: sub([ts('a')]),
              isMember: false,
              nodeType: 'tailscale',
              presets: presets),
          isFalse);
      expect(
          skipPresetsToggleVisible(
              list: user(ts('a')),
              isMember: false,
              nodeType: 'vless',
              presets: presets),
          isFalse);
      expect(
          skipPresetsToggleVisible(
              list: user(ts('a')),
              isMember: false,
              nodeType: 'tailscale',
              presets: [
                for (final p in presets)
                  if (p.forEach == null) p
              ]),
          isFalse);
    });
  });
}
