import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_notifications_view.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/contract/registry_warning.dart';

// §511 l1 — маска секретов стоит в общем компоненте карточки, а не только на
// пути отказа ввода. Ни один код реестра сейчас не подставляет `{value}`,
// поэтому тест кладёт в копию зеркала контракта код-образец, текст которого
// значение подставляет: первый такой код на секретном поле показал бы секрет
// на всех экранах, кроме листа отказа.

const _probeCode = 'secret_value_probe';
const _secret = 'hunter2-secret-password';

/// Копия `assets/contract` во временный каталог с кодом-образцом.
Future<Directory> _registryWithProbe() async {
  final tmp = await Directory.systemTemp.createTemp('lx_secret_mask_');
  final src = Directory('assets/contract');
  await for (final e in src.list(recursive: true)) {
    if (e is! File) continue;
    final rel = e.path.substring(src.path.length + 1);
    final out = File('${tmp.path}/$rel');
    await out.parent.create(recursive: true);
    await e.copy(out.path);
  }
  final wFile = File('${tmp.path}/registry/warnings.json');
  final doc = jsonDecode(await wFile.readAsString()) as Map<String, dynamic>;
  (doc['warnings'] as Map<String, dynamic>)[_probeCode] = {
    'severity': 'warning',
    'params': <String>[],
    'title_en': 'Value {value} was replaced',
    'title_ru': 'Значение {value} заменено',
    'text_en': 'The field held {value}.',
    'text_ru': 'В поле было {value}.',
    'cause_en': 'Cause: {value}.',
    'cause_ru': 'Причина: {value}.',
    'fix_en': ['Check {value}.'],
    'fix_ru': ['Проверьте {value}.'],
  };
  await wFile.writeAsString(jsonEncode(doc));
  return tmp;
}

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await _registryWithProbe();
    await ContractRegistry.I.loadFromDirectory(dir.path);
  });

  tearDownAll(() async {
    ContractRegistry.I.resetForTesting();
    await dir.delete(recursive: true);
  });

  testWidgets('value секретного поля в карточке — маска, не значение',
      (tester) async {
    expect(registryFieldPathIsSecret('password'), isTrue,
        reason: 'password помечен secret в реестре');
    expect(registryText(_probeCode, RegistryLang.en, value: 'x'),
        'The field held x.',
        reason: 'код-образец подставляет value');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: NodeNotificationsView(const [
            RegistryWarning(code: _probeCode, path: 'password', value: _secret),
          ]),
        ),
      ),
    ));
    await tester.tap(find.byType(ExpansionTile));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining(_secret), findsNothing);
    expect(find.textContaining('***'), findsWidgets);
  });

  testWidgets('несекретное поле показывает значение как есть', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: NodeNotificationsView(const [
            RegistryWarning(code: _probeCode, path: 'server', value: 'h.example'),
          ]),
        ),
      ),
    ));
    await tester.tap(find.byType(ExpansionTile));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('h.example'), findsWidgets);
  });
}
