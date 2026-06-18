import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/settings_storage.dart';

/// §072 — атомарность + восстановление SettingsStorage.
///
/// Pattern: ротация `getApplicationDocumentsPath()` через mocked
/// MethodChannel + `resetCacheForTesting()` между прогонами (как в
/// `backup_service_test.dart`).
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  String mainPath() => '${tmp.path}/lxbox_settings.json';
  String bakPath() => '${tmp.path}/lxbox_settings.json.bak';
  // §141 P1.5 — фиксированное legacy-имя (для эмуляции crashed save прошлых
  // версий) + glob-счётчик новых seq-уникальных tmp.
  String tmpPath() => '${tmp.path}/lxbox_settings.json.tmp';
  int orphanTmpCount() => tmp
      .listSync()
      .whereType<File>()
      .where((f) {
        final name = f.uri.pathSegments.last;
        return name.startsWith('lxbox_settings.json.') && name.endsWith('.tmp');
      })
      .length;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_settings_storage_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return tmp.path;
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    // Игнорируем FileSystemException (Directory not empty): AppLog пишет
    // persistent log файл async в `getApplicationDocumentsDirectory()` —
    // может race'ить с нашим recursive delete после warning/error в тесте.
    // Каждый test создаёт уникальный tmp dir через `createTemp`, так что
    // leftover'ы в /tmp не загрязняют следующие прогоны.
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } on FileSystemException {
      /* ignore */
    }
  });

  group('§072 — round-trip', () {
    test('setVar + read back в пределах сессии', () async {
      await SettingsStorage.setVar('alpha', '1');
      expect(await SettingsStorage.getVar('alpha', 'def'), '1');
    });

    test('setVar + resetCacheForTesting + read back с диска', () async {
      await SettingsStorage.setVar('alpha', '1');
      SettingsStorage.resetCacheForTesting();
      expect(await SettingsStorage.getVar('alpha', 'def'), '1');
    });
  });

  group('§072 — corruption recovery', () {
    test('main битый, .bak валидный → recovery из .bak', () async {
      // Сначала записываем валидный state: создаст main + .bak (при second save).
      await SettingsStorage.setVar('alpha', '1');
      await SettingsStorage.setVar('alpha', '2');
      // Теперь портим main:
      await File(mainPath()).writeAsString('{this is not valid json');
      // .bak должен существовать (создан при втором setVar).
      expect(File(bakPath()).existsSync(), isTrue,
          reason: '.bak должен быть создан вторым save');

      SettingsStorage.resetCacheForTesting();
      expect(await SettingsStorage.getVar('alpha', 'def'), isNotEmpty,
          reason: 'данные восстанавливаются из .bak');
      // Sticky-флаг НЕ выставлен (восстановили успешно).
      expect(SettingsStorage.mainIsCorruptedForTesting, isFalse);
    });

    test('main битый, .bak отсутствует → return {}, sticky flag', () async {
      await File(mainPath()).writeAsString('not a json');
      expect(File(bakPath()).existsSync(), isFalse);

      // Просто getVar (не setVar) — ничего не должно перезаписывать main.
      expect(await SettingsStorage.getVar('alpha', 'default'), 'default');
      expect(SettingsStorage.mainIsCorruptedForTesting, isTrue);
      // Main файл остался битым (не перезаписан).
      expect(File(mainPath()).readAsStringSync(), 'not a json');
    });

    test('main = 0 bytes (truncate) → не считается valid empty settings',
        () async {
      // Сначала запишем валидное состояние и .bak.
      await SettingsStorage.setVar('alpha', '1');
      await SettingsStorage.setVar('alpha', '2');
      // Truncate main.
      await File(mainPath()).writeAsString('');

      SettingsStorage.resetCacheForTesting();
      // Должен восстановиться из .bak — alpha остался.
      expect(await SettingsStorage.getVar('alpha', 'def'), isNotEmpty);
      expect(SettingsStorage.mainIsCorruptedForTesting, isFalse);
    });

    test('main 0 bytes + .bak нет → drop с corruption flag', () async {
      await File(mainPath()).writeAsString('');
      expect(File(bakPath()).existsSync(), isFalse);
      expect(await SettingsStorage.getVar('any', 'def'), 'def');
      expect(SettingsStorage.mainIsCorruptedForTesting, isTrue);
    });
  });

  group('§072 — atomic save artifacts', () {
    test('после успешного _save() .tmp не остаётся', () async {
      await SettingsStorage.setVar('alpha', '1');
      expect(File(tmpPath()).existsSync(), isFalse,
          reason: 'rename() консумирует .tmp');
    });

    test('после drop + setVar — main перезаписан, sticky flag сброшен',
        () async {
      // Сценарий: загрузка с битым main без bak → drop. Затем юзер начинает
      // что-то писать → новый save должен пройти атомарно и зачистить
      // sticky-flag.
      await File(mainPath()).writeAsString('garbage');
      expect(await SettingsStorage.getVar('any', 'def'), 'def');
      expect(SettingsStorage.mainIsCorruptedForTesting, isTrue);

      await SettingsStorage.setVar('new', 'x');
      expect(SettingsStorage.mainIsCorruptedForTesting, isFalse,
          reason: 'atomic save сбрасывает flag');

      SettingsStorage.resetCacheForTesting();
      expect(await SettingsStorage.getVar('new', 'def'), 'x');
    });

    test('stale .tmp от прошлого crashed save → удаляется в _load()',
        () async {
      // Эмулируем что предыдущий save был убит после write tmp, до rename.
      // Используем и legacy-имя (`.tmp`), и новое seq-имя — _sweep должен
      // подобрать оба по маске.
      await File(mainPath()).writeAsString(jsonEncode({'vars': {'a': '1'}}));
      await File(tmpPath()).writeAsString('{"vars":{"a":"PARTIAL');
      await File('${tmp.path}/lxbox_settings.json.7.tmp')
          .writeAsString('{"vars":{"a":"PARTIAL2');

      SettingsStorage.resetCacheForTesting();
      expect(await SettingsStorage.getVar('a', 'def'), '1',
          reason: 'main валидный → читаем оттуда');
      // §141 P1.5 — все осиротевшие .tmp (legacy + seq) удалены _sweep'ом.
      expect(orphanTmpCount(), 0,
          reason: '.tmp от прошлых crashed save удалены');
    });

    test('§141 P1.5 — конкурентные _save() не оставляют сирот и не бросают',
        () async {
      // Прогреваем кэш (в проде `_load` отрабатывает на старте app до любых
      // конкурентных save — `subscription._persist` ↔ AutoUpdater ↔ UI). После
      // прогрева `_load()` возвращает общий `_cache` синхронно, так что
      // мутации видят друг друга.
      await SettingsStorage.setVar('warm', '0');

      // Гонка: три перекрывающихся save поверх прогретого кэша. Раньше они
      // писали в ОДИН фиксированный .tmp и каждый rename'ил → второй/третий
      // бросали PathNotFoundException (unhandled async). С seq-уникальными tmp
      // все проходят чисто.
      await Future.wait([
        SettingsStorage.setVar('a', '1'),
        SettingsStorage.setVar('b', '2'),
        SettingsStorage.setVar('c', '3'),
      ]);
      // Все значения сохранены (общий прогретый `_cache`).
      SettingsStorage.resetCacheForTesting();
      expect(await SettingsStorage.getVar('a', 'def'), '1');
      expect(await SettingsStorage.getVar('b', 'def'), '2');
      expect(await SettingsStorage.getVar('c', 'def'), '3');
      // Ни одного осиротевшего .tmp (все rename консумированы, без residual).
      expect(orphanTmpCount(), 0, reason: 'нет residual .tmp после гонки');
    });

    test('.bak создаётся только из валидного main', () async {
      // Первый save: main отсутствует → .bak тоже не должен создаться.
      await SettingsStorage.setVar('alpha', '1');
      expect(File(bakPath()).existsSync(), isFalse,
          reason: 'до первого save main отсутствовал → .bak не создаётся');

      // Второй save: main теперь валидный → .bak копируется из него
      // (содержимое = состояние ПЕРЕД вторым save).
      await SettingsStorage.setVar('alpha', '2');
      expect(File(bakPath()).existsSync(), isTrue);
      final bakContent =
          jsonDecode(await File(bakPath()).readAsString()) as Map;
      expect(((bakContent['vars'] as Map)['alpha']), '1',
          reason: '.bak = состояние main до второго save');
    });

    test('.bak не пишется если main битый', () async {
      // На диске битый main + старый валидный .bak.
      await File(mainPath()).writeAsString('garbage');
      await File(bakPath())
          .writeAsString(jsonEncode({'vars': {'old': 'value'}}));

      SettingsStorage.resetCacheForTesting();
      // _load восстановит из .bak.
      expect(await SettingsStorage.getVar('old', 'def'), 'value');

      // Теперь setVar — atomic save должен:
      //  • НЕ перезаписать .bak из битого main (битый main уже не существует
      //    к этому моменту? давай проверим: copy(main → .bak) шла бы только
      //    если main валидный. У нас main всё ещё битый на диске),
      //  • Записать новый main атомарно.
      await SettingsStorage.setVar('new', 'x');
      // .bak должен остаться с old:value (не был перезаписан из main, т.к.
      // main был битый на момент save).
      // ВАЖНО: после rename main стал валидным → следующий save уже
      // снапнёт его в .bak. Но один-то save мы сделали. Проверяем .bak
      // ПОСЛЕ этого save'а.
      final bakAfter =
          jsonDecode(await File(bakPath()).readAsString()) as Map;
      expect((bakAfter['vars'] as Map)['old'], 'value',
          reason: '.bak остался с предыдущим валидным state');
    });
  });

  group('§072 — миграция совместимость', () {
    test('старый формат proxy_sources читается и мигрирует', () async {
      // Симулируем pre-§030 файл с `proxy_sources` без `server_lists`.
      // migrateProxySources возвращает migrated list.
      final legacy = {
        'proxy_sources': [
          {
            'url': 'https://example.com/sub.txt',
            'enabled': true,
            'name': 'Test sub',
          },
        ],
      };
      await File(mainPath()).writeAsString(jsonEncode(legacy));

      SettingsStorage.resetCacheForTesting();
      final lists = await SettingsStorage.getServerLists();
      expect(lists, isNotEmpty,
          reason: 'миграция proxy_sources → server_lists должна отработать');
    });
  });
}
