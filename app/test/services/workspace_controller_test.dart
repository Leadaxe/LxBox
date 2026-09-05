import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/workspaces/workspace_controller.dart';
import 'package:lxbox/services/workspaces/workspace_store.dart';

/// §417 — оркестрация загрузки: стоп-колбэк, generation для пересоздания
/// HomeScreen, одноразовый флаг автозапуска, no-op на current.
void main() {
  late Directory docs;
  late Directory support;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final ws = WorkspaceController.I;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    docs = await Directory.systemTemp.createTemp('lxbox_wsctl_docs_');
    support = await Directory.systemTemp.createTemp('lxbox_wsctl_support_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
        case 'getApplicationDocumentsPath':
          return docs.path;
        case 'getApplicationSupportDirectory':
        case 'getApplicationSupportPath':
          return support.path;
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
    await File('${docs.path}/lxbox_settings.json')
        .writeAsString('{"vars":{"scene":"a"}}');
    // Синглтон держит справочник прошлого теста — перечитать пустой.
    await ws.refresh();
  });

  Future<String> sceneTag() async {
    final j = jsonDecode(
        await File('${docs.path}/lxbox_settings.json').readAsString()) as Map;
    return (j['vars'] as Map)['scene'] as String;
  }

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    for (final d in [docs, support]) {
      try {
        if (d.existsSync()) await d.delete(recursive: true);
      } on FileSystemException {
        // AppLog пишет persistent-лог в docs async — race с delete.
      }
    }
  });

  test('load current → alreadyCurrent: стоп не зовётся, generation прежний',
      () async {
    final gen = ws.generation;
    var stopCalls = 0;
    final outcome = await ws.load(WorkspaceStore.defaultName, stopVpn: () async {
      stopCalls++;
      return true;
    });
    expect(outcome, WorkspaceLoadOutcome.alreadyCurrent);
    expect(stopCalls, 0);
    expect(ws.generation, gen);
    expect(ws.takePendingAutoConnect(), isFalse);
  });

  test('load другого: стоп → файлы → generation+1 → флаг автозапуска один раз',
      () async {
    await ws.saveAs('Home');
    await File('${docs.path}/lxbox_settings.json')
        .writeAsString('{"vars":{"scene":"b"}}');
    await ws.saveAs('Work');
    final gen = ws.generation;
    var stopCalls = 0;

    final outcome = await ws.load('Home', stopVpn: () async {
      stopCalls++;
      return true;
    });

    expect(outcome, WorkspaceLoadOutcome.loaded);
    expect(stopCalls, 1);
    expect(ws.generation, gen + 1);
    expect(ws.current, 'Home');
    expect(ws.busy, isFalse);
    // После загрузки состояние перечитано: миграции (Направления) прошли по
    // новой сцене и переписали файл — сравниваем разобранный JSON.
    expect(await sceneTag(), 'a');
    expect(await File('${docs.path}/lxbox_settings.json').readAsString(),
        contains('"directions"'),
        reason: 'миграции бутстрапа прошли по загруженной сцене');
    expect(ws.takePendingAutoConnect(), isTrue);
    expect(ws.takePendingAutoConnect(), isFalse, reason: 'одноразовый');
  });

  test('VPN был опущен → автозапуска нет', () async {
    await ws.saveAs('Home');
    await ws.saveAs('Work');
    await ws.load('Home', stopVpn: () async => false);
    expect(ws.takePendingAutoConnect(), isFalse);
  });

  test('load несуществующего → WorkspaceError, busy снят', () async {
    await ws.saveAs('Home');
    await expectLater(
      ws.load('Nope', stopVpn: () async => false),
      throwsA(isA<WorkspaceError>()),
    );
    expect(ws.busy, isFalse);
    expect(ws.current, 'Home');
  });

  test('saveAs обновляет справочник контроллера', () async {
    expect(ws.slots, isEmpty);
    await ws.saveAs('Home');
    expect(ws.current, 'Home');
    expect(ws.slots.map((s) => s.name), ['Home']);
  });
}
