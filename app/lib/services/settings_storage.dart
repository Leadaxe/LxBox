import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/custom_rule.dart';
import '../models/server_list.dart';
import 'app_log.dart';
import 'migration/proxy_source_migration.dart';

part 'settings_storage/io.dart';
part 'settings_storage/vars.dart';
part 'settings_storage/sources_rules.dart';
part 'settings_storage/network.dart';
part 'settings_storage/backup_tun.dart';

/// Persistent storage for user settings: vars, proxy sources, enabled rules.
///
/// **Convention для list getters**: возвращаем **growable** list (`toList()`)
/// чтобы caller'ы могли делать `removeWhere`/`add` для optimistic UI update
/// (особенно в setState callbacks — иначе silent `UnsupportedError`).
/// Если нужна read-only гарантия — caller оборачивает в `UnmodifiableListView`.
/// `toList(growable: false)` приводил к Phase 3 bug в `wifi_history` Pick
/// saved sheet (см. commit `04ba3ce` follow-up).
///
/// **Структура файла**: реализация разнесена `part`'ами по доменам (та же
/// библиотека, тот же класс, идентичный доступ к приватным статикам):
///   • `io.dart`           — atomic load/save/recovery (§072) + кэш-инфра
///   • `vars.dart`         — vars-домен + var-backed feature-флаги
///   • `sources_rules.dart`— server lists, enabled rules/groups, custom rules
///   • `network.dart`      — route final, excluded nodes, DNS, ping-options
///   • `backup_tun.dart`   — backup snapshot (§031) + tun-apps (§046)
class SettingsStorage {
  SettingsStorage._();

  static const _fileName = 'lxbox_settings.json';
  static const _bakSuffix = '.bak';
  static const _tmpSuffix = '.tmp';
  static Map<String, dynamic>? _cache;
  static Future<void>? _pendingSave;

  /// §072 — sticky флаг что main файл был повреждён и .bak не помог.
  /// Используется чтобы:
  ///   (а) логировать факт повреждения ровно один раз за сессию (см.
  ///       `_corruptionLogged`),
  ///   (б) дать диагностикам/тестам способ узнать произошёл ли drop.
  /// **Не блокирует** последующие записи — `_save()` после первого
  /// успешного write флаг сбрасывает. Defaultнутый `_cache = {}` после
  /// drop'а сохраняется только если юзер начал что-то записывать заново
  /// (что и означает «хочу заново»).
  static bool _mainIsCorrupted = false;
  static bool _corruptionLogged = false;

  /// Test-only: drop in-memory cache so the next read goes back to disk.
  /// Used by unit tests that rotate `getApplicationDocumentsPath()` between
  /// runs to keep storage isolated.
  static void resetCacheForTesting() {
    _cache = null;
    _pendingSave = null;
    _mainIsCorrupted = false;
    _corruptionLogged = false;
  }

  /// §072 — true если последний `_load()` обнаружил битый main и не смог
  /// восстановить из `.bak`. Сбрасывается на первой успешной записи
  /// (юзер начал заново вводить данные).
  static bool get mainIsCorruptedForTesting => _mainIsCorrupted;

  /// Clears the in-memory cache (useful for tests).
  static void clearCache() => _cache = null;

  /// §107 — дисковый flush staged-изменений. Lazy-экраны (LazyPersistMixin /
  /// settings_screen Core vars) пишут мутации в `_cache` сразу через
  /// `setX(..., flush: false)`, а на диск — одним атомарным `_save()` на
  /// dispose/paused. No-op если `_cache` ещё не загружен (нечего флашить).
  static Future<void> flushToDisk() async {
    if (_cache == null) return;
    await _save();
  }

  // ---------------------------------------------------------------------------
  // Vars
  // ---------------------------------------------------------------------------

  static Future<String> getVar(String name, String defaultValue) =>
      _getVar(name, defaultValue);

  /// `flush: false` (§107) — staged-запись: обновляет только in-memory
  /// `_cache`, дисковый `_save()` откладывается до [flushToDisk].
  static Future<void> setVar(String name, String value,
          {bool flush = true}) =>
      _setVar(name, value, flush: flush);

  static Future<Map<String, String>> getAllVars() => _getAllVars();

  /// Удаляет var из storage. Разница с `setVar(k, '')`:
  /// пустая строка — legitimate value, `getVar(k, default)` возвращает `''`;
  /// `removeVar` → ключ отсутствует, `getVar(k, default)` возвращает default.
  /// Используется в Debug API `DELETE /settings/vars/{key}`.
  static Future<void> removeVar(String name) => _removeVar(name);

  // ---------------------------------------------------------------------------
  // Server lists (v2). Ключ на диске: `server_lists`.
  // ---------------------------------------------------------------------------

  static Future<List<ServerList>> getServerLists() => _getServerLists();

  static Future<void> saveServerLists(List<ServerList> lists) =>
      _saveServerLists(lists);

  // ---------------------------------------------------------------------------
  // Enabled selectable rules
  // ---------------------------------------------------------------------------

  static Future<Set<String>> getEnabledRules() => _getEnabledRules();

  static Future<void> saveEnabledRules(Set<String> rules) =>
      _saveEnabledRules(rules);

  // ---------------------------------------------------------------------------
  // Enabled preset groups
  // ---------------------------------------------------------------------------

  static Future<Set<String>> getEnabledGroups() => _getEnabledGroups();

  static Future<void> saveEnabledGroups(Set<String> groups,
          {bool flush = true}) =>
      _saveEnabledGroups(groups, flush: flush);

  // ---------------------------------------------------------------------------
  // Last global update timestamp
  // ---------------------------------------------------------------------------

  static Future<DateTime?> getLastGlobalUpdate() => _getLastGlobalUpdate();

  static Future<void> setLastGlobalUpdate(DateTime dt) =>
      _setLastGlobalUpdate(dt);

  /// Parses a Go-style duration string like "4h", "12h", "30m" into a [Duration].
  static Duration? parseReloadInterval(String reload) =>
      _parseReloadInterval(reload);

  /// Returns true if subscriptions should be refreshed based on the reload interval.
  static Future<bool> shouldRefreshSubscriptions(String reloadInterval) =>
      _shouldRefreshSubscriptions(reloadInterval);

  // ---------------------------------------------------------------------------
  // Rule outbounds: Map<ruleLabel, outboundTag>
  // ---------------------------------------------------------------------------

  static Future<Map<String, String>> getRuleOutbounds() => _getRuleOutbounds();

  static Future<void> saveRuleOutbounds(Map<String, String> outbounds) =>
      _saveRuleOutbounds(outbounds);

  // ---------------------------------------------------------------------------
  // Custom rules (§030) — единая модель для domain/IP/port/package/protocol/srs.
  // Per-app rules сюда же (поле `packages`), отдельного типа больше нет.
  // ---------------------------------------------------------------------------

  static Future<List<CustomRule>> getCustomRules() => _getCustomRules();

  static Future<void> saveCustomRules(List<CustomRule> rules,
          {bool flush = true}) =>
      _saveCustomRules(rules, flush: flush);

  /// Флаг one-shot миграции `enabled_rules` + `rule_outbounds` → `custom_rules`.
  /// Выставляется после первого прохода миграции в `RoutingScreen._load`.
  static Future<bool> hasPresetsMigrated() => _hasPresetsMigrated();

  static Future<void> markPresetsMigrated() => _markPresetsMigrated();

  // ---------------------------------------------------------------------------
  // Route final outbound
  // ---------------------------------------------------------------------------

  static Future<String> getRouteFinal() => _getRouteFinal();

  static Future<void> saveRouteFinal(String outbound, {bool flush = true}) =>
      _saveRouteFinal(outbound, flush: flush);

  static Future<Set<String>> getExcludedNodes() => _getExcludedNodes();

  static Future<void> saveExcludedNodes(Set<String> excluded) =>
      _saveExcludedNodes(excluded);

  // §100 — персист сортировки нод (имя режима + порядок ручной сортировки).
  static Future<({String mode, List<String> order})> getNodeSort() async {
    final c = await _load();
    final raw = c['node_manual_order'];
    return (
      mode: c['node_sort_mode'] as String? ?? '',
      order: raw is List ? raw.whereType<String>().toList() : const <String>[],
    );
  }

  static Future<void> setNodeSort(String mode, List<String> order) async {
    final c = await _load();
    c['node_sort_mode'] = mode;
    c['node_manual_order'] = List<String>.from(order);
    await _save();
  }

  static Future<List<Map<String, dynamic>>> getDnsServers() => _getDnsServers();

  static Future<void> saveDnsServers(List<Map<String, dynamic>> servers,
          {bool flush = true}) =>
      _saveDnsServers(servers, flush: flush);

  // ---------------------------------------------------------------------------
  // Ping/test options (§040)
  // ---------------------------------------------------------------------------

  /// Возвращает raw `ping_options` Map (= storage). Empty map если не set —
  /// caller должен fallback'нуться на template default.
  static Future<Map<String, dynamic>> getPingOptions() => _getPingOptions();

  /// Сохраняет всю structure целиком (atomic). Caller передаёт final shape —
  /// ничего не мерджится, только overwrite. Для частичных изменений см.
  /// [setGlobalPingUrl] / [setGroupPing] / [clearGroupPing].
  static Future<void> savePingOptions(Map<String, dynamic> options) =>
      _savePingOptions(options);

  /// Sugared: установить global URL без затирания timeout / groups.
  static Future<void> setGlobalPingUrl(String url) => _setGlobalPingUrl(url);

  /// Sugared: установить global timeout (ms) без затирания url / groups.
  static Future<void> setGlobalPingTimeout(int timeoutMs) =>
      _setGlobalPingTimeout(timeoutMs);

  /// Sugared: установить per-group override. Передаётся одно из / оба из
  /// `url` / `timeoutMs`; nil-аргументы не трогают существующее. Создаёт
  /// `groups[tag]` если не было.
  static Future<void> setGroupPing(
    String groupTag, {
    String? url,
    int? timeoutMs,
  }) =>
      _setGroupPing(groupTag, url: url, timeoutMs: timeoutMs);

  /// Sugared: убрать override этой группы целиком. No-op если не было.
  static Future<void> clearGroupPing(String groupTag) =>
      _clearGroupPing(groupTag);

  /// DEPRECATED (§061 dns-rules-refactor, бывший feature §041): legacy
  /// `dns_options.rules_json` — single JSON-string override. Заменён на
  /// структурированный [getDnsRulesList]. Поле в storage остаётся для
  /// downgrade-friendliness, но билдер и UI больше не читают.
  @Deprecated('Use getDnsRulesList()/saveDnsRulesList() instead. See task 061.')
  static Future<String> getDnsRules() => _getDnsRules();

  /// DEPRECATED (§061 dns-rules-refactor, бывший feature §041): см. [getDnsRules].
  @Deprecated('Use getDnsRulesList()/saveDnsRulesList() instead. See task 061.')
  static Future<void> saveDnsRules(String rulesJson) => _saveDnsRules(rulesJson);

  /// Структурированный список DNS-правил (§061 dns-rules-refactor, бывший feature §041). Каждая запись:
  /// `{enabled: bool, type: 'user'|'template'|'rule', title: String, rule?: Map}`.
  /// Если ключ отсутствует — возвращает пустой список (auto-discovery в
  /// builder/UI заполнит начальный набор).
  static Future<List<Map<String, dynamic>>> getDnsRulesList() =>
      _getDnsRulesList();

  /// Сохраняет структурированный список DNS-правил. Caller отвечает за
  /// orphan-cleanup (§061) — выбрасывание `type: template/rule` чьи titles
  /// не находятся в текущем шаблоне / активных пресетах. Этот метод просто
  /// пишет, что дали.
  static Future<void> saveDnsRulesList(List<Map<String, dynamic>> rules,
          {bool flush = true}) =>
      _saveDnsRulesList(rules, flush: flush);

  // ---------------------------------------------------------------------------
  // Auto-update subscriptions (§027) — global on/off gate. Manual refresh
  // работает всегда; affects только автоматические триггеры (appStart /
  // vpnConnected / periodic / vpnStopped).
  // ---------------------------------------------------------------------------

  static Future<bool> getAutoUpdateSubs() async =>
      (await getVar('auto_update_subs', 'true')) != 'false';

  static Future<void> setAutoUpdateSubs(bool enabled) =>
      setVar('auto_update_subs', enabled ? 'true' : 'false');

  // ---------------------------------------------------------------------------
  // §037: Config lock for Debug API. Когда true — `generateConfig()` возвращает
  // null silently, любые UI-rebuild'ы skipped. Используется когда юзер pin'ит
  // свой config через `PUT /config` для экспериментов с фичами которые
  // parser/builder не понимают (Tailscale outbound, custom DNS shapes etc).
  // Default false — обычный flow.
  // ---------------------------------------------------------------------------

  static Future<bool> getConfigLockedForDebug() async =>
      (await getVar('config_locked_for_debug', 'false')) == 'true';

  static Future<void> setConfigLockedForDebug(bool locked) =>
      setVar('config_locked_for_debug', locked ? 'true' : 'false');

  // ---------------------------------------------------------------------------
  // §051 Phase 2 — Wi-Fi network history (для CustomRuleEditScreen «Pick saved»).
  //
  // Локальная история сетей которые юзер когда-либо прокинул через Add current
  // / Manual в каком-либо custom rule. Stays in app private storage, никуда не
  // уходит. Cap 50 entries, evict oldest by `lastSeen`.
  //
  // Schema: list of `{ssid, bssid, last_seen}` (last_seen — ISO8601 UTC).
  // ---------------------------------------------------------------------------

  static const int _wifiHistoryCap = 50;

  static Future<List<Map<String, String>>> getWifiHistory() => _getWifiHistory();

  /// Upsert по composite key `(ssid, bssid)`. Если уже есть — обновляет
  /// `last_seen`. Иначе добавляет в начало списка. Cap 50 (evict oldest).
  static Future<void> addToWifiHistory(String ssid, String bssid) =>
      _addToWifiHistory(ssid, bssid);

  static Future<void> removeFromWifiHistory(String ssid, String bssid) =>
      _removeFromWifiHistory(ssid, bssid);

  static Future<void> clearWifiHistory() => setVar('wifi_history', '[]');

  /// §051 Phase 3 — flag для auto-record visited Wi-Fi networks в
  /// `wifi_history`. Default false — silent network logging это privacy
  /// след даже local-only. Юзер включает в Settings → Diagnostics когда
  /// захочет. Stickiness threshold 5 минут (см. `WifiNetworkObserver`).
  static Future<bool> getAutoRecordWifi() async =>
      (await getVar('auto_record_wifi_history', 'false')) == 'true';

  static Future<void> setAutoRecordWifi(bool enabled) =>
      setVar('auto_record_wifi_history', enabled ? 'true' : 'false');

  // ---------------------------------------------------------------------------
  // App update check (§036) — GitHub Releases polling on launch with 24h cap.
  // Sideload-flow: SnackBar → user opens release page in browser → downloads
  // APK manually. No in-app installer.
  // ---------------------------------------------------------------------------

  static Future<bool> getAutoCheckUpdates() async =>
      (await getVar('auto_check_updates', 'true')) != 'false';

  static Future<void> setAutoCheckUpdates(bool enabled) =>
      setVar('auto_check_updates', enabled ? 'true' : 'false');

  static Future<DateTime?> getLastUpdateCheck() async {
    final raw = await getVar('last_update_check_at', '');
    return raw.isEmpty ? null : DateTime.tryParse(raw);
  }

  static Future<void> setLastUpdateCheck(DateTime dt) =>
      setVar('last_update_check_at', dt.toUtc().toIso8601String());

  /// Cached latest release tag — снэкбар при следующем запуске показываем
  /// сразу, не ждём сетевого fetch'а.
  static Future<String> getLastKnownVersion() async =>
      getVar('last_known_version', '');

  static Future<void> setLastKnownVersion(String tag) =>
      setVar('last_known_version', tag);

  /// Тег который юзер уже dismiss'нул — снэкбар для него не показываем.
  /// При новом релизе тег меняется, dismissed становится stale → показываем.
  static Future<String> getDismissedUpdateVersion() async =>
      getVar('dismissed_update_version', '');

  static Future<void> setDismissedUpdateVersion(String tag) =>
      setVar('dismissed_update_version', tag);

  // ---------------------------------------------------------------------------
  // Debug API (§031) — runtime toggle, bearer token, port.
  // ---------------------------------------------------------------------------

  static const int debugPortDefault = 9269;

  static Future<bool> getDebugEnabled() async =>
      (await getVar('debug_enabled', 'false')) == 'true';

  static Future<void> setDebugEnabled(bool enabled) =>
      setVar('debug_enabled', enabled ? 'true' : 'false');

  static Future<String> getDebugToken() async => getVar('debug_token', '');

  static Future<void> setDebugToken(String token) =>
      setVar('debug_token', token);

  static Future<int> getDebugPort() async {
    final raw = await getVar('debug_port', '$debugPortDefault');
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 1024 || parsed > 49151) {
      return debugPortDefault;
    }
    return parsed;
  }

  static Future<void> setDebugPort(int port) =>
      setVar('debug_port', port.toString());

  // ---------------------------------------------------------------------------
  // Backup snapshot (§031) — dump/export/replace всего `lxbox_settings.json`.
  // ---------------------------------------------------------------------------

  /// Снимок всего `_cache` для `/state/storage` (§031). Возвращает
  /// глубокую копию — сериализатор сам фильтрует по allow-list,
  /// чтобы не утекли чувствительные поля (debug_token, subscription URLs).
  static Future<Map<String, dynamic>> dumpCache() => _dumpCache();

  /// Backup: глубокая копия всего `lxbox_settings.json` для export'а через
  /// [BackupService]. Возвращает то же что [dumpCache] — alias для ясности
  /// семантики на call-site.
  static Future<Map<String, dynamic>> exportRaw() => dumpCache();

  /// Backup: применить snapshot целиком. `merge=false` (default) — replace
  /// (overwrite cache + flush на disk), `merge=true` — top-level merge:
  /// присутствующие в [snapshot] ключи overwrite, отсутствующие — keep.
  /// `vars` мерджится recursively (subkey-level upsert) при `merge=true`.
  static Future<void> replaceRaw(
    Map<String, dynamic> snapshot, {
    bool merge = false,
  }) =>
      _replaceRaw(snapshot, merge: merge);

  // ---------------------------------------------------------------------------
  // Tunnel apps — OS-level split-tunneling (§046)
  //
  // Storage shape: `{mode: "off"|"allow"|"deny", packages: [pkg, ...]}`.
  // Builder transforms into `inbound[tun].include_package` (mode=allow) или
  // `exclude_package` (mode=deny); mode=off → ничего не пишем (sing-box default
  // = всё через tun).
  //
  // Native слой (BoxVpnService.kt:557-560) уже умеет — просто читает
  // `options.includePackage`/`excludePackage` от libbox и зовёт
  // `VpnService.Builder.addAllowedApplication`/`addDisallowedApplication`.
  // applies на `builder.establish()` — на изменение нужен FULL VPN restart.
  // ---------------------------------------------------------------------------

  static const _tunAppsModeOff = 'off';
  static const _tunAppsModeAllow = 'allow';
  static const _tunAppsModeDeny = 'deny';

  /// Возвращает текущий tun-apps config. Default: `{mode: 'off', packages: []}`
  /// — backward-compat для existing юзеров.
  static Future<TunAppsConfig> getTunApps() => _getTunApps();

  /// Persist `tun_apps`. Caller передаёт финальный shape, мы только проверяем
  /// валидность. Дубликаты в `packages` schлопываются (idempotent).
  static Future<void> setTunApps(TunAppsConfig cfg, {bool flush = true}) =>
      _setTunApps(cfg, flush: flush);
}
