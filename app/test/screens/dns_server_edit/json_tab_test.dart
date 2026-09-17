import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/screens/dns_server_edit/edit_controller.dart';
import 'package:lxbox/screens/dns_server_edit/tabs/json_tab.dart';
import 'package:lxbox/screens/dns_settings_screen/resolved_server.dart';

/// #143 / §458 — read-only JSON-вкладка редактора template/preset-сервера.
/// После §439 у [DnsServerRef] нет `toJson`; вкладка кодировала снимок
/// контроллера в `JsonEncoder` напрямую и падала на каждом template/preset
/// («Converting object to an encodable object failed: Instance of
/// 'DnsServerTemplate'»). Блок «storage shape» должен быть записью 1.0
/// кодеком.
void main() {
  Widget host(DnsServerEditController c) => MaterialApp(
        home: Scaffold(
          body: DnsServerEditScope(
            notifier: c,
            child: const DnsServerJsonTab(),
          ),
        ),
      );

  testWidgets('template: вкладка строится, storage shape — запись 1.0',
      (tester) async {
    final c = DnsServerEditController(
      initialRef: const DnsServerTemplate(
        enabled: true,
        tag: 'dns_tpl',
        varValues: {'server': '9.9.9.9'},
      ),
      resolved: const ResolvedServer(
        kind: ServerKind.template,
        tag: 'dns_tpl',
        description: 'Template DNS',
        enabled: true,
        body: {},
        varValues: {'server': '9.9.9.9'},
      ),
      templateWrapper: const {
        'description': 'Template DNS',
        'vars': [
          {'name': 'server', 'type': 'string', 'default': '1.1.1.1'},
        ],
        'server': {'type': 'udp', 'server': '@server'},
      },
      canonicalDescription: 'Template DNS',
    );
    addTearDown(c.dispose);

    await tester.pumpWidget(host(c));
    expect(tester.takeException(), isNull);
    expect(find.byType(DnsServerJsonTab), findsOneWidget);

    final texts = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((w) => w.data ?? '')
        .toList();
    expect(texts, hasLength(2));
    final storage = texts.first;
    expect(storage, contains('"kind": "template"'));
    expect(storage, contains('"tag": "dns_tpl"'));
    expect(storage, contains('"vars"'));
    expect(storage, contains('"server": "9.9.9.9"'));
    // Превью — отрезолвленное тело с текущим значением переменной.
    expect(texts.last, contains('"server": "9.9.9.9"'));
  });

  testWidgets('preset: вкладка строится, storage shape — запись с ref',
      (tester) async {
    final c = DnsServerEditController(
      initialRef: const DnsServerPreset(
        enabled: true,
        tag: 'ru-direct:dns_ru',
        presetId: 'ru-direct',
      ),
      resolved: const ResolvedServer(
        kind: ServerKind.preset,
        tag: 'ru-direct:dns_ru',
        description: 'Preset DNS',
        enabled: true,
        body: {'type': 'udp', 'server': '77.88.8.8'},
        presetId: 'ru-direct',
      ),
      canonicalDescription: 'Preset DNS',
    );
    addTearDown(c.dispose);

    await tester.pumpWidget(host(c));
    expect(tester.takeException(), isNull);

    final texts = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((w) => w.data ?? '')
        .toList();
    expect(texts, hasLength(2));
    expect(texts.first, contains('"kind": "preset"'));
    expect(texts.first, contains('"ref": "ru-direct:dns_ru"'));
    expect(texts.last, contains('"server": "77.88.8.8"'));
  });
}
