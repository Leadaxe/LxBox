import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/subscription_detail_screen/detour_mode.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/subscription_settings_tab.dart';

/// §393 A6 — ЛОВУШКА, из-за которой каскад нельзя вешать на `onChanged`.
///
/// Поле «Prefix» стреляет `onChanged` на КАЖДОЕ нажатие клавиши. Если бы
/// каскад считался там, набор `DE:` поверх `RU:` прогнал бы серию правок
/// `RU:`→`R`, `R`→`RU`… и перемолол бы regex-фильтры Направлений в фарш за
/// несколько символов (каждая правка чинила бы фильтр под очередной огрызок).
///
/// Поэтому каскад висит на `onTagPrefixCommitted` — уход фокуса / submit.
/// Тест закрепляет именно это разделение.
void main() {
  SubscriptionEntry makeEntry(String prefix) => SubscriptionEntry(
        list: SubscriptionServers(
          id: 'sub-1',
          name: 'Sub',
          enabled: true,
          tagPrefix: prefix,
          detourPolicy: DetourPolicy.defaults,
          url: 'https://example.com/sub',
        ),
      );

  Widget host(
    SubscriptionEntry entry, {
    required ValueChanged<String> onChanged,
    required ValueChanged<String> onCommitted,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: SubscriptionSettingsTab(
            entry: entry,
            hasDetour: false,
            detourMode: DetourMode.use,
            onTagPrefixChanged: onChanged,
            onTagPrefixCommitted: onCommitted,
            onSetDetourMode: (_) {},
            onRegisterDetourServersChanged: (_) {},
            onRegisterDetourInAutoChanged: (_) {},
            onShowOverrideDetourPicker: () {},
            onReplaceDetourChainChanged: (_) {},
            onCopyUrl: () {},
            onShowIntervalPicker: () {},
            onShowOnUpdateActionPicker: () {},
            onRefreshNow: () {},
            onEditSource: () {},
          ),
        ),
      );

  testWidgets('набор символов НЕ коммитит префикс (каскад молчит)',
      (tester) async {
    final entry = makeEntry('RU:');
    final changed = <String>[];
    final committed = <String>[];
    await tester.pumpWidget(host(entry,
        onChanged: (v) {
          changed.add(v);
          entry.tagPrefix = v.trim();
        },
        onCommitted: committed.add));

    final field = find.byType(TextFormField);
    await tester.enterText(field, 'D');
    await tester.enterText(field, 'DE');
    await tester.enterText(field, 'DE:');
    await tester.pump();

    expect(changed, ['D', 'DE', 'DE:'], reason: 'onChanged — на клавишу');
    expect(committed, isEmpty,
        reason: 'промежуточные огрызки не должны запускать каскад');
  });

  testWidgets('уход фокуса коммитит один раз, финальным значением',
      (tester) async {
    final entry = makeEntry('RU:');
    final committed = <String>[];
    await tester.pumpWidget(host(entry,
        onChanged: (v) => entry.tagPrefix = v.trim(),
        onCommitted: committed.add));

    final field = find.byType(TextFormField);
    await tester.enterText(field, 'D');
    await tester.enterText(field, 'DE:');
    // Фокус уходит с поля — «допечатал».
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    expect(committed, ['DE:']);
  });

  testWidgets('submit клавиатуры коммитит РОВНО один раз', (tester) async {
    // Регрессия: свой onFieldSubmitted рядом с Focus давал два вызова на одно
    // событие (submit снимает фокус сам). Каскад идемпотентен, но лишний
    // прогон по всем Направлениям на каждый submit — не бесплатен.
    final entry = makeEntry('RU:');
    final committed = <String>[];
    await tester.pumpWidget(host(entry,
        onChanged: (v) => entry.tagPrefix = v.trim(),
        onCommitted: committed.add));

    await tester.enterText(find.byType(TextFormField), 'DE: ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(committed, ['DE:'], reason: 'submit отдаёт trim-нутое значение');
  });
}
