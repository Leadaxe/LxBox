import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/direction_mutations.dart';
import 'package:lxbox/services/settings_storage.dart';

import 'golden_harness.dart';

// §439 волна 0 — фикстура хранения читается текущим `SettingsStorage` без
// потерь: все сущности проходят типизированные геттеры и сейверы (модели
// `fromJson` → `toJson`), и файл после записи сверяется с фикстурой. Это
// доказательство, что фикстура — настоящая форма 2.23.2, на которую
// опираются golden конфига и бэкапа. Эталон
// `golden/<name>.storage_roundtrip.json`: разница содержимого и совпадение
// байтов.

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

      final raw = jsonDecode(await fixtureFile(name).readAsString())
          as Map<String, dynamic>;

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
      if (raw.containsKey('dns_options')) {
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
      // Ожидание: разница содержимого (пусто — фикстура проходит модели без
      // потерь) и совпадение байтов, то есть порядка ключей и форматирования
      // `_atomicSave`. Непустая разница — нормализация записи, которая есть
      // уже сегодня; волны 439 её не расширяют.
      final expectation = {
        'content_diff': jsonDiff(raw, reread),
        'bytes_identical': written == await fixtureFile(name).readAsString(),
      };
      expectGolden('$name.storage_roundtrip.json', prettyJson(expectation));
    });
  }
}
