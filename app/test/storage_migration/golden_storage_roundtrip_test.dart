import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/direction_mutations.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/storage_migration/migrate_storage.dart';
import 'package:lxbox/services/subscription/http_cache.dart';

import 'golden_harness.dart';

// §439 — фикстура хранения формы 2.23.2 мигрирует при первом чтении
// (`_load`), и документ формы 1.0 проходит все типизированные геттеры и
// сейверы (кодек записей → модели → кодек) без потерь.
//
// Эталон `golden/<name>.storage_roundtrip.json`:
//   • `migration` — отчёт `migrateStorageDoc` над фикстурой (что сделано и
//     что прочитано не дословно);
//   • `migrated_file_is_report_doc` — файл, записанный `_load`, равен
//     документу отчёта (кроме `id` второй и следующих записей разделённого
//     json-массива: они новые при каждой миграции);
//   • `content_diff` / `bytes_identical` — файл после круга через модели
//     против файла сразу после миграции. Пустая разница и совпадение байтов —
//     форма 1.0 проходит модели дословно.

void main() {
  for (final name in kStorageFixtures) {
    test('$name: загрузка и запись SettingsStorage — разница с фикстурой',
        timeout: kGoldenTimeout, () async {
      final sw = Stopwatch()..start();
      void t(String s) => printOnFailure('${sw.elapsedMilliseconds}ms $s');
      final box = await StorageSandbox.create();
      t('created');
      addTearDown(box.dispose);
      await box.seed(name);
      t('seeded');

      final fixture = jsonDecode(await fixtureFile(name).readAsString())
          as Map<String, dynamic>;
      // Как `_load`: пресеты DNS по шаблону и тела подписок из `sub_cache`
      // (перевод ссылок на узлы подписок, §439 п. 8).
      final bodies = <String, String>{};
      for (final l in fixture['server_lists'] as List) {
        if (l is! Map || l['type'] != 'subscription') continue;
        final url = l['url'];
        if (url is! String || bodies.containsKey(url)) continue;
        final body = await HttpCache.loadBody(url);
        if (body != null && body.isNotEmpty) bodies[url] = body;
      }
      final report = migrateStorageDoc(
        jsonDecode(jsonEncode(fixture)) as Map<String, dynamic>,
        presetIdByDnsServerTag: await SettingsStorage.presetIdsForMigration(),
        subscriptionBodies: bodies,
      );

      // Первое чтение мигрирует файл и пишет его.
      final raw = await SettingsStorage.exportRaw();
      final migratedText = await box.settingsFile.readAsString();
      t('migrated');

      // Типизированные сущности — через модели.
      await SettingsStorage.saveServerLists(
          await SettingsStorage.getServerLists());
      t('lists');
      await SettingsStorage.setChains(await SettingsStorage.getChains(),
          flush: false);
      await SettingsStorage.saveCustomRules(
          await SettingsStorage.getCustomRules(),
          flush: false);
      await DirectionMutations.bulkReplace(
          await SettingsStorage.getDirections(),
          flush: false);
      if (raw.containsKey('dns')) {
        await SettingsStorage.saveDnsServers(
            await SettingsStorage.getDnsServers(),
            flush: false);
        await SettingsStorage.saveDnsRulesList(
            await SettingsStorage.getDnsRulesList(),
            flush: false);
      }
      for (final e in (await SettingsStorage.getAllVars()).entries) {
        await SettingsStorage.setVar(e.key, e.value, flush: false);
      }
      if (raw.containsKey('route_final')) {
        await SettingsStorage.saveRouteFinal(
            await SettingsStorage.getRouteFinal(),
            flush: false);
      }
      if (raw.containsKey('route_idle_suspend')) {
        await SettingsStorage.saveIdleSuspend(
            await SettingsStorage.getIdleSuspend(),
            flush: false);
      }
      if (raw.containsKey('route_idle_suspend_reachable')) {
        await SettingsStorage.saveIdleSuspendReachable(
            await SettingsStorage.getIdleSuspendReachable(),
            flush: false);
      }
      if (raw.containsKey('urltest_passive_check')) {
        await SettingsStorage.savePassiveCheck(
            await SettingsStorage.getPassiveCheck(),
            flush: false);
      }
      if (raw.containsKey('tun_apps')) {
        await SettingsStorage.setTunApps(await SettingsStorage.getTunApps(),
            flush: false);
      }
      if (raw.containsKey('vpn_mode')) {
        await SettingsStorage.setVpnMode(await SettingsStorage.getVpnMode(),
            flush: false);
      }
      if (raw.containsKey('warp_account')) {
        await SettingsStorage.setWarpAccount(
            await SettingsStorage.getWarpAccount(),
            flush: false);
      }
      if (raw.containsKey('masque_account')) {
        await SettingsStorage.setMasqueAccount(
            await SettingsStorage.getMasqueAccount(),
            flush: false);
      }
      if (raw.containsKey('ping_options')) {
        await SettingsStorage.savePingOptions(
            await SettingsStorage.getPingOptions());
      }
      await SettingsStorage.flushToDisk();
      t('flushed');

      final written = await box.settingsFile.readAsString();
      final reread = jsonDecode(written) as Map<String, dynamic>;
      final expectation = {
        'migration': report.toReportJson(),
        'migrated_file_is_report_doc':
            jsonEncode(_withoutSplitIds(jsonDecode(migratedText))) ==
                jsonEncode(_withoutSplitIds(report.doc)),
        'content_diff': jsonDiff(jsonDecode(migratedText), reread),
        'bytes_identical': written == migratedText,
      };
      expectGolden('$name.storage_roundtrip.json', prettyJson(expectation));
    });
  }
}

/// Документ без `id` записей `rules[]`, заведённых делением json-массива
/// (`<имя> #N`): миграция выдаёт им новый `id` при каждом прогоне.
Object? _withoutSplitIds(Object? doc) {
  if (doc is! Map) return doc;
  final rules = doc['rules'];
  if (rules is! List) return doc;
  final split = RegExp(r' #\d+$');
  return {
    ...doc,
    'rules': [
      for (final r in rules)
        if (r is Map && r['name'] is String && split.hasMatch(r['name'] as String))
          {...r}..remove('id')
        else
          r,
    ],
  };
}
