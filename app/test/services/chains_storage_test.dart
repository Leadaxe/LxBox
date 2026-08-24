import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/direction.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/services/backup_service.dart';
import 'package:lxbox/services/settings_storage.dart';

// §393 C2 — хранение источников-цепочек (`chains[]`) и их выживание в
// ВНУТРЕННЕМ backup/restore.
//
// LX Backup цепочек пока НЕ переносит (раздела в контракте нет — TODO C9 в
// `lx_backup.dart`), а внутренний бэкап обязан: иначе перенос на новое
// устройство молча терял бы вручную собранные маршруты — ровно та болезнь,
// которую §219/§221 уже ловили на Направлениях.

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
      // Отсутствие `chains` = «цепочек нет», состояние, неотличимое от «все
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
        hops: ['home', 'de-exit'],
        idleTimeout: '10m',
        stripEvasion: false,
      ));
      final got = (await SettingsStorage.getChains()).single;
      expect(got.label, 'Германия');
      expect(got.hops, ['home', 'de-exit']);
      expect(got.idleTimeout, '10m');
      expect(got.stripEvasion, isFalse);

      expect(() => SettingsStorage.updateChain(const SourceChain(tag: 'nope')),
          throwsA(isA<StateError>()));
    });

    test('delete убирает запись и НЕ вычищает позиции других цепочек',
        () async {
      // Асимметрия с `include` Направлений намеренна: снятие позиции
      // превращает маршрут в ДРУГОЙ маршрут, и молча подменять его нельзя.
      // Висячую позицию деградирует билдер (`chain_hop_missing`).
      await SettingsStorage.setChains(const [
        SourceChain(tag: 'inner', hops: ['a', 'b']),
        SourceChain(tag: 'outer', hops: ['inner', 'c']),
      ]);
      await SettingsStorage.deleteChain('inner');
      final left = await SettingsStorage.getChains();
      expect(left.map((c) => c.tag), ['outer']);
      expect(left.single.hops, ['inner', 'c'],
          reason: 'позиция осталась — пользователь правит маршрут осознанно');
    });

    test('порядок списка сохраняется — им держится антицикл', () async {
      await SettingsStorage.setChains(const [
        SourceChain(tag: 'c3', hops: ['a', 'b']),
        SourceChain(tag: 'c1', hops: ['a', 'b']),
        SourceChain(tag: 'c2', hops: ['a', 'b']),
      ]);
      expect((await SettingsStorage.getChains()).map((c) => c.tag),
          ['c3', 'c1', 'c2']);
    });

    test('round-trip через файл: полная запись доезжает без потерь', () async {
      const c = SourceChain(
        tag: 'tuned',
        label: 'Tuned',
        hops: ['a', 'b'],
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
      expect(back.toJson(), c.toJson());
      // И в самом файле — под своим ключом, не внутри подписки.
      expect((await readFile())['chains'], isA<List>());
    });
  });

  group('внутренний backup/restore', () {
    test('цепочки переживают export→restore в категории routing', () async {
      await SettingsStorage.setChains(const [
        SourceChain(tag: 'via-de', label: 'DE', hops: ['home', 'de']),
      ]);
      final raw = await readFile();

      final exported = BackupService.filterStorageForExport(
        raw,
        include: {BackupCategory.routing},
      );
      expect(exported['chains'], isA<List>(),
          reason: 'без этого перенос на новое устройство терял бы маршруты');

      // Restore на «чистое» устройство.
      SettingsStorage.resetCacheForTesting();
      await File('${tmp.path}/lxbox_settings.json').delete();
      SettingsStorage.resetCacheForTesting();
      expect(await SettingsStorage.getChains(), isEmpty);

      await SettingsStorage.replaceRaw(exported.cast<String, dynamic>());
      final back = await SettingsStorage.getChains();
      expect(back.single.tag, 'via-de');
      expect(back.single.hops, ['home', 'de']);
    });

    test('без галки routing цепочки в архив не идут', () async {
      await SettingsStorage.setChains(
          const [SourceChain(tag: 'c', hops: ['a', 'b'])]);
      final exported = BackupService.filterStorageForExport(
        await readFile(),
        include: {BackupCategory.appSettings},
      );
      expect(exported.containsKey('chains'), isFalse);
    });

    test('allowlist импорта пропускает chains (иначе default-deny съел бы)',
        () async {
      // §159 — default-deny: ключ, забытый в allowlist, молча исчезает на
      // restore. Ровно так уже терялись `masque_account` и `directions`.
      expect(SettingsStorage.allowedTopLevelKeys.contains('chains'), isTrue);
      final dropped = await SettingsStorage.replaceRaw({
        'chains': [
          const SourceChain(tag: 'c', hops: ['a', 'b']).toJson(),
        ],
      });
      expect(dropped, isNot(contains('chains')));
      expect((await SettingsStorage.getChains()).single.tag, 'c');
    });
  });
}
