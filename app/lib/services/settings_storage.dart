import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import '../models/background_mode.dart';
import '../models/channel.dart';
import '../models/memory_limit_setting.dart';
import '../models/custom_rule.dart';
import '../models/parser_config.dart';
import '../models/server_list.dart';
import '../vpn/box_vpn_client.dart';
import 'app_log.dart';
import 'config_dirty_check.dart';
import 'l10n/app_language_reconcile.dart';
import 'template_loader.dart';
import 'warp/masque_account.dart';
import 'warp/warp_account.dart';

part 'settings_storage/io.dart';
part 'settings_storage/vars.dart';
part 'settings_storage/sources_rules.dart';
part 'settings_storage/channels.dart';
part 'settings_storage/network.dart';
part 'settings_storage/backup_tun.dart';
part 'settings_storage/vpn_mode.dart';
part 'settings_storage/warp.dart';
part 'settings_storage/native_prefs.dart';

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
  // §141 P1.5 — монотонный суффикс tmp-файлов. Два перекрывающихся `_save()`
  // раньше писали в ОДИН фиксированный `.tmp` и оба делали `tmp.rename(main)`;
  // второй rename бросал `PathNotFoundException` (первый уже консумировал tmp)
  // как unhandled async. Уникальный per-write tmp (эталон — HttpCache._tmpSeq)
  // развязывает их: каждый save renamуется из своего файла. Last-writer-wins
  // на main безвреден — оба пишут консистентный снимок общего `_cache`.
  static int _tmpSeq = 0;
  static Map<String, dynamic>? _cache;
  static Future<void>? _pendingSave;

  // ---------------------------------------------------------------------------
  // §113 — config-dirty флаг живёт здесь (в объекте, где меняются настройки),
  // а не на SubscriptionController. `configDirty` контроллера — делегат сюда,
  // так что все существующие read/write-сайты работают без правок.
  //
  // Поднимается автоматически config-значимыми сейверами (`markConfigDirty`):
  // типизированные сейверы целиком, `setVar` — только для config-vars из
  // [_configVarKeys]. Снимается успешной пересборкой (контроллер ставит
  // `configDirty = false`). При снятом флаге `_save()` выравнивает mtime
  // конфига (`ConfigDirtyCheck.touchConfig`) — см. §113 spec.
  // ---------------------------------------------------------------------------
  /// Текущее значение config-dirty (sync). Читают home/контроллер/debug;
  /// пересборка ставит false; bootstrap mtime-compare и узловые правки — true.
  /// Config-значимые сейверы поднимают его через [markConfigDirty].
  static bool configDirty = false;

  /// Помечает конфиг грязным. Зовётся из config-значимых сейверов.
  static void markConfigDirty() => configDirty = true;

  /// §113 — template-`@var`, реально подставляемые в `config`
  /// (`wizard_template.json`), минус машинно-генерируемые `clash_api`/
  /// `clash_secret` (выходы сборки, не пользовательский ввод). Запись любого
  /// из этих var через `setVar` → авто-dirty.
  static const _configVarKeys = <String>{
    'auto_detect_interface',
    'dns_default_domain_resolver',
    'dns_final',
    'dns_strategy',
    'log_level',
    'resolve_strategy',
    'tun_address',
    'tun_address6',
    'tun_auto_route',
    'tun_mtu',
    'tun_name',
    'tun_stack',
    'tun_strict_route',
  };

  // ---------------------------------------------------------------------------
  // §159 — Import allowlist (default-deny). Фильтр на ВХОДЕ данных в storage
  // (`replaceRaw` — UI-импорт бэкапа + Debug API `POST /backup/import`): всё, что
  // не в allowlist, отбрасывается. Экспорт НЕ фильтруется — «что записали, то и
  // отдаём». Единственная машинерия чистки мусора/«мёртвых» ключей: legacy
  // DENY-`.remove()` и one-shot миграции удалены (см. spec/tasks/159).
  // ---------------------------------------------------------------------------

  /// Валидные top-level ключи `lxbox_settings.json`. Полный закрытый список —
  /// все имена известны. `vars` — контейнер, его содержимое фильтруется
  /// отдельно через [allowedVarKeys]. Источник правды: STORAGE.md.
  static const allowedTopLevelKeys = <String>{
    'vars',
    'server_lists',
    'custom_rules',
    'dns_options',
    'ping_options',
    'route_final',
    'route_idle_suspend', // §215 — idle-suspend threshold (route.lx_idle_suspend)
    'route_idle_suspend_reachable', // §272 — reachable idle window (route.lx_idle_suspend_reachable)
    'urltest_passive_check', // §272 — passive health check (urltest.passive_check)
    'excluded_nodes',
    'enabled_groups', // §125 — DEPRECATED (читается только миграцией; safe-мусор)
    'channels', // §125 — каналы роутинга (template→storage)
    'channels_migrated', // §125 — guard one-shot миграции
    'tun_apps',
    'vpn_mode',
    'warp_account',
    'masque_account', // §130/§219 — MASQUE-WARP аккаунт; был в бэкапе, но не в
    //                   allowlist → терялся при restore (default-deny)
    'last_global_update',
    'presets_migrated', // §159 — переиспользуется как «дефолты засеяны» (seed guard)
    'preset_ids_remapped', // §228 legacy guard; миграция удалена в §229, ключ
    //                        сохранён (имя не переиспользовать, не мусор)
    'interrupt_connections_on_switch',
    'node_sort_mode',
    'node_manual_order',
    'profiler_retention_sec', // §044/new-profiler — окно хранения Live-журнала
  };

  /// Var-ключи, которые живут ТОЛЬКО в коде (app feature-flags), а НЕ в
  /// `wizard_template.json`. Полный allowlist для `vars` = это множество ∪
  /// `template.vars` (см. [allowedVarKeys]). Template-vars не хардкодим — их
  /// источник правды сам template (зашит в APK, см. §159).
  static const _appFeatureFlagVars = <String>{
    // Подписки (§027, §337)
    'auto_update_subs',
    'auto_update_disabled_subs',
    // Обновления приложения (§036)
    'auto_check_updates',
    'last_update_check_at',
    'last_known_version',
    'dismissed_update_version',
    // Краш-репорты ядра (§316)
    'shown_crash_stamp',
    // Debug API / config-lock (§031, §037)
    'config_locked_for_debug',
    'debug_enabled',
    'debug_token',
    'debug_port',
    // Wi-Fi history (§051)
    'wifi_history',
    'auto_record_wifi_history',
    // §236 — пороги цветовой шкалы Test servers (папки). НЕ config-vars
    // (в sing-box config не идут) → dirty не поднимают.
    'probe_ms_green',
    'probe_ms_yellow',
    'probe_ms_orange',
    // Automation API (§047)
    'automation_receive_enabled',
    'automation_emit_lifecycle',
    'automation_emit_state',
    'automation_emit_subs',
    'automation_emit_health',
    'automation_explainer_shown_v1',
    // Subscription identity headers
    'subscription_user_agent',
    'subscription_send_hwid',
    'subscription_hwid',
    'subscription_device_os',
    'subscription_ver_os',
    'subscription_device_model',
    // Прочие UI/one-shot флаги
    'haptic_enabled', // §029 — НЕ в SharedPreferences (вопреки старому STORAGE.md)
    'notif_perm_prompted_v1', // §128 — promt уведомлений показан
    'allow_rotation', // §220 — снятие портретной фиксации
    'app_language', // §279 — язык приложения (system|en|ru); НЕ config-var
  };

  /// Полный allowlist для подключей `vars` при импорте: кодовые флаги ∪ все
  /// имена vars из текущего (локального) template. Template в бэкап не входит —
  /// резолвим против зашитого в APK (§159).
  static Set<String> allowedVarKeys(Iterable<String> templateVarNames) =>
      {..._appFeatureFlagVars, ...templateVarNames};

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
    configDirty = false; // §113
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

  // §159 — getEnabledRules/saveEnabledRules удалены (legacy-миграция снята).

  // ---------------------------------------------------------------------------
  // Enabled preset groups
  // ---------------------------------------------------------------------------

  static Future<Set<String>> getEnabledGroups() => _getEnabledGroups();

  static Future<void> saveEnabledGroups(Set<String> groups,
          {bool flush = true}) =>
      _saveEnabledGroups(groups, flush: flush);

  // ---------------------------------------------------------------------------
  // §125 — Каналы роутинга (channels[]). Заменяют enabled_groups[] + статичные
  // template-пресеты как source-of-truth. На первом запуске seeded из template
  // (migrateChannelsIfNeeded; §267 — из group_templates). vpn-1 неудаляем, лимит 10.
  // ---------------------------------------------------------------------------

  static Future<List<Channel>> getChannels() => _getChannels();

  /// §292 — код приложения зовёт `ChannelMutations.bulkReplace`: bulk-overwrite
  /// мимо heal'а допустим только там, где ссылка структурно не может повиснуть
  /// (staging-буфер, reorder). Голый вызов из `lib/` — предупреждение analyze'а.
  @visibleForTesting
  static Future<void> setChannels(List<Channel> channels, {bool flush = true}) =>
      _setChannels(channels, flush: flush);

  /// Добавить канал: первый свободный 'vpn-N' (N∈2..10). Throws при лимите 10.
  ///
  /// §275 — код приложения зовёт `ChannelMutations.add`: мутаторы каналов
  /// парные с ресинком контроллера, здесь — только storage-половина.
  @visibleForTesting
  static Future<Channel> addChannel({String? label}) => _addChannel(label: label);

  /// Обновить канал по [Channel.tag]. Throws если tag не найден.
  /// §248 — возвращает счётчики вылеченных ссылок (disable/flag-set →
  /// rules-ссылки → vpn-1; disable/flag-unset → detour-ссылки → '').
  ///
  /// §275 — код приложения зовёт `ChannelMutations.update`: detour-heal ОБЯЗАН
  /// зеркалиться в `_entries` контроллера, иначе следующий `_persist()`
  /// воскресит вылеченную ссылку. Голый вызов из `lib/` — предупреждение
  /// analyze'а (это и есть страховка от «забыл ресинк»).
  @visibleForTesting
  static Future<ChannelHealResult> updateChannel(Channel channel) =>
      _updateChannel(channel);

  /// Удалить канал. Throws для 'vpn-1'. Переводит rules-ссылки на 'vpn-1',
  /// §248 detour-ссылки — на '' (None); возвращает счётчики.
  ///
  /// §275 — код приложения зовёт `ChannelMutations.delete` (см. выше).
  @visibleForTesting
  static Future<ChannelHealResult> deleteChannel(String tag) =>
      _deleteChannel(tag);

  /// One-shot миграция enabled_groups[] → channels[] (seed из template).
  /// §267 — сид из `template.groupTemplates` (default_channels + channel-шаблон).
  /// Идемпотентна. Зовётся из main() init до первого билда.
  /// §327 — `varDefaults` (имя var → `default_value`) резолвит `@urltest_*`
  /// в `group_templates.auto.options`: на этом этапе var-substitution ещё не
  /// отработала, а дефолт обязан быть один — шаблонный.
  static Future<void> migrateChannelsIfNeeded(
    GroupTemplates gt, {
    Map<String, String> varDefaults = const {},
  }) =>
      _migrateChannelsIfNeeded(gt, varDefaults: varDefaults);

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

  // §159 — getRuleOutbounds/saveRuleOutbounds удалены (legacy-миграция снята).

  // ---------------------------------------------------------------------------
  // Custom rules (§030) — единая модель для domain/IP/port/package/protocol/srs.
  // Per-app rules сюда же (поле `packages`), отдельного типа больше нет.
  // ---------------------------------------------------------------------------

  static Future<List<CustomRule>> getCustomRules() => _getCustomRules();

  static Future<void> saveCustomRules(List<CustomRule> rules,
          {bool flush = true}) =>
      _saveCustomRules(rules, flush: flush);

  /// §159 — флаг «дефолтные пресеты засеяны» (fresh-install seed). Хранится в
  /// том же ключе `presets_migrated` (см. `_hasDefaultsSeeded`).
  static Future<bool> hasDefaultsSeeded() => _hasDefaultsSeeded();

  static Future<void> markDefaultsSeeded() => _markDefaultsSeeded();

  // ---------------------------------------------------------------------------
  // Route final outbound
  // ---------------------------------------------------------------------------

  static Future<String> getRouteFinal() => _getRouteFinal();

  static Future<void> saveRouteFinal(String outbound, {bool flush = true}) =>
      _saveRouteFinal(outbound, flush: flush);

  // §215 — idle-suspend threshold (route.lx_idle_suspend, kernel SPEC 020)

  static Future<String> getIdleSuspend() => _getIdleSuspend();

  static Future<void> saveIdleSuspend(String threshold, {bool flush = true}) =>
      _saveIdleSuspend(threshold, flush: flush);

  // §272 — reachable idle window (route.lx_idle_suspend_reachable, SPEC 020)

  static Future<String> getIdleSuspendReachable() => _getIdleSuspendReachable();

  static Future<void> saveIdleSuspendReachable(String threshold,
          {bool flush = true}) =>
      _saveIdleSuspendReachable(threshold, flush: flush);

  // §272 — passive health check (urltest.passive_check, SPEC 019)

  static Future<bool> getPassiveCheck() => _getPassiveCheck();

  static Future<void> savePassiveCheck(bool enabled, {bool flush = true}) =>
      _savePassiveCheck(enabled, flush: flush);

  // §125-cleanup — excluded_nodes (§048 глобальный фильтр) удалён. Ключ остаётся
  // в allowlist (legacy backward-compat, безвредный мусор как enabled_groups).

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

  // §143 — принудительно рвать активные соединения переключаемой группы при
  // смене ноды. НЕ config-significant (поведение Clash-API клиента, не идёт в
  // sing-box config) → без markConfigDirty. Default false (opt-in).
  static Future<bool> getInterruptOnSwitch() async {
    final c = await _load();
    return c['interrupt_connections_on_switch'] == true;
  }

  static Future<void> setInterruptOnSwitch(bool value) async {
    final c = await _load();
    c['interrupt_connections_on_switch'] = value;
    SettingsStorage._cache = c;
    await _save();
  }

  /// §044/new-profiler — окно хранения Live-журнала профайлера в секундах
  /// (global rolling buffer). Не config-significant (поведение UI-буфера, не
  /// идёт в sing-box config) → без markConfigDirty. Default 600s (10 мин).
  /// Опции в UI: 60 / 600 / 3600. Дольше = больше памяти на busy device.
  static const int profilerRetentionDefaultSec = 600;

  static Future<int> getProfilerRetentionSec() async {
    final c = await _load();
    final v = c['profiler_retention_sec'];
    if (v is int && v > 0) return v;
    return profilerRetentionDefaultSec;
  }

  static Future<void> setProfilerRetentionSec(int seconds) async {
    final c = await _load();
    c['profiler_retention_sec'] = seconds;
    SettingsStorage._cache = c;
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
  ///
  /// §219 — геттер `getDnsRules()` удалён (0 call-sites). `saveDnsRules`
  /// оставлен: его дёргает legacy Debug-эндпоинт `PUT /settings/dns_options/
  /// rules`. NB: он пишет в `rules_json`, который билдер игнорирует, — эндпоинт
  /// фактически no-op; депрекация роута — отдельно (обновить help/reference).
  @Deprecated('Use saveDnsRulesList() instead. See task 061.')
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

  /// §337 — обновлять и **выключенные** подписки, чтобы их снапшот не тух до
  /// момента, когда юзер их включит. Off по умолчанию: существующие установки
  /// поведение не меняют. Живёт внутри `auto_update_subs` — при выключенном
  /// глобальном тумблере не обновляется ничего.
  static Future<bool> getAutoUpdateDisabledSubs() async =>
      (await getVar('auto_update_disabled_subs', 'false')) == 'true';

  static Future<void> setAutoUpdateDisabledSubs(bool enabled) =>
      setVar('auto_update_disabled_subs', enabled ? 'true' : 'false');

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

  /// §220 — разрешить поворот UI (landscape). Default false — жёсткий портрет,
  /// как было всегда; поведение телефонов не меняется. Toggle в App Settings →
  /// General → Behavior; применяется сразу через `applyAllowRotationSetting()`
  /// (main.dart), без рестарта.
  static Future<bool> getAllowRotation() async =>
      (await getVar('allow_rotation', 'false')) == 'true';

  static Future<void> setAllowRotation(bool enabled) =>
      setVar('allow_rotation', enabled ? 'true' : 'false');

  /// §279 — допустимые значения `app_language`. Неизвестное (hand-edited
  /// бэкап, будущие языки) → 'system'.
  static const appLanguageValues = {'system', 'en', 'ru'};

  /// §279 — язык приложения. Default 'system' — следовать языку устройства.
  /// Запись из кода приложения — только через LocaleController.set()
  /// (владелец пайплайна); прямой setAppLanguage — storage-половина.
  static Future<String> getAppLanguage() async {
    final v = await getVar('app_language', 'system');
    return appLanguageValues.contains(v) ? v : 'system';
  }

  static Future<void> setAppLanguage(String value) async {
    final v = appLanguageValues.contains(value) ? value : 'system';
    await setVar('app_language', v);
    await _mirrorAppLanguageToNative(v);
  }

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
  // Краш-репорты ядра (§316) — отметка «про этот краш уже сказали».
  // ---------------------------------------------------------------------------

  /// Штамп (`имя@mtime`, см. `CrashReports.stamp`) последнего краш-репорта,
  /// про который баннер уже показали. Привязка к КОНКРЕТНОМУ файлу, а не
  /// счётчик показов: повторный запуск молчит, новый краш — говорит.
  static Future<String> getShownCrashStamp() async =>
      getVar('shown_crash_stamp', '');

  static Future<void> setShownCrashStamp(String stamp) =>
      setVar('shown_crash_stamp', stamp);

  // ---------------------------------------------------------------------------
  // Debug API (§031) — runtime toggle, bearer token, port.
  // ---------------------------------------------------------------------------

  static const int debugPortDefault = 9269;

  /// §141 P2.4d — допустимый диапазон Debug API-порта. Раньше `1024`/`49151`
  /// были захардкожены в 3 местах (этот валидатор, app_settings_screen,
  /// diagnostics_tab helperText). Единый источник.
  static const int debugPortMin = 1024;
  static const int debugPortMax = 49151;

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
    if (parsed == null || parsed < debugPortMin || parsed > debugPortMax) {
      return debugPortDefault;
    }
    return parsed;
  }

  static Future<void> setDebugPort(int port) =>
      setVar('debug_port', port.toString());

  // ---------------------------------------------------------------------------
  // Automation API (§047) — public broadcast intents (Tasker / Macrodroid).
  //
  // Все ключи default false — фича opt-in, по умолчанию receiver disabled и
  // эмиттер молчит. Барьер приёма — мастер-toggle (receiver enabled=false).
  // Per-app пропуск удалён (§157 — permission-чек в broadcast недетерминирован).
  // ---------------------------------------------------------------------------

  /// Мастер-toggle приёма команд автоматизации. При смене вызывается
  /// `setComponentEnabledSetting` на native — receiver включается/выключается.
  static Future<bool> getAutomationReceiveEnabled() async =>
      (await getVar('automation_receive_enabled', 'false')) == 'true';

  static Future<void> setAutomationReceiveEnabled(bool enabled) =>
      setVar('automation_receive_enabled', enabled ? 'true' : 'false');

  /// Emit-категория: lifecycle (VPN_CONNECTED/DISCONNECTED/ERROR/REVOKED +
  /// UPDATE_AVAILABLE/PERMISSION_NEEDED).
  static Future<bool> getAutomationEmitLifecycle() async =>
      (await getVar('automation_emit_lifecycle', 'false')) == 'true';

  static Future<void> setAutomationEmitLifecycle(bool enabled) =>
      setVar('automation_emit_lifecycle', enabled ? 'true' : 'false');

  /// Emit-категория: state (ACTIVE_NODE_CHANGED / ACTIVE_GROUP_CHANGED).
  static Future<bool> getAutomationEmitState() async =>
      (await getVar('automation_emit_state', 'false')) == 'true';

  static Future<void> setAutomationEmitState(bool enabled) =>
      setVar('automation_emit_state', enabled ? 'true' : 'false');

  /// Emit-категория: subscription (SUB_REFRESHED / SUB_REFRESH_FAILED).
  static Future<bool> getAutomationEmitSubs() async =>
      (await getVar('automation_emit_subs', 'false')) == 'true';

  static Future<void> setAutomationEmitSubs(bool enabled) =>
      setVar('automation_emit_subs', enabled ? 'true' : 'false');

  /// Emit-категория: health (зарезервирована под §042 watchdog).
  static Future<bool> getAutomationEmitHealth() async =>
      (await getVar('automation_emit_health', 'false')) == 'true';

  static Future<void> setAutomationEmitHealth(bool enabled) =>
      setVar('automation_emit_health', enabled ? 'true' : 'false');

  /// Флаг «explainer-диалог при первом включении emit-категории уже показан».
  static Future<bool> getAutomationExplainerShown() async =>
      (await getVar('automation_explainer_shown_v1', 'false')) == 'true';

  static Future<void> setAutomationExplainerShown(bool shown) =>
      setVar('automation_explainer_shown_v1', shown ? 'true' : 'false');

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

  /// Backup: применить snapshot. `merge=false` (default) — replace (overwrite
  /// cache + flush на disk), `merge=true` — top-level merge: присутствующие в
  /// [snapshot] ключи overwrite, отсутствующие — keep. `vars` мерджится
  /// recursively (subkey-level upsert) при `merge=true`.
  ///
  /// §159 — применяет default-deny allowlist (см. [allowedTopLevelKeys] /
  /// [allowedVarKeys]). Возвращает список **отброшенных** ключей (top-level имена
  /// + `vars.<key>` для подключей) — caller логирует в applog и показывает юзеру.
  static Future<List<String>> replaceRaw(
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

  // ---------------------------------------------------------------------------
  // VPN mode — Proxy / VPN / VPN+Proxy (§119)
  //
  // Storage shape: `{mode, proxy_port, proxy_listen, proxy_auth_enabled,
  // proxy_username, proxy_password}`. Билдер (`applyVpnMode`) трансформирует
  // config.inbounds: mode=vpn → tun (как сейчас); mode=proxy → mixed без tun
  // (libbox не зовёт openTun → нет establish); mode=vpn_proxy → tun + mixed.
  // Смена inbounds → FULL VPN restart (наследуется от config-dirty машинерии).
  // ---------------------------------------------------------------------------

  static const _vpnModeVpn = 'vpn';
  static const _vpnModeProxy = 'proxy';
  static const _vpnModeVpnProxy = 'vpn_proxy';

  /// Возвращает текущий VPN-mode config. Default: `mode=vpn` —
  /// backward-compat для existing юзеров (= текущее поведение).
  static Future<VpnModeConfig> getVpnMode() => _getVpnMode();

  /// Persist `vpn_mode`. Caller передаёт финальный shape; валидируем mode.
  static Future<void> setVpnMode(VpnModeConfig cfg, {bool flush = true}) =>
      _setVpnMode(cfg, flush: flush);

  // §189 native_prefs — JSON-зеркало Android-prefs. JSON = истина, native =
  // рабочая копия. Все писатели идут через setNativeBool/setNativeBackgroundMode
  // (write-through: JSON + зеркало в native). См. settings_storage/native_prefs.dart.
  static Future<Map<String, dynamic>> getNativePrefs() => _getNativePrefs();
  static Future<bool> getNativeBool(String key) => _getNativeBool(key);
  static Future<String> getNativeBackgroundMode() => _getNativeBackgroundMode();
  static Future<void> setNativeBool(String key, bool value) =>
      _setNativeBool(key, value);
  static Future<void> setNativeBackgroundMode(String wireValue) =>
      _setNativeBackgroundMode(wireValue);
  // §271 — memory limit ядра (wire-значения в MemoryLimitSetting).
  static Future<String> getNativeMemoryLimit() => _getNativeMemoryLimit();
  static Future<void> setNativeMemoryLimit(String wireValue) =>
      _setNativeMemoryLimit(wireValue);

  /// Старт: bootstrap (первый запуск §189 — seed native⇒JSON) или sync
  /// (JSON⇒native). Зовётся из app init до UI.
  static Future<void> bootstrapAndSyncNativePrefs() =>
      _bootstrapAndSyncNativePrefs();

  /// §189 — единая сериализация backup-блока vpn_settings (состав/дефолты/типы
  /// в одном месте). backup_service и Debug-handler делегируют сюда.
  static Future<Map<String, dynamic>> exportNativePrefsBackup() =>
      _exportToBackupMap();
  static Future<int> applyNativePrefsBackup(Map<String, dynamic> data,
          {void Function(String, Object)? onError}) =>
      _applyFromBackupMap(data, onError: onError);

  /// §192 — зеркалить has_tun (производное от vpn_mode) в native. Гейтит
  /// VpnService.prepare(). Зовётся при смене режима в Mode-вкладке.
  static Future<void> setNativeHasTun(bool hasTun) => _setNativeHasTun(hasTun);

  // ---------------------------------------------------------------------------
  // §025 — Cloudflare WARP account cache. Закешированный аккаунт переиспользуется
  // при повторном «Get WARP» (идемпотентность), null = не зарегистрирован.
  // ---------------------------------------------------------------------------

  /// Закешированный WARP-аккаунт или null.
  static Future<WarpAccount?> getWarpAccount() => _getWarpAccount();

  /// Persist (или очистить при null) WARP-аккаунт.
  static Future<void> setWarpAccount(WarpAccount? account,
          {bool flush = true}) =>
      _setWarpAccount(account, flush: flush);

  /// §130 — закешированный MASQUE-WARP аккаунт или null.
  static Future<MasqueAccount?> getMasqueAccount() => _getMasqueAccount();

  /// §130 — persist (или очистить при null) MASQUE-WARP аккаунт.
  static Future<void> setMasqueAccount(MasqueAccount? account,
          {bool flush = true}) =>
      _setMasqueAccount(account, flush: flush);
}
