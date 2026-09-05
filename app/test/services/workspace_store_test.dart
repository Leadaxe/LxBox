import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/workspaces/workspace_store.dart';

/// §417 — Workspaces: справочник, копирование состава слота в обе стороны,
/// журнал незавершённой загрузки, управление слотами.
///
/// Pattern: mocked path_provider (ОБА корня — Documents и Support, у слота
/// позиции в обоих) + уникальный temp на тест.
void main() {
  late Directory docs;
  late Directory support;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final store = WorkspaceStore.I;

  File settings() => File('${docs.path}/lxbox_settings.json');
  File settingsBak() => File('${docs.path}/lxbox_settings.json.bak');
  Directory ruleSets() => Directory('${docs.path}/rule_sets');
  Directory subCache() => Directory('${support.path}/sub_cache');
  File manifest() => File('${docs.path}/workspaces.json');

  /// Сцена в состоянии [tag]: настройки, один .srs, одно тело подписки.
  Future<void> putScene(String tag, {bool withDirs = true}) async {
    await settings().writeAsString('{"vars":{"scene":"$tag"}}');
    if (withDirs) {
      await ruleSets().create(recursive: true);
      await File('${ruleSets().path}/$tag.srs').writeAsString('srs-$tag');
      await File('${ruleSets().path}/$tag.meta.json').writeAsString('{}');
      await subCache().create(recursive: true);
      await File('${subCache().path}/body-$tag').writeAsString('sub-$tag');
      await File('${subCache().path}/body-$tag.headers')
          .writeAsString('{"h":"$tag"}');
    }
  }

  Future<String> sceneTag() async {
    final j = jsonDecode(await settings().readAsString()) as Map;
    return (j['vars'] as Map)['scene'] as String;
  }

  Future<Set<String>> names(Directory d) async {
    if (!await d.exists()) return {};
    return d
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path.substring(d.path.length + 1))
        .toSet();
  }

  Future<Map<String, dynamic>> readManifestRaw() async =>
      jsonDecode(await manifest().readAsString()) as Map<String, dynamic>;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    docs = await Directory.systemTemp.createTemp('lxbox_ws_docs_');
    support = await Directory.systemTemp.createTemp('lxbox_ws_support_');
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

  group('без справочника', () {
    test('дефолт: current=Default, слотов нет, диск не трогается', () async {
      await putScene('a');
      final m = await store.readManifest();
      expect(m.current, 'Default');
      expect(m.slots, isEmpty);
      expect(m.pending, isNull);
      expect(await store.recover(), isFalse);
      expect(await manifest().exists(), isFalse,
          reason: 'recover без справочника не создаёт файлов');
      expect(await store.load('Default'), isFalse, reason: 'current → no-op');
      expect(await manifest().exists(), isFalse);
    });

    test('load несуществующего слота → notFound', () async {
      await putScene('a');
      expect(
        () => store.load('Nope'),
        throwsA(isA<WorkspaceError>()
            .having((e) => e.kind, 'kind', WorkspaceErrorKind.notFound)),
      );
    });
  });

  group('validateName', () {
    test('правила имени = имени папки', () {
      expect(WorkspaceStore.validateName('Home'), isNull);
      expect(WorkspaceStore.validateName('  Home  '), isNull);
      expect(WorkspaceStore.validateName('Работа 2'), isNull);
      expect(WorkspaceStore.validateName(''), WorkspaceNameError.empty);
      expect(WorkspaceStore.validateName('   '), WorkspaceNameError.empty);
      expect(WorkspaceStore.validateName('a/b'), WorkspaceNameError.forbiddenChars);
      expect(WorkspaceStore.validateName('a\\b'), WorkspaceNameError.forbiddenChars);
      expect(WorkspaceStore.validateName('a\nb'), WorkspaceNameError.forbiddenChars);
      expect(WorkspaceStore.validateName('..'), WorkspaceNameError.leadingDot);
      expect(WorkspaceStore.validateName('.hidden'), WorkspaceNameError.leadingDot);
      expect(WorkspaceStore.validateName('x' * 65), WorkspaceNameError.tooLong);
    });

    test('saveAs с плохим именем → invalidName, ничего не создано', () async {
      await putScene('a');
      expect(
        () => store.saveAs('a/b'),
        throwsA(isA<WorkspaceError>()
            .having((e) => e.kind, 'kind', WorkspaceErrorKind.invalidName)
            .having((e) => e.nameError, 'nameError',
                WorkspaceNameError.forbiddenChars)),
      );
      expect(await manifest().exists(), isFalse);
    });
  });

  group('saveAs', () {
    test('копирует все три позиции, current = имя, дата записана', () async {
      await putScene('a');
      // Сироты атомарных писателей не копируются.
      await File('${subCache().path}/body-a.3.tmp').writeAsString('junk');
      await File('${ruleSets().path}/x.srs.tmp').writeAsString('junk');

      await store.saveAs(' Home ');

      final slot = await store.slotDirForTesting('Home');
      expect(await File('${slot.path}/lxbox_settings.json').readAsString(),
          contains('"scene":"a"'));
      expect(await names(Directory('${slot.path}/rule_sets')),
          {'a.srs', 'a.meta.json'});
      expect(await names(Directory('${slot.path}/sub_cache')),
          {'body-a', 'body-a.headers'});

      final m = await store.readManifest();
      expect(m.current, 'Home');
      expect(m.slots.map((s) => s.name), ['Home']);
      expect(m.slots.single.savedAt.year, greaterThanOrEqualTo(2026));
      expect(m.pending, isNull);
      expect(await sceneTag(), 'a', reason: 'сцена не тронута');
    });

    test('повторный saveAs в то же имя перезаписывает слот целиком', () async {
      await putScene('a');
      await store.saveAs('Home');
      // Сцена изменилась: другой набор файлов, меньше папок.
      await ruleSets().delete(recursive: true);
      await subCache().delete(recursive: true);
      await putScene('b', withDirs: false);
      await store.saveAs('Home');

      final slot = await store.slotDirForTesting('Home');
      expect(await File('${slot.path}/lxbox_settings.json').readAsString(),
          contains('"scene":"b"'));
      expect(await Directory('${slot.path}/rule_sets').exists(), isFalse,
          reason: 'позиции, которых нет на сцене, из слота удаляются');
      expect(await Directory('${slot.path}/sub_cache').exists(), isFalse);
      expect((await store.readManifest()).slots.length, 1);
    });
  });

  group('load', () {
    test('сцена уходит в current, цель приходит на сцену, .bak снят',
        () async {
      await putScene('a');
      await store.saveAs('Home');
      await putScene('b');
      await store.saveAs('Work');
      // Правки поверх Work, ещё не сохранённые.
      await putScene('c');
      await settingsBak().writeAsString('stale');
      final beforeMtime = settings().lastModifiedSync();

      expect(await store.load('Home'), isTrue);

      expect(await sceneTag(), 'a', reason: 'на сцене — Home');
      expect(await names(ruleSets()), {'a.srs', 'a.meta.json'},
          reason: 'файлы c.* со сцены исчезли');
      expect(await names(subCache()), {'body-a', 'body-a.headers'});
      expect(await settingsBak().exists(), isFalse, reason: '.bak чужого слота снят');
      expect(
          settings().lastModifiedSync().isAfter(beforeMtime) ||
              settings().lastModifiedSync().isAtSameMomentAs(beforeMtime),
          isTrue,
          reason: 'настройки заведомо не старее — touch');

      final work = await store.slotDirForTesting('Work');
      expect(await File('${work.path}/lxbox_settings.json').readAsString(),
          contains('"scene":"c"'),
          reason: 'несохранённое состояние уехало в current (Work)');
      expect(await names(Directory('${work.path}/rule_sets')),
          containsAll({'c.srs', 'b.srs'}));

      final m = await store.readManifest();
      expect(m.current, 'Home');
      expect(m.pending, isNull);
      expect(m.slots.map((s) => s.name).toSet(), {'Home', 'Work'});
    });

    test('первая загрузка без папки у current создаёт «Default»', () async {
      await putScene('a');
      // Слот Work появился не через saveAs текущего: справочник без Default.
      await store.saveAs('Work');
      await putScene('b');
      // Эмуляция «фичей не пользовались, но слот есть» — current сброшен.
      final raw = await readManifestRaw();
      raw['current'] = 'Default';
      await manifest().writeAsString(jsonEncode(raw));

      expect(await store.load('Work'), isTrue);

      expect(await sceneTag(), 'a');
      final def = await store.slotDirForTesting('Default');
      expect(await File('${def.path}/lxbox_settings.json').readAsString(),
          contains('"scene":"b"'));
      final m = await store.readManifest();
      expect(m.current, 'Work');
      expect(m.slots.map((s) => s.name).toSet(), {'Work', 'Default'});
    });

    test('load current → no-op, файлы не трогаются', () async {
      await putScene('a');
      await store.saveAs('Home');
      await putScene('b');
      expect(await store.load('Home'), isFalse);
      expect(await sceneTag(), 'b');
      final slot = await store.slotDirForTesting('Home');
      expect(await File('${slot.path}/lxbox_settings.json').readAsString(),
          contains('"scene":"a"'));
    });
  });

  group('recover — журнал незавершённой загрузки', () {
    test('pending load → повтор шагов: сцена = цель, current = цель',
        () async {
      await putScene('a');
      await store.saveAs('Home');
      await putScene('b');
      await store.saveAs('Work');
      // Убили посреди загрузки Home: журнал есть, сцена — смесь.
      final raw = await readManifestRaw();
      raw['pending'] = {'op': 'load', 'target': 'Home'};
      await manifest().writeAsString(jsonEncode(raw));
      await File('${ruleSets().path}/mixed.srs').writeAsString('x');

      expect(await store.recover(), isTrue);

      expect(await sceneTag(), 'a');
      expect(await names(ruleSets()), {'a.srs', 'a.meta.json'});
      final m = await store.readManifest();
      expect(m.current, 'Home');
      expect(m.pending, isNull);
      expect(await store.recover(), isFalse, reason: 'повтор — нечего доводить');
    });

    test('pending с исчезнувшей целью → журнал снят, сцена как есть', () async {
      await putScene('a');
      await store.saveAs('Home');
      final raw = await readManifestRaw();
      raw['pending'] = {'op': 'load', 'target': 'Gone'};
      await manifest().writeAsString(jsonEncode(raw));

      expect(await store.recover(), isFalse);
      expect(await sceneTag(), 'a');
      expect((await store.readManifest()).pending, isNull);
    });
  });

  group('rename / delete', () {
    test('rename current переименовывает папку и current', () async {
      await putScene('a');
      await store.saveAs('Home');
      await store.rename('Home', 'Casa');
      expect(await (await store.slotDirForTesting('Home')).exists(), isFalse);
      expect(await (await store.slotDirForTesting('Casa')).exists(), isTrue);
      final m = await store.readManifest();
      expect(m.current, 'Casa');
      expect(m.slots.map((s) => s.name), ['Casa']);
    });

    test('rename в занятое имя → exists', () async {
      await putScene('a');
      await store.saveAs('Home');
      await store.saveAs('Work');
      expect(
        () => store.rename('Home', 'Work'),
        throwsA(isA<WorkspaceError>()
            .having((e) => e.kind, 'kind', WorkspaceErrorKind.exists)),
      );
    });

    test('delete current → isCurrent; delete другого — папка и запись сняты',
        () async {
      await putScene('a');
      await store.saveAs('Home');
      await store.saveAs('Work');
      expect(
        () => store.delete('Work'),
        throwsA(isA<WorkspaceError>()
            .having((e) => e.kind, 'kind', WorkspaceErrorKind.isCurrent)),
      );
      await store.delete('Home');
      expect(await (await store.slotDirForTesting('Home')).exists(), isFalse);
      expect((await store.readManifest()).slots.map((s) => s.name), ['Work']);
    });

    test('slotSizeBytes считает файлы слота', () async {
      await putScene('a');
      await store.saveAs('Home');
      expect(await store.slotSizeBytes('Home'), greaterThan(0));
      expect(await store.slotSizeBytes('Nope'), 0);
    });
  });

  test('битый справочник читается как отсутствующий', () async {
    await putScene('a');
    await manifest().writeAsString('{not json');
    final m = await store.readManifest();
    expect(m.current, 'Default');
    expect(m.slots, isEmpty);
  });
}
