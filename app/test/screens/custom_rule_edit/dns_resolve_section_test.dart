import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/screens/custom_rule_edit_screen.dart';
import 'package:lxbox/widgets/outbound_picker.dart';

// §683 — секция DNS & Resolve: поле Fixed IP блокирует Save при
// неразбираемой строке, годные адреса уходят в RuleDns.fixedIps; Resolve
// only выбирается в Action и ставит resolve.only. Проверяется поведение,
// не тексты (AGENTS.md).

class _Host {
  CustomRuleEditResult? result;
  bool closed = false;
}

Future<_Host> _open(WidgetTester tester, CustomRule initial) async {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final host = _Host();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async {
            host.result = await openCustomRuleEditor(
              context,
              initial: initial,
              outboundOptions: const [
                OutboundOption(value: 'direct-out', label: 'direct-out'),
              ],
              existingNames: const {},
            );
            host.closed = true;
          },
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return host;
}

Finder get _appBarSave => find.descendant(
      of: find.byType(AppBar),
      matching: find.widgetWithIcon(IconButton, Icons.save),
    );

CustomRuleInline _rule({List<String> ips = const ['192.168.1.10']}) =>
    CustomRuleInline(
      id: 'r1',
      name: 'nas',
      domains: const ['nas.home'],
      outbound: 'direct-out',
      dns: RuleDns(fixed: true, fixedIps: ips),
    );

Finder get _fixedField => find.byWidgetPredicate((w) =>
    w is TextField && w.decoration?.hintText == '192.168.1.10');

void main() {
  testWidgets('битая строка Fixed IP блокирует Save', (tester) async {
    final host = await _open(tester, _rule());
    await tester.enterText(_fixedField, '192.168.1.10\nnot-an-ip');
    await tester.pump();

    expect(tester.widget<IconButton>(_appBarSave).onPressed, isNull);
    await tester.tap(_appBarSave, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(host.closed, isFalse);
  });

  testWidgets('годные адреса сохраняются в fixedIps', (tester) async {
    final host = await _open(tester, _rule());
    await tester.enterText(_fixedField, '10.0.0.1\n\nfd00::1');
    await tester.pump();

    await tester.tap(_appBarSave);
    await tester.pumpAndSettle();
    expect(host.closed, isTrue);
    final dns = host.result!.saved!.dns!;
    expect(dns.fixedMode, isTrue);
    expect(dns.fixedIps, ['10.0.0.1', 'fd00::1']);
  });

  testWidgets('Resolve only в Action ставит resolve.only, направление цело',
      (tester) async {
    final host = await _open(tester, _rule());
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.travel_explore).last);
    await tester.pumpAndSettle();

    await tester.tap(_appBarSave);
    await tester.pumpAndSettle();
    final saved = host.result!.saved!;
    expect(saved.resolve?.only, isTrue);
    expect(saved.outbound, 'direct-out');
  });
}
