import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/probe/probe_detour.dart';
import 'package:lxbox/widgets/probe_detour_note.dart';

/// §738 — тексты пометки §730: владельца detour пометка не называет.
NodeSpec _node(String label) => VlessSpec(
      id: label,
      tag: label,
      label: label,
      server: '${label.toLowerCase()}.example.com',
      port: 443,
      rawSource: '',
      uuid: '00000000-0000-0000-0000-000000000000',
    );

ProbeDetourRoute _applied(String label) =>
    ProbeDetourRoute.applied(target: _node(label), replace: false, targetLabel: label);

void main() {
  test('detour не задан — пометки нет', () {
    expect(probeDetourNoteText(ProbeDetourPlan.empty), isNull);
  });

  test('один узел, detour не учтён — единственное число, без «of this source»',
      () {
    final text = probeDetourNoteText(
        ProbeDetourPlan.single(const ProbeDetourRoute.unapplied()));
    expect(text,
        'Detour is not applied in the test — the node is checked directly.');
  });

  test('несколько узлов, detour не учтён — множественное число', () {
    final text = probeDetourNoteText(const ProbeDetourPlan({
      0: ProbeDetourRoute.unapplied(),
      1: ProbeDetourRoute.unapplied(),
    }));
    expect(text,
        'Detour is not applied in the test — nodes are checked directly.');
  });

  test('учтён через одну цель и смешанный случай — прежние тексты', () {
    expect(probeDetourNoteText(ProbeDetourPlan({0: _applied('J')})),
        'Tested through J.');
    expect(
        probeDetourNoteText(ProbeDetourPlan({
          0: _applied('J'),
          1: const ProbeDetourRoute.unapplied(),
        })),
        'Detour is applied in the test for 1 of 2; the others are checked directly.');
  });
}
