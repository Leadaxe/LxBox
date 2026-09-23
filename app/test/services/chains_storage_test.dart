import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/chain_record.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/services/backup_service.dart';
import 'package:lxbox/services/settings_storage.dart';

// §393 C2 — хранение источников-цепочек (§439: записи `kind: chain` хвостом
// `sources[]`) и их выживание во ВНУТРЕННЕМ backup/restore: иначе перенос на
// новое устройство молча терял бы вручную собранные маршруты — ровно та
// болезнь, которую §219/§221 уже ловили на Направлениях.

void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_chains_');
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

  Future<Map<String, dynamic>> readFile() async => jsonDecode(
        File('${tmp.path}/lxbox_settings.json').readAsStringSync(),
      ) as Map<String, dynamic>;

  group('CRUD', () {
    test('чистая установка: цепочек нет и никто их не сеет', () async {
      // Нет записей цепочек = «цепочек нет», состояние, неотличимое от «все
      // удалены», — поэтому миграции/seed'а здесь нет и быть не должно.
      expect(await SettingsStorage.getChains(), isEmpty);
    });

    test('add выдаёт первый свободный chain-N', () async {
      final a = await SettingsStorage.addChain();
      final b = await SettingsStorage.addChain();
      expect(a.tag, 'chain-1');
      expect(b.tag, 'chain-2');
      expect((await SettingsStorage.getChains()).map((c) => c.tag),
          ['chain-1', 'chain-2']);
    });

    test('add с занятым тегом отвергается машинным кодом причины', () async {
      await SettingsStorage.addChain(tag: 'via-de');
      expect(
        () => SettingsStorage.addChain(tag: 'via-de'),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('duplicate'))),
      );
    });

    test('тег, занятый Направлением, отвергается', () async {
      // Два outbound'а с одним тегом — отказ ядра на ВЕСЬ конфиг, поэтому
      // коллизия ловится на входе, а не на сборке.
      await SettingsStorage.setDirections(
          const [Direction(tag: 'vpn-1', label: 'VPN ①')]);
      expect(
        () => SettingsStorage.addChain(tag: 'vpn-1'),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('duplicate'))),
      );
      // Тёзка auto-двойника Направления — тоже коллизия: `vpn-1-auto`
      // эмитится билдером и заняло бы тот же тег.
      expect(() => SettingsStorage.addChain(tag: 'vpn-1-auto'),
          throwsA(isA<StateError>()));
    });

    test('служебный тег отвергается', () async {
      expect(() => SettingsStorage.addChain(tag: 'direct-out'),
          throwsA(isA<StateError>()));
      expect(() => SettingsStorage.addChain(tag: 'reject'),
          throwsA(isA<StateError>()));
    });

    test('update пишет по тегу; неизвестный тег — StateError', () async {
      await SettingsStorage.addChain(tag: 'via-de', label: 'DE');
      await SettingsStorage.updateChain(const SourceChain(
        tag: 'via-de',
        label: 'Германия',
        hops: [NodeLink(tag: 'home'), NodeLink(tag: 'de-exit')],
        idleTimeout: '10m',
        stripEvasion: false,
      ));
      final got = (await SettingsStorage.getChains()).single;
      expect(got.label, 'Германия');
      expect(got.hops, const [NodeLink(tag: 'home'), NodeLink(tag: 'de-exit')]);
      expect(got.idleTimeout, '10m');
      expect(got.stripEvasion, isFalse);

      expect(() => SettingsStorage.updateChain(const SourceChain(tag: 'nope')),
          throwsA(isA<StateError>()));
    });

    test('§393 D2 delete вычищает ПОЗИЦИЮ из других цепочек, сами они остаются',
        () async {
      // Директива оператора 24.08: осознанное удаление источника — это
      // высказывание про состав, и маршрут переживает его УКОРОЧЕННЫМ.
      // Каскад рекурсивен только через цепочки-позиции: удаление `inner`
      // снимает позицию `inner` у `outer`, но `outer` живёт дальше.
      await SettingsStorage.setChains(const [
        SourceChain(tag: 'inner', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
        SourceChain(tag: 'outer', hops: [NodeLink(tag: 'inner'), NodeLink(tag: 'c'), NodeLink(tag: 'd')]),
      ]);
      final healed = await SettingsStorage.deleteChain('inner');
      final left = await SettingsStorage.getChains();
      expect(left.map((c) => c.tag), ['outer'],
          reason: 'сама цепочка НЕ удаляется каскадом');
      expect(left.single.hops, const [NodeLink(tag: 'c'), NodeLink(tag: 'd')],
          reason: 'ушла ровно позиция удалённого');
      expect(healed.positions, 1,
          reason: 'счётчик виден пользователю: маршрут стал короче');
      expect(healed.touched, ['outer']);
    });

    test('§393 D2 цепочка, упавшая ниже двух позиций, остаётся в storage',
        () async {
      // Принято как есть: не эмитится (существующая деградация
      // `chainEmitError`), но данные пользователя не стираются — чинит руками.
      await SettingsStorage.setChains(const [
        SourceChain(tag: 'inner', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
        SourceChain(tag: 'outer', hops: [NodeLink(tag: 'inner'), NodeLink(tag: 'c')]),
      ]);
      await SettingsStorage.deleteChain('inner');
      final left = await SettingsStorage.getChains();
      expect(left.map((c) => c.tag), ['outer']);
      expect(left.single.hops, const [NodeLink(tag: 'c')]);
      expect(chainEmitError(left.single), isNotEmpty,
          reason: 'одна позиция — ядру не годится, цепочка не эмитится');
    });

    test('§393 D2 heal чужого источника снимает позицию у всех цепочек',
        () async {
      await SettingsStorage.setChains(const [
        SourceChain(tag: 'c1', hops: [NodeLink(tag: 'gone'), NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
        SourceChain(tag: 'c2', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'gone')]),
        SourceChain(tag: 'c3', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
      ]);
      final healed = await SettingsStorage.healChainHops('gone');
      expect(healed.positions, 2);
      expect(healed.touched, ['c1', 'c2']);
      final left = await SettingsStorage.getChains();
      expect(left.map((c) => c.hops), const [
        [NodeLink(tag: 'a'), NodeLink(tag: 'b')],
        [NodeLink(tag: 'a')],
        [NodeLink(tag: 'a'), NodeLink(tag: 'b')],
      ]);
    });

    test('порядок списка сохраняется — им держится антицикл', () async {
      await SettingsStorage.setChains(const [
        SourceChain(tag: 'c3', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
        SourceChain(tag: 'c1', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
        SourceChain(tag: 'c2', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
      ]);
      expect((await SettingsStorage.getChains()).map((c) => c.tag),
          ['c3', 'c1', 'c2']);
    });

    test('round-trip через файл: полная запись доезжает без потерь', () async {
      const c = SourceChain(
        tag: 'tuned',
        label: 'Tuned',
        hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')],
        idleTimeout: '0s',
        stripEvasion: false,
        strip: {kChainStripTlsUtls: true},
        rewrite: {
          'vless': {'flow': null},
        },
      );
      await SettingsStorage.setChains(const [c]);
      SettingsStorage.resetCacheForTesting();
      final back = (await SettingsStorage.getChains()).single;
      expect(back, c);
      // §439 — в файле запись `kind: chain` в `sources[]`, отдельного ключа нет.
      final file = await readFile();
      expect(file.containsKey('chains'), isFalse);
      final records = (file['sources'] as List).cast<Map<String, dynamic>>();
      expect(records.single['kind'], 'chain');
      expect(records.single['tag'], 'tuned');
    });
  });

  // §439 / §509 — цепочки в `sources[]` среди остальных источников; место —
  // индекс записи. Миграция со старого `order` по-прежнему кладёт их хвостом.
  group('место в общем списке источников', () {
    test('порядок записей держит порядок чтения', () async {
      await SettingsStorage.setChains(const [
        SourceChain(tag: 'c1', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
        SourceChain(tag: 'c2', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
        SourceChain(tag: 'c3', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
      ]);
      SettingsStorage.resetCacheForTesting();
      final got = await SettingsStorage.getChains();
      expect(got.map((c) => c.tag), ['c1', 'c2', 'c3']);
      final records = ((await readFile())['sources'] as List)
          .cast<Map<String, dynamic>>();
      expect(records.map((r) => r['tag']), ['c1', 'c2', 'c3']);
      expect(records.every((r) => !r.containsKey('order')), isTrue,
          reason: 'поля позиции у записи нет');
    });

    test('reorder меняет взаимный порядок цепочек', () async {
      await SettingsStorage.setChains(const [
        SourceChain(tag: 'c1', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
        SourceChain(tag: 'c2', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
      ]);
      final now = await SettingsStorage.getChains();
      await SettingsStorage.reorderChains([now[1], now[0]]);
      SettingsStorage.resetCacheForTesting();
      expect((await SettingsStorage.getChains()).map((c) => c.tag),
          ['c2', 'c1']);
    });

    test('сохранение источников не трогает цепочки, цепочки — источники',
        () async {
      await SettingsStorage.setChains(const [
        SourceChain(tag: 'c1', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
        SourceChain(tag: 'c2', hops: [NodeLink(tag: 'c1'), NodeLink(tag: 'b')]),
      ]);
      await SettingsStorage.saveServerLists([
        UserServer(
          id: 'u1',
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          rawBody: 'vless://11111111-1111-1111-1111-111111111111@198.51.100.1:443#One',
        ),
      ]);
      await SettingsStorage.setChains(const [
        SourceChain(tag: 'c2', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
        SourceChain(tag: 'c1', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
      ]);
      SettingsStorage.resetCacheForTesting();

      final records = ((await readFile())['sources'] as List)
          .cast<Map<String, dynamic>>();
      expect(records.map((r) => (r['kind'], r['id'] ?? r['tag'])), [
        ('chain', 'c2'),
        ('chain', 'c1'),
        ('server', 'u1'),
      ], reason: 'слоты цепочек на месте, новый сервер в конец массива');
      expect((await SettingsStorage.getServerLists()).map((l) => l.id), ['u1']);
      expect((await SettingsStorage.getChains()).map((c) => c.tag),
          ['c2', 'c1']);
    });

    test('reorderSources ставит цепочку между серверами', () async {
      await SettingsStorage.saveServerLists([
        UserServer(
          id: 'u1',
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          rawBody:
              'vless://11111111-1111-1111-1111-111111111111@198.51.100.1:443#One',
        ),
        UserServer(
          id: 'u2',
          name: '',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          rawBody:
              'vless://22222222-2222-2222-2222-222222222222@198.51.100.2:443#Two',
        ),
      ]);
      await SettingsStorage.setChains(const [
        SourceChain(tag: 'c1', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]),
      ]);
      await SettingsStorage.reorderSources([
        SettingsStorage.sourceKeyForId('u1'),
        SettingsStorage.sourceKeyForChain('c1'),
        SettingsStorage.sourceKeyForId('u2'),
      ]);
      SettingsStorage.resetCacheForTesting();
      final records = ((await readFile())['sources'] as List)
          .cast<Map<String, dynamic>>();
      expect(records.map((r) => (r['kind'], r['id'] ?? r['tag'])), [
        ('server', 'u1'),
        ('chain', 'c1'),
        ('server', 'u2'),
      ]);
      expect(await SettingsStorage.getSourceKeys(), [
        SettingsStorage.sourceKeyForId('u1'),
        SettingsStorage.sourceKeyForChain('c1'),
        SettingsStorage.sourceKeyForId('u2'),
      ]);

      await SettingsStorage.saveServerLists([
        for (final l in await SettingsStorage.getServerLists())
          if (l is UserServer && l.id == 'u2')
            l.copyWith(enabled: false)
          else
            l,
      ]);
      SettingsStorage.resetCacheForTesting();
      expect(
        ((await readFile())['sources'] as List)
            .cast<Map<String, dynamic>>()
            .map((r) => (r['kind'], r['id'] ?? r['tag'])),
        [
          ('server', 'u1'),
          ('chain', 'c1'),
          ('server', 'u2'),
        ],
        reason: 'saveServerLists не выносит цепочку в хвост',
      );
    });

    // §511 M1 — удаление из середины смешанного списка: соседи того же рода
    // остаются в своих слотах, а не сдвигаются в освободившийся.
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

    Future<List<String>> keysInFile() async {
      SettingsStorage.resetCacheForTesting();
      return [
        for (final r in ((await readFile())['sources'] as List)
            .cast<Map<String, dynamic>>())
          '${r['id'] ?? r['tag']}',
      ];
    }

    Future<void> seedMixed(List<String> order) async {
      await SettingsStorage.saveServerLists([
        for (final k in order)
          if (k.startsWith('u')) server(k, int.parse(k.substring(1))),
      ]);
      await SettingsStorage.setChains([
        for (final k in order)
          if (k.startsWith('c')) SourceChain(tag: k, hops: hops),
      ]);
      await SettingsStorage.reorderSources([
        for (final k in order)
          k.startsWith('c')
              ? SettingsStorage.sourceKeyForChain(k)
              : SettingsStorage.sourceKeyForId(k),
      ]);
      expect(await keysInFile(), order);
    }

    test('удаление цепочки из середины не сдвигает соседнюю цепочку', () async {
      await seedMixed(['u1', 'c1', 'u2', 'c2']);
      await SettingsStorage.deleteChain('c1');
      expect(await keysInFile(), ['u1', 'u2', 'c2']);
    });

    test('удаление сервера из середины не сдвигает соседние серверы', () async {
      await seedMixed(['u1', 'c1', 'u2', 'c2', 'u3']);
      await SettingsStorage.saveServerLists([
        for (final l in await SettingsStorage.getServerLists())
          if (l.id != 'u1') l,
      ]);
      expect(await keysInFile(), ['c1', 'u2', 'c2', 'u3']);
    });

    test('перестановка своего рода идёт порядком записи, новая — в хвост',
        () async {
      await seedMixed(['u1', 'c1', 'u2', 'c2', 'u3']);
      await SettingsStorage.setChains(const [
        SourceChain(tag: 'c2', hops: hops),
        SourceChain(tag: 'c1', hops: hops),
        SourceChain(tag: 'c3', hops: hops),
      ]);
      expect(await keysInFile(), ['u1', 'c2', 'u2', 'c1', 'u3', 'c3']);
    });

    test('форма 2.23.2: цепочки встают хвостом sources[] по старому order, '
        'без order — в конец в порядке файла', () async {
      final f = File('${tmp.path}/lxbox_settings.json');
      f.writeAsStringSync(jsonEncode({
        'server_lists': [
          {'type': 'user', 'id': 'u1', 'name': '', 'enabled': true},
        ],
        'chains': [
          {'tag': 'no-order', 'hops': ['a', 'b']},
          {'tag': 'second', 'hops': ['first', 'c'], 'order': 5},
          {'tag': 'first', 'hops': ['a', 'b'], 'order': 1},
        ],
      }));
      SettingsStorage.resetCacheForTesting();

      final got = await SettingsStorage.getChains();
      expect(got.map((c) => c.tag), ['first', 'second', 'no-order']);
      // Маршрут не тронут — мигрируются позиции в списке, а не хопы.
      expect(got[1].hops, const [NodeLink(tag: 'first'), NodeLink(tag: 'c')]);
      final records = ((await readFile())['sources'] as List)
          .cast<Map<String, dynamic>>();
      expect(records.map((r) => r['kind']),
          ['server', 'chain', 'chain', 'chain']);
    });
  });

  group('внутренний backup/restore', () {
    test('цепочки переживают export→restore в категории routing', () async {
      await SettingsStorage.setChains(const [
        SourceChain(tag: 'via-de', label: 'DE', hops: [NodeLink(tag: 'home'), NodeLink(tag: 'de')]),
      ]);
      final raw = await readFile();

      final exported = BackupService.filterStorageForExport(
        raw,
        include: {BackupCategory.routing},
      );
      expect(
          (exported['sources'] as List).map((r) => (r as Map)['kind']),
          ['chain'],
          reason: 'без этого перенос на новое устройство терял бы маршруты');

      // Restore на «чистое» устройство.
      SettingsStorage.resetCacheForTesting();
      await File('${tmp.path}/lxbox_settings.json').delete();
      SettingsStorage.resetCacheForTesting();
      expect(await SettingsStorage.getChains(), isEmpty);

      await SettingsStorage.replaceRaw(exported.cast<String, dynamic>());
      final back = await SettingsStorage.getChains();
      expect(back.single.tag, 'via-de');
      expect(back.single.hops, const [NodeLink(tag: 'home'), NodeLink(tag: 'de')]);
    });

    test('без галки routing цепочки в архив не идут', () async {
      await SettingsStorage.setChains(
          const [SourceChain(tag: 'c', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')])]);
      final exported = BackupService.filterStorageForExport(
        await readFile(),
        include: {BackupCategory.appSettings},
      );
      expect(exported.containsKey('sources'), isFalse);
    });

    test('allowlist импорта пропускает sources (иначе default-deny съел бы)',
        () async {
      // §159 — default-deny: ключ, забытый в allowlist, молча исчезает на
      // restore. Ровно так уже терялись `masque_account` и `directions`.
      expect(SettingsStorage.allowedTopLevelKeys.contains('sources'), isTrue);
      final dropped = await SettingsStorage.replaceRaw({
        'storage_version': 1,
        'sources': [
          chainToRecord(const SourceChain(tag: 'c', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')])),
        ],
      });
      expect(dropped, isEmpty);
      expect((await SettingsStorage.getChains()).single.tag, 'c');
    });

    test('снимок формы 2.23.2 с chains мигрирует на входе replaceRaw',
        () async {
      final dropped = await SettingsStorage.replaceRaw({
        'chains': [
          {'tag': 'c', 'hops': ['a', 'b'], 'order': 3},
        ],
      });
      expect(dropped, isEmpty);
      expect((await SettingsStorage.getChains()).single.hops, const [NodeLink(tag: 'a'), NodeLink(tag: 'b')]);
      final file = await readFile();
      expect(file.containsKey('chains'), isFalse);
      expect(file['storage_version'], 1);
    });
  });
}
