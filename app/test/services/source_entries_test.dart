import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/models/source_entry.dart';
import 'package:lxbox/services/settings_storage.dart';

import '../contract_paths.dart';

// §524 — ЕДИНЫЙ СПИСОК ЗАПИСЕЙ `sources[]`: один упорядоченный род сущности
// (`SourceEntry`) над подписками, серверами, папками и цепочками.
//
// Решение владельца 24.09: «как мы храним по маркеру kind, так мы должны и
// структуру держать … Разных списков быть не должно.» Формат на диске при этом
// НЕ менялся — эти тесты ровно про то, что порядок и байты записей переживают
// круг через новую модель, а операции над списком (удаление из середины,
// перестановка при нечитаемой записи, toggle) соседей не двигают.

void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_sources_');
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
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } on FileSystemException {
      /* ignore */
    }
  });

  File file() => File('${tmp.path}/lxbox_settings.json');

  Future<Map<String, dynamic>> readFile() async =>
      jsonDecode(file().readAsStringSync()) as Map<String, dynamic>;

  Future<List<String>> keysInFile() async {
    SettingsStorage.resetCacheForTesting();
    return [
      for (final r
          in ((await readFile())['sources'] as List).cast<Map<String, dynamic>>())
        '${r['id'] ?? r['tag']}',
    ];
  }

  UserServer server(String id, int n) => UserServer(
        id: id,
        name: '',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: 'vless://$n$n$n$n$n$n$n$n-1111-1111-1111-111111111111'
            '@198.51.100.$n:443#S$n',
      );

  const hops = [NodeLink(tag: 'a'), NodeLink(tag: 'b')];

  /// Смешанный список на диске в порядке [order]: `uN` — сервер, `cN` —
  /// цепочка. Пишется ОДНОЙ записью через единый писатель.
  Future<void> seed(List<String> order) async {
    await SettingsStorage.saveSourceEntries([
      for (final k in order)
        k.startsWith('c')
            ? ChainEntry(SourceChain(tag: k, hops: hops))
            : ContainerEntry(server(k, int.parse(k.substring(1)))),
    ]);
    expect(await keysInFile(), order);
  }

  group('модель: один список всех родов', () {
    test('чтение отдаёт записи в порядке файла, с родом в kind', () async {
      await seed(['u1', 'c1', 'u2', 'c2']);
      final entries = await SettingsStorage.getSourceEntries();
      expect(entries.map((e) => e.kind), ['server', 'chain', 'server', 'chain']);
      expect(entries.map((e) => e.sourceKey), [
        'id:u1',
        'chain:c1',
        'id:u2',
        'chain:c2',
      ]);
      expect(entries.map((e) => e.enabled), [true, true, true, true]);
      expect(entries.whereType<ChainEntry>().map((e) => e.chain.tag),
          ['c1', 'c2']);
      expect(entries.whereType<ContainerEntry>().map((e) => e.list.id),
          ['u1', 'u2']);
    });

    test('round-trip смешанного списка сохраняет порядок и записи', () async {
      // Корпус контракта: подписка, две папки (внутри папки — узел И цепочка),
      // корневой сервер и корневая цепочка со ссылками в папки.
      final corpus = jsonDecode(File('contract/corpus/backup/'
              'v10_sources_union.backup.json')
          .readAsStringSync()) as Map<String, dynamic>;

      file().writeAsStringSync(jsonEncode({
        'storage_version': 1,
        'sources': corpus['sources'],
      }));
      SettingsStorage.resetCacheForTesting();

      final entries = await SettingsStorage.getSourceEntries();
      expect(entries.map((e) => e.kind),
          ['subscription', 'folder', 'folder', 'server', 'chain'],
          reason: 'все рода читаются одним списком, в порядке файла');

      // Первая запись переводит записи в форму хранения приложения (кодек
      // нормализует то, что читает). ДАЛЬШЕ форма стабильна: второй круг через
      // единый писатель обязан дать те же байты — иначе каждый `_persist`
      // переписывал бы файл заново и `configDirty` врал бы (§113).
      await SettingsStorage.saveSourceEntries(entries);
      SettingsStorage.resetCacheForTesting();
      final once = jsonEncode((await readFile())['sources']);

      await SettingsStorage
          .saveSourceEntries(await SettingsStorage.getSourceEntries());
      SettingsStorage.resetCacheForTesting();
      expect(jsonEncode((await readFile())['sources']), once,
          reason: 'формат на диске §524 не менялся — круг идемпотентен');

      // Порядок родов и адресация записей переживают круг.
      final back = await SettingsStorage.getSourceEntries();
      expect(back.map((e) => e.kind),
          ['subscription', 'folder', 'folder', 'server', 'chain']);
      expect(back.last.sourceKey, 'chain:jp-via-eu');
      expect((back.last as ChainEntry).chain.hops.length, 3,
          reason: 'позиции цепочки (в том числе ссылки в папки) на месте');
    }, skip: corpusTestSkip('test/services/source_entries_test.dart'));
  });

  group('операции над списком', () {
    test('удаление цепочки из середины: u1,c1,u2,c2 → u1,u2,c2', () async {
      await seed(['u1', 'c1', 'u2', 'c2']);
      final entries = await SettingsStorage.getSourceEntries();
      await SettingsStorage.saveSourceEntries(
          [for (final e in entries) if (e.sourceKey != 'chain:c1') e]);
      expect(await keysInFile(), ['u1', 'u2', 'c2'],
          reason: 'соседи в освободившееся место не съезжают');
    });

    test('удаление контейнера из середины соседей не двигает', () async {
      await seed(['u1', 'c1', 'u2', 'c2', 'u3']);
      final entries = await SettingsStorage.getSourceEntries();
      await SettingsStorage.saveSourceEntries(
          [for (final e in entries) if (e.sourceKey != 'id:u2') e]);
      expect(await keysInFile(), ['u1', 'c1', 'c2', 'u3']);
    });

    test('нечитаемая запись в середине остаётся на своём месте', () async {
      await seed(['u1', 'c1', 'u2']);
      final doc = await readFile();
      (doc['sources'] as List)
          .insert(2, <String, dynamic>{'kind': 'bogus', 'id': 'junk', 'x': 1});
      file().writeAsStringSync(jsonEncode(doc));
      SettingsStorage.resetCacheForTesting();

      final entries = await SettingsStorage.getSourceEntries();
      expect(entries.map((e) => e.sourceKey),
          ['id:u1', 'chain:c1', 'raw:2', 'id:u2']);
      final opaque = entries[2] as OpaqueEntry;
      expect(opaque.kind, 'bogus');
      expect(opaque.enabled, isFalse);

      // §511 M2 — перестановка ВИДИМЫХ применяется, нечитаемая держит слот.
      expect(
        await SettingsStorage.reorderSources(
            ['id:u2', 'id:u1', 'chain:c1']),
        isTrue,
      );
      expect(await keysInFile(), ['u2', 'u1', 'junk', 'c1']);

      // Долг §511:54-59 — запись переживает ЗАПИСЬ, а не только чтение: она
      // уехала на диск байт в байт, включая ключ, которого модель не держит.
      SettingsStorage.resetCacheForTesting();
      final junk = ((await readFile())['sources'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((r) => r['id'] == 'junk');
      expect(junk, {'kind': 'bogus', 'id': 'junk', 'x': 1});
    });

    test('toggle цепочки не двигает соседей', () async {
      await seed(['u1', 'c1', 'u2']);
      final entries = await SettingsStorage.getSourceEntries();
      await SettingsStorage.saveSourceEntries([
        for (final e in entries)
          if (e is ChainEntry)
            ChainEntry(e.chain.copyWith(enabled: false))
          else
            e,
      ]);
      expect(await keysInFile(), ['u1', 'c1', 'u2']);
      final chains = await SettingsStorage.getChains();
      expect(chains.single.enabled, isFalse);
    });

    test('перестановка через reorderSources пишет порядок как есть', () async {
      await seed(['u1', 'c1', 'u2']);
      expect(
        await SettingsStorage.reorderSources(
            ['chain:c1', 'id:u2', 'id:u1']),
        isTrue,
      );
      expect(await keysInFile(), ['c1', 'u2', 'u1']);
      expect(await SettingsStorage.getSourceKeys(),
          ['chain:c1', 'id:u2', 'id:u1']);
    });
  });

  group('контроллер: applySourceOrder', () {
    test('одна запись на операцию, порядок контейнеров зеркалится в памяти',
        () async {
      await seed(['u1', 'c1', 'u2']);
      final ctrl = SubscriptionController()
        ..debugSetEntries([
          for (final l in await SettingsStorage.getServerLists())
            SubscriptionEntry(list: l),
        ]);

      expect(
        await ctrl.applySourceOrder(['id:u2', 'chain:c1', 'id:u1']),
        isTrue,
      );
      expect(await keysInFile(), ['u2', 'c1', 'u1']);
      expect(ctrl.entries.map((e) => e.id), ['u2', 'u1'],
          reason: 'без зеркала следующий _persist вернул бы прежний порядок');

      // Ключи любого рода: цепочка адресуется наравне с контейнером.
      expect(
        await ctrl.applySourceOrder(['chain:c1', 'id:u1', 'id:u2']),
        isTrue,
      );
      expect(await keysInFile(), ['c1', 'u1', 'u2']);
    });

    test('состав не совпал — false, порядок не тронут', () async {
      await seed(['u1', 'c1', 'u2']);
      final ctrl = SubscriptionController()
        ..debugSetEntries([
          for (final l in await SettingsStorage.getServerLists())
            SubscriptionEntry(list: l),
        ]);
      // Неизвестный ключ — отказ; порядок на диске не тронут.
      expect(
        await ctrl.applySourceOrder(['id:nope', 'chain:c1', 'id:u2']),
        isFalse,
      );
      expect(await keysInFile(), ['u1', 'c1', 'u2']);
      // Повторный ключ — тоже отказ (состав списка эта операция не меняет).
      expect(
        await ctrl.applySourceOrder(['id:u1', 'id:u1', 'chain:c1']),
        isFalse,
      );
      expect(await keysInFile(), ['u1', 'c1', 'u2']);
    });

    test('sourceEntries отдаёт весь список, цепочки с диска', () async {
      await seed(['u1', 'c1', 'u2']);
      final ctrl = SubscriptionController()
        ..debugSetEntries([
          for (final l in await SettingsStorage.getServerLists())
            SubscriptionEntry(list: l),
        ]);
      final all = await ctrl.sourceEntries();
      expect(all.map((e) => e.sourceKey), ['id:u1', 'chain:c1', 'id:u2']);
      expect(all.whereType<ChainEntry>().single.chain.tag, 'c1');
    });
  });
}
