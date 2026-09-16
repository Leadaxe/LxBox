import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/tailscale_state/state_store.dart';
import 'package:lxbox/services/workspaces/workspace_store.dart';

/// §445 — Workspaces × каталоги состояния Tailscale: Save as копирует набор
/// записей индекса (каталоги общие, без копирования), Load каталоги не
/// трогает, Rename переносит набор, Delete удаляет каталоги без других ссылок.
/// `tailscale/` в слот не копируется.
///
/// Pattern: mocked path_provider (Documents и Support) + temp на тест, как в
/// `workspace_store_test.dart`.
void main() {
  late Directory docs;
  late Directory support;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final ws = WorkspaceStore.I;
  final ts = TailscaleStateStore.I;
  var seq = 0;

  UserServer server(String id, String tag) => UserServer(
        id: id,
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        nodes: [TailscaleSpec(id: 'n${seq++}', tag: tag, label: tag)],
      );

  Directory stateDir(String name) =>
      Directory('${support.path}/${TailscaleStateStore.dirName}/$name');

  Future<void> putState(String name) async {
    await stateDir(name).create(recursive: true);
    await File('${stateDir(name).path}/tailscaled.state')
        .writeAsString('key-$name');
  }

  Future<Map<String, dynamic>> slots() async {
    final f = File('${support.path}/${TailscaleStateStore.indexFileName}');
    return (jsonDecode(await f.readAsString()) as Map)['slots']
        as Map<String, dynamic>;
  }

  Future<Map<NodeSpec, String>> build(List<ServerList> lists) async {
    final m = await ws.readManifest();
    return ts.prepareForBuild(
      root: support.path,
      slot: m.current,
      slotNames: m.names,
      lists: lists,
      coreStopped: () async => true,
    );
  }

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    docs = await Directory.systemTemp.createTemp('lxbox_wsts_docs_');
    support = await Directory.systemTemp.createTemp('lxbox_wsts_support_');
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
    await File('${docs.path}/lxbox_settings.json')
        .writeAsString('{"vars":{"scene":"home"}}');
  });

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

  test('Save as → сборка другого слота → Load → Rename → Delete', () async {
    final home = server('H', 'home');
    expect((await build([home]))[home.nodes.single], 'home');
    await putState('home');

    // Первое Save as из «Default»: набор сцены уезжает в Home.
    await ws.saveAs('Home');
    expect((await slots())['Home'], {'H': 'home'});
    expect(
        Directory('${(await ws.slotDirForTesting('Home')).path}/tailscale')
            .existsSync(),
        isFalse,
        reason: 'каталоги состояния в слот не копируются');

    // Save as Work — копия, затем в Work узел заменён другим.
    await ws.saveAs('Work');
    expect((await slots())['Work'], {'H': 'home'});
    final work = server('W', 'work');
    expect((await build([work]))[work.nodes.single], 'work');
    await putState('work');
    expect(stateDir('home').existsSync(), isTrue,
        reason: 'на home ссылается Home');
    expect((await slots()).keys.toSet(), {'Home', 'Work'},
        reason: 'набор «Default» снят сборкой');

    // Load Home: каталоги не трогаются, личность Home на месте.
    expect(await ws.load('Home'), isTrue);
    expect((await build([home]))[home.nodes.single], 'home');
    expect(stateDir('home').existsSync(), isTrue);
    expect(stateDir('work').existsSync(), isTrue,
        reason: 'сборка Home не стирает каталог Work');

    // Rename Work → Job: набор тот же.
    await ws.rename('Work', 'Job');
    expect((await slots())['Job'], {'W': 'work'});
    expect((await slots()).containsKey('Work'), isFalse);

    // Delete Job: его каталог удалён, каталог Home — нет.
    await ws.delete('Job');
    expect((await slots()).containsKey('Job'), isFalse);
    expect(stateDir('work').existsSync(), isFalse);
    expect(stateDir('home').existsSync(), isTrue);
  });

  test('без индекса Tailscale операции Workspaces файлов не создают', () async {
    await ws.saveAs('Home');
    await ws.saveAs('Work');
    await ws.rename('Home', 'Office');
    await ws.delete('Office');
    expect(
        File('${support.path}/${TailscaleStateStore.indexFileName}')
            .existsSync(),
        isFalse);
    expect(stateDir('').existsSync(), isFalse);
  });
}
