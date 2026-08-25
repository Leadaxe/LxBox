import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/screens/routing_screen/widgets/custom_rule_tile.dart';
import 'package:lxbox/services/rule_display_names.dart';

/// §279 Phase 2 (§3.5.1) — тайлы двух копий одного пресета рендерятся
/// РАЗЛИЧИМО: live-label + порядковый суффикс " (N)" у N-й копии.
/// Без дизамбигуации live-резолюция схлопнула бы оба тайла в один текст.
void main() {
  final template = WizardTemplate.fromJson({
    'selectable_rules': [
      {
        'preset_id': 'block-ads',
        'ui': {'label': 'Block Ads'},
        'rule': {'rule_set': 'geosite-ads', 'action': 'reject'},
        'rule_set': [
          {
            'type': 'remote',
            'tag': 'geosite-ads',
            'url': 'https://example.com/ads.srs',
          },
        ],
      },
    ],
  });

  Widget tile(int index, List<CustomRule> rules) => CustomRuleTile(
        key: ValueKey('tile-$index'),
        index: index,
        rule: rules[index],
        displayName: ruleDisplayName(rules[index], rules, template),
        options: const [],
        subtitle: 'Tap to edit',
        pickerValue: '',
        pickerDisabled: false,
        showOutbound: false,
        statusButton: null,
        onTap: () {},
        onLongPressStart: (_) {},
        onSwitchChanged: (_) {},
        onOutboundChanged: (_) {},
      );

  testWidgets('две копии одного пресета различимы (bare + " (2)")',
      (tester) async {
    final rules = <CustomRule>[
      // Оба снапшота идентичны — различает только live-ordinal.
      CustomRulePreset(name: 'Block Ads', presetId: 'block-ads'),
      CustomRulePreset(name: 'Block Ads', presetId: 'block-ads'),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReorderableListView.builder(
          buildDefaultDragHandles: false,
          itemCount: rules.length,
          onReorderItem: (_, _) {},
          itemBuilder: (ctx, i) => tile(i, rules),
        ),
      ),
    ));

    expect(find.text('Block Ads'), findsOneWidget);
    expect(find.text('Block Ads (2)'), findsOneWidget);
  });

  testWidgets('одиночный пресет — live-label без суффикса, снапшот не виден',
      (tester) async {
    final rules = <CustomRule>[
      CustomRulePreset(name: 'Stale Snapshot', presetId: 'block-ads'),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReorderableListView.builder(
          buildDefaultDragHandles: false,
          itemCount: rules.length,
          onReorderItem: (_, _) {},
          itemBuilder: (ctx, i) => tile(i, rules),
        ),
      ),
    ));

    expect(find.text('Block Ads'), findsOneWidget);
    expect(find.text('Stale Snapshot'), findsNothing);
  });
}
