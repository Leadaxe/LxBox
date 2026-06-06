import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/custom_rule.dart';
import '../models/server_list.dart';
import 'app_log.dart';
import 'migration/proxy_source_migration.dart';

/// Persistent storage for user settings: vars, proxy sources, enabled rules.
///
/// **Convention для list getters**: возвращаем **growable** list (`toList()`)
/// чтобы caller'ы могли делать `removeWhere`/`add` для optimistic UI update
/// (особенно в setState callbacks — иначе silent `UnsupportedError`).
/// Если нужна read-only гарантия — caller оборачивает в `UnmodifiableListView`.
/// `toList(growable: false)` приводил к Phase 3 bug в `wifi_history` Pick
/// saved sheet (см. commit `04ba3ce` follow-up).
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

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<File> _bakFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName$_bakSuffix');
  }

  static Future<File> _tmpFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName$_tmpSuffix');
  }

  /// §072 — попытаться прочитать файл как JSON Map. Возвращает `null` в
  /// четырёх случаях: файл отсутствует / пустой / не Map / FormatException
  /// при парсе. Все «не валидно» сводятся к одному `null` — caller сам
  /// решает что делать (для main → пробовать `.bak`).
  static Future<Map<String, dynamic>?> _tryParseFile(File f) async {
    if (!await f.exists()) return null;
    try {
      final raw = await f.readAsString();
      if (raw.isEmpty) return null;
      final parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) return parsed;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// §072 — Decision tree:
  ///   main отсутствует   → `{}` (fresh install)
  ///   main парсится      → return parsed
  ///   main битый, bak ok → recover из bak, log warning
  ///   main битый, bak no → `{}` + sticky `_mainIsCorrupted` flag, log error.
  ///                        Main файл НЕ перезаписывается на этом этапе —
  ///                        оставляем для ручной диагностики.
  static Future<Map<String, dynamic>> _load() async {
    if (_cache != null) return _cache!;
    // Wait for any pending save to complete before loading
    if (_pendingSave != null) await _pendingSave;

    // Если path provider недоступен (binding не инициализирован в тестах,
    // platform unsupported и т.п.) — degrade к `{}`. Это сохраняет
    // legacy-семантику оригинального `_load` (try-catch вокруг всего тела).
    try {
      final main = await _file();
      final bak = await _bakFile();
      final tmp = await _tmpFile();

      // Best-effort: убираем `.tmp` от прошлого оборванного `_save()`.
      // Rename консумирует `.tmp` при success — наличие файла значит save
      // был убит. Содержимое не консистентно (partial write), нельзя
      // использовать для recovery.
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {
          // ignore — не критично
        }
      }

      // 1. Main отсутствует → fresh install.
      if (!await main.exists()) {
        _cache = {};
        return _cache!;
      }

      // 2. Main парсится → ok.
      final mainParsed = await _tryParseFile(main);
      if (mainParsed != null) {
        _cache = mainParsed;
        return _cache!;
      }

      // 3. Main битый. Пробуем `.bak`.
      final bakParsed = await _tryParseFile(bak);
      if (bakParsed != null) {
        AppLog.I.warning(
          'SettingsStorage: main file corrupted, recovered from .bak '
          '(${main.path})',
        );
        _cache = bakParsed;
        // НЕ зовём _save() здесь — `_cache` уже консистентный, любой
        // последующий setVar пройдёт через атомарный `_save`. Если
        // процесс убьют до этого — следующий `_load` тот же recovery
        // повторит (идемпотентно).
        return _cache!;
      }

      // 4. Main битый, bak не помог → drop с sticky flag.
      _mainIsCorrupted = true;
      if (!_corruptionLogged) {
        _corruptionLogged = true;
        AppLog.I.error(
          'SettingsStorage: main file corrupted, no recoverable .bak. '
          'Settings reset to defaults; main file left on disk for diagnostics '
          '(${main.path})',
        );
      }
      _cache = {};
      return _cache!;
    } catch (_) {
      // Path provider или filesystem unavailable — degrade к defaultам.
      _cache = {};
      return _cache!;
    }
  }

  /// §072 — атомарная запись:
  ///   1. Copy валидного main → `.bak` (если main существует и валиден).
  ///   2. Write новых данных в `.tmp` с `flush: true`.
  ///   3. `tmp.rename(main)` — POSIX rename(2), атомарный в пределах одной
  ///      FS. `getApplicationDocumentsDirectory()` это всегда app-internal
  ///      storage (ext4/f2fs) → single mount → safe.
  ///
  /// Если kill попадёт:
  ///   • между copy и tmp-write → main целый, .bak старый. Потерь нет.
  ///   • между tmp-write и rename → main целый, .bak старый. Новые данные
  ///     потеряны, но старые сохранены. Acceptable.
  ///   • во время rename — это atomic syscall, либо main old либо main new.
  static Future<void> _save() async {
    // Clean up removed keys (legacy schema cruft).
    _cache?.remove('node_overrides');
    _cache?.remove('show_detour_servers');
    final data = Map<String, dynamic>.from(_cache ?? {});

    final main = await _file();
    final bak = await _bakFile();
    final tmp = await _tmpFile();

    _pendingSave = _atomicSave(data, main: main, bak: bak, tmp: tmp);
    await _pendingSave;
    _pendingSave = null;
  }

  static Future<void> _atomicSave(
    Map<String, dynamic> data, {
    required File main,
    required File bak,
    required File tmp,
  }) async {
    final encoded = const JsonEncoder.withIndent('  ').convert(data);

    // 1. Snapshot текущий **валидный** main → .bak. Битый main не копируем —
    //    нет смысла плодить второй битый файл, лучше оставить старый .bak
    //    если он был (он от ещё более раннего, но валидного состояния).
    if (await main.exists()) {
      final mainParsed = await _tryParseFile(main);
      if (mainParsed != null) {
        try {
          await main.copy(bak.path);
        } catch (_) {
          // best-effort — не блокируем save если copy не получился
          // (acceptable: новые данные всё равно перезапишут main атомарно).
        }
      }
    }

    // 2. Write в tmp с flush. Без flush rename может зафиксировать pointer
    //    на ещё не сброшенные dirty pages → видимо как пустой/обрезанный
    //    файл при kill сразу после rename.
    await tmp.writeAsString(encoded, flush: true);

    // 3. Атомарная замена.
    await tmp.rename(main.path);

    // 4. Main теперь свежий и валидный — сбрасываем sticky-флаги.
    //    Следующий `_load()` (после `resetCacheForTesting` или рестарта
    //    процесса) увидит чистый main и не пойдёт через corruption path.
    _mainIsCorrupted = false;
    _corruptionLogged = false;
  }

  // ---------------------------------------------------------------------------
  // Vars
  // ---------------------------------------------------------------------------

  static Future<String> getVar(String name, String defaultValue) async {
    final data = await _load();
    final vars = data['vars'] as Map<String, dynamic>? ?? {};
    return vars[name]?.toString() ?? defaultValue;
  }

  static Future<void> setVar(String name, String value) async {
    final data = await _load();
    final vars = (data['vars'] as Map<String, dynamic>?) ?? {};
    vars[name] = value;
    data['vars'] = vars;
    _cache = data;
    await _save();
  }

  static Future<Map<String, String>> getAllVars() async {
    final data = await _load();
    final vars = data['vars'] as Map<String, dynamic>? ?? {};
    return vars.map((k, v) => MapEntry(k, v.toString()));
  }

  /// Удаляет var из storage. Разница с `setVar(k, '')`:
  /// пустая строка — legitimate value, `getVar(k, default)` возвращает `''`;
  /// `removeVar` → ключ отсутствует, `getVar(k, default)` возвращает default.
  /// Используется в Debug API `DELETE /settings/vars/{key}`.
  static Future<void> removeVar(String name) async {
    final data = await _load();
    final vars = data['vars'] as Map<String, dynamic>?;
    if (vars == null || !vars.containsKey(name)) return;
    vars.remove(name);
    data['vars'] = vars;
    _cache = data;
    await _save();
  }

  // ---------------------------------------------------------------------------
  // Server lists (v2). Ключ на диске: `server_lists`.
  //
  // Миграция с v1 (`proxy_sources`): при первом чтении, если старый ключ
  // есть и новый пустой — конвертируем через `migrateProxySources`, пишем
  // в новый ключ, старый удаляем. Необратимо.
  // ---------------------------------------------------------------------------

  static Future<List<ServerList>> getServerLists() async {
    final data = await _load();
    final v2 = data['server_lists'] as List<dynamic>?;
    if (v2 != null) {
      return v2
          .whereType<Map<String, dynamic>>()
          .map(ServerList.fromJson)
          .toList();
    }
    final v1 = data['proxy_sources'] as List<dynamic>?;
    if (v1 == null || v1.isEmpty) return const [];
    final migrated = migrateProxySources(
      v1.whereType<Map<String, dynamic>>().toList(),
    );
    data['server_lists'] = migrated.map((e) => e.toJson()).toList();
    data.remove('proxy_sources');
    _cache = data;
    await _save();
    return migrated;
  }

  static Future<void> saveServerLists(List<ServerList> lists) async {
    final data = await _load();
    data['server_lists'] = lists.map((e) => e.toJson()).toList();
    data.remove('proxy_sources');
    _cache = data;
    await _save();
  }

  // ---------------------------------------------------------------------------
  // Enabled selectable rules
  // ---------------------------------------------------------------------------

  static Future<Set<String>> getEnabledRules() async {
    final data = await _load();
    final list = data['enabled_rules'] as List<dynamic>? ?? [];
    return list.map((e) => e.toString()).toSet();
  }

  static Future<void> saveEnabledRules(Set<String> rules) async {
    final data = await _load();
    data['enabled_rules'] = rules.toList();
    _cache = data;
    await _save();
  }

  // ---------------------------------------------------------------------------
  // Enabled preset groups
  // ---------------------------------------------------------------------------

  static Future<Set<String>> getEnabledGroups() async {
    final data = await _load();
    final list = data['enabled_groups'] as List<dynamic>? ?? [];
    return list.map((e) => e.toString()).toSet();
  }

  static Future<void> saveEnabledGroups(Set<String> groups) async {
    final data = await _load();
    data['enabled_groups'] = groups.toList();
    _cache = data;
    await _save();
  }

  // ---------------------------------------------------------------------------
  // Last global update timestamp
  // ---------------------------------------------------------------------------

  static Future<DateTime?> getLastGlobalUpdate() async {
    final data = await _load();
    final raw = data['last_global_update'] as String?;
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  static Future<void> setLastGlobalUpdate(DateTime dt) async {
    final data = await _load();
    data['last_global_update'] = dt.toIso8601String();
    _cache = data;
    await _save();
  }

  /// Parses a Go-style duration string like "4h", "12h", "30m" into a [Duration].
  static Duration? parseReloadInterval(String reload) {
    final trimmed = reload.trim().toLowerCase();
    if (trimmed.isEmpty) return null;
    final match = RegExp(r'^(\d+)\s*(h|m|s)$').firstMatch(trimmed);
    if (match == null) return null;
    final value = int.parse(match.group(1)!);
    return switch (match.group(2)) {
      'h' => Duration(hours: value),
      'm' => Duration(minutes: value),
      's' => Duration(seconds: value),
      _ => null,
    };
  }

  /// Returns true if subscriptions should be refreshed based on the reload interval.
  static Future<bool> shouldRefreshSubscriptions(String reloadInterval) async {
    final interval = parseReloadInterval(reloadInterval);
    if (interval == null) return false;
    final lastUpdate = await getLastGlobalUpdate();
    if (lastUpdate == null) return true;
    return DateTime.now().difference(lastUpdate) >= interval;
  }

  /// Clears the in-memory cache (useful for tests).
  static void clearCache() => _cache = null;

  // ---------------------------------------------------------------------------
  // Rule outbounds: Map<ruleLabel, outboundTag>
  // ---------------------------------------------------------------------------

  static Future<Map<String, String>> getRuleOutbounds() async {
    final data = await _load();
    final map = data['rule_outbounds'] as Map<String, dynamic>? ?? {};
    return map.map((k, v) => MapEntry(k, v.toString()));
  }

  static Future<void> saveRuleOutbounds(Map<String, String> outbounds) async {
    final data = await _load();
    data['rule_outbounds'] = outbounds;
    _cache = data;
    await _save();
  }

  // ---------------------------------------------------------------------------
  // Custom rules (§030) — единая модель для domain/IP/port/package/protocol/srs.
  // Per-app rules сюда же (поле `packages`), отдельного типа больше нет.
  // ---------------------------------------------------------------------------

  static Future<List<CustomRule>> getCustomRules() async {
    final data = await _load();
    await _absorbLegacyAppRules(data);
    final list = data['custom_rules'] as List<dynamic>? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(CustomRule.fromJson)
        .toList();
  }

  /// One-shot: legacy `app_rules` (отдельная таба до v1.3.2) → `custom_rules`
  /// с полем `packages`. Запускается один раз — после конверсии ключ удаляется.
  /// Оставлен внутри getter'а чтобы автоматически подхватиться при первом
  /// открытии Rules-таба после апдейта.
  static Future<void> _absorbLegacyAppRules(Map<String, dynamic> data) async {
    final legacy = data['app_rules'] as List<dynamic>?;
    if (legacy == null || legacy.isEmpty) return;
    final existing = (data['custom_rules'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        <Map<String, dynamic>>[];
    for (final e in legacy.whereType<Map<String, dynamic>>()) {
      final packages = (e['packages'] as List<dynamic>?)
              ?.map((p) => p.toString())
              .toList() ??
          const <String>[];
      if (packages.isEmpty) continue;
      final migrated = CustomRuleInline(
        id: (e['id'] as String?)?.trim().isNotEmpty == true
            ? e['id'] as String
            : null,
        name: (e['name'] as String?) ?? 'App group',
        enabled: (e['enabled'] as bool?) ?? true,
        packages: packages,
        outbound: (e['outbound'] as String?) ?? 'direct-out',
      );
      existing.add(migrated.toJson());
    }
    data['custom_rules'] = existing;
    data.remove('app_rules');
    _cache = data;
    await _save();
  }

  static Future<void> saveCustomRules(List<CustomRule> rules) async {
    final data = await _load();
    data['custom_rules'] = rules.map((r) => r.toJson()).toList();
    _cache = data;
    await _save();
  }

  /// Флаг one-shot миграции `enabled_rules` + `rule_outbounds` → `custom_rules`.
  /// Выставляется после первого прохода миграции в `RoutingScreen._load`.
  static Future<bool> hasPresetsMigrated() async {
    final data = await _load();
    return data['presets_migrated'] == true;
  }

  static Future<void> markPresetsMigrated() async {
    final data = await _load();
    data['presets_migrated'] = true;
    _cache = data;
    await _save();
  }

  // ---------------------------------------------------------------------------
  // Route final outbound
  // ---------------------------------------------------------------------------

  static Future<String> getRouteFinal() async {
    final data = await _load();
    return (data['route_final'] as String?) ?? '';
  }

  static Future<void> saveRouteFinal(String outbound) async {
    final data = await _load();
    data['route_final'] = outbound;
    _cache = data;
    await _save();
  }

  static Future<Set<String>> getExcludedNodes() async {
    final data = await _load();
    final list = data['excluded_nodes'] as List<dynamic>?;
    if (list == null) return {};
    return list.map((e) => e.toString()).toSet();
  }

  static Future<void> saveExcludedNodes(Set<String> excluded) async {
    final data = await _load();
    data['excluded_nodes'] = excluded.toList();
    _cache = data;
    await _save();
  }

  static Future<List<Map<String, dynamic>>> getDnsServers() async {
    final data = await _load();
    final dns = data['dns_options'] as Map<String, dynamic>?;
    if (dns == null) return [];
    final servers = dns['servers'] as List<dynamic>?;
    if (servers == null) return [];
    return servers.whereType<Map<String, dynamic>>().toList();
  }

  static Future<void> saveDnsServers(List<Map<String, dynamic>> servers) async {
    final data = await _load();
    final dns = (data['dns_options'] as Map<String, dynamic>?) ?? {};
    dns['servers'] = servers;
    data['dns_options'] = dns;
    _cache = data;
    await _save();
  }

  // ---------------------------------------------------------------------------
  // Ping/test options (§040)
  //
  // Storage shape mirrors template `ping_options.{url, timeout_ms, presets}`,
  // плюс расширение `groups: Map<groupTag, {url?, timeout_ms?}>` — per-group
  // override'ы для ping/mass-ping/URLTest. Resolve chain в HomeController:
  // group override → global storage → template default.
  // ---------------------------------------------------------------------------

  /// Возвращает raw `ping_options` Map (= storage). Empty map если не set —
  /// caller должен fallback'нуться на template default.
  static Future<Map<String, dynamic>> getPingOptions() async {
    final data = await _load();
    final raw = data['ping_options'];
    if (raw is Map<String, dynamic>) {
      return Map<String, dynamic>.from(raw);
    }
    return <String, dynamic>{};
  }

  /// Сохраняет всю structure целиком (atomic). Caller передаёт final shape —
  /// ничего не мерджится, только overwrite. Для частичных изменений см.
  /// [setGlobalPingUrl] / [setGroupPing] / [clearGroupPing].
  static Future<void> savePingOptions(Map<String, dynamic> options) async {
    final data = await _load();
    data['ping_options'] = options;
    _cache = data;
    await _save();
  }

  /// Sugared: установить global URL без затирания timeout / groups.
  static Future<void> setGlobalPingUrl(String url) async {
    final opts = await getPingOptions();
    opts['url'] = url;
    await savePingOptions(opts);
  }

  /// Sugared: установить global timeout (ms) без затирания url / groups.
  static Future<void> setGlobalPingTimeout(int timeoutMs) async {
    final opts = await getPingOptions();
    opts['timeout_ms'] = timeoutMs;
    await savePingOptions(opts);
  }

  /// Sugared: установить per-group override. Передаётся одно из / оба из
  /// `url` / `timeoutMs`; nil-аргументы не трогают существующее. Создаёт
  /// `groups[tag]` если не было.
  static Future<void> setGroupPing(
    String groupTag, {
    String? url,
    int? timeoutMs,
  }) async {
    if (groupTag.isEmpty) return;
    final opts = await getPingOptions();
    final groups = (opts['groups'] is Map<String, dynamic>)
        ? Map<String, dynamic>.from(opts['groups'] as Map<String, dynamic>)
        : <String, dynamic>{};
    final existing = (groups[groupTag] is Map<String, dynamic>)
        ? Map<String, dynamic>.from(groups[groupTag] as Map<String, dynamic>)
        : <String, dynamic>{};
    if (url != null) existing['url'] = url;
    if (timeoutMs != null) existing['timeout_ms'] = timeoutMs;
    groups[groupTag] = existing;
    opts['groups'] = groups;
    await savePingOptions(opts);
  }

  /// Sugared: убрать override этой группы целиком. No-op если не было.
  static Future<void> clearGroupPing(String groupTag) async {
    if (groupTag.isEmpty) return;
    final opts = await getPingOptions();
    final groups = opts['groups'];
    if (groups is! Map<String, dynamic>) return;
    if (!groups.containsKey(groupTag)) return;
    groups.remove(groupTag);
    if (groups.isEmpty) {
      opts.remove('groups');
    } else {
      opts['groups'] = groups;
    }
    await savePingOptions(opts);
  }

  /// DEPRECATED (§061 dns-rules-refactor, бывший feature §041): legacy
  /// `dns_options.rules_json` — single JSON-string override. Заменён на
  /// структурированный [getDnsRulesList]. Поле в storage остаётся для
  /// downgrade-friendliness, но билдер и UI больше не читают.
  @Deprecated('Use getDnsRulesList()/saveDnsRulesList() instead. See task 061.')
  static Future<String> getDnsRules() async {
    final data = await _load();
    final dns = data['dns_options'] as Map<String, dynamic>?;
    if (dns == null) return '';
    return dns['rules_json'] as String? ?? '';
  }

  /// DEPRECATED (§061 dns-rules-refactor, бывший feature §041): см. [getDnsRules].
  @Deprecated('Use getDnsRulesList()/saveDnsRulesList() instead. See task 061.')
  static Future<void> saveDnsRules(String rulesJson) async {
    final data = await _load();
    final dns = (data['dns_options'] as Map<String, dynamic>?) ?? {};
    dns['rules_json'] = rulesJson;
    data['dns_options'] = dns;
    _cache = data;
    await _save();
  }

  /// Структурированный список DNS-правил (§061 dns-rules-refactor, бывший feature §041). Каждая запись:
  /// `{enabled: bool, type: 'user'|'template'|'rule', title: String, rule?: Map}`.
  /// Если ключ отсутствует — возвращает пустой список (auto-discovery в
  /// builder/UI заполнит начальный набор).
  static Future<List<Map<String, dynamic>>> getDnsRulesList() async {
    final data = await _load();
    final dns = data['dns_options'] as Map<String, dynamic>?;
    if (dns == null) return [];
    final rules = dns['rules'] as List<dynamic>?;
    if (rules == null) return [];
    return rules.whereType<Map<String, dynamic>>().toList();
  }

  /// Сохраняет структурированный список DNS-правил. Caller отвечает за
  /// orphan-cleanup (§061) — выбрасывание `type: template/rule` чьи titles
  /// не находятся в текущем шаблоне / активных пресетах. Этот метод просто
  /// пишет, что дали.
  static Future<void> saveDnsRulesList(List<Map<String, dynamic>> rules) async {
    final data = await _load();
    final dns = (data['dns_options'] as Map<String, dynamic>?) ?? {};
    dns['rules'] = rules;
    data['dns_options'] = dns;
    _cache = data;
    await _save();
  }

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

  static Future<List<Map<String, String>>> getWifiHistory() async {
    final raw = await getVar('wifi_history', '[]');
    final decoded = (jsonDecode(raw) as List?) ?? const [];
    // Growable — caller'ы (Pick saved bottom sheet) делают `removeWhere`
    // для optimistic UI update. `growable: false` ломал это с silent
    // UnsupportedError в setState callback.
    return decoded
        .whereType<Map>()
        .map<Map<String, String>>((e) => {
              'ssid': (e['ssid'] as String?) ?? '',
              'bssid': (e['bssid'] as String?) ?? '',
              'last_seen': (e['last_seen'] as String?) ?? '',
            })
        .where((e) => (e['ssid'] ?? '').isNotEmpty)
        .toList();
  }

  /// Upsert по composite key `(ssid, bssid)`. Если уже есть — обновляет
  /// `last_seen`. Иначе добавляет в начало списка. Cap 50 (evict oldest).
  static Future<void> addToWifiHistory(String ssid, String bssid) async {
    if (ssid.isEmpty) return;
    final normalized = bssid.trim().toLowerCase();
    final history = (await getWifiHistory()).toList();
    final now = DateTime.now().toUtc().toIso8601String();
    history.removeWhere((e) =>
        (e['ssid'] ?? '') == ssid && (e['bssid'] ?? '') == normalized);
    history.insert(0, {
      'ssid': ssid,
      'bssid': normalized,
      'last_seen': now,
    });
    if (history.length > _wifiHistoryCap) {
      history.removeRange(_wifiHistoryCap, history.length);
    }
    await setVar('wifi_history', jsonEncode(history));
  }

  static Future<void> removeFromWifiHistory(String ssid, String bssid) async {
    final normalized = bssid.trim().toLowerCase();
    final history = (await getWifiHistory()).toList();
    final initial = history.length;
    history.removeWhere((e) =>
        (e['ssid'] ?? '') == ssid && (e['bssid'] ?? '') == normalized);
    if (history.length != initial) {
      await setVar('wifi_history', jsonEncode(history));
    }
  }

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

  /// Снимок всего `_cache` для `/state/storage` (§031). Возвращает
  /// глубокую копию — сериализатор сам фильтрует по allow-list,
  /// чтобы не утекли чувствительные поля (debug_token, subscription URLs).
  static Future<Map<String, dynamic>> dumpCache() async {
    final data = await _load();
    return jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
  }

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
  }) async {
    final clean = jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>;
    if (!merge) {
      _cache = clean;
      await _save();
      return;
    }
    final current = await _load();
    for (final entry in clean.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key == 'vars' && value is Map<String, dynamic>) {
        final existing = (current['vars'] as Map<String, dynamic>?) ?? {};
        for (final v in value.entries) {
          existing[v.key] = v.value;
        }
        current['vars'] = existing;
      } else {
        current[key] = value;
      }
    }
    _cache = current;
    await _save();
  }

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
  static Future<TunAppsConfig> getTunApps() async {
    final data = await _load();
    final raw = data['tun_apps'];
    if (raw is Map<String, dynamic>) {
      final mode = raw['mode'];
      final packages = (raw['packages'] as List<dynamic>?)
              ?.whereType<String>()
              .toList() ??
          const <String>[];
      if (mode == _tunAppsModeAllow ||
          mode == _tunAppsModeDeny ||
          mode == _tunAppsModeOff) {
        return TunAppsConfig(mode: mode as String, packages: packages);
      }
    }
    return const TunAppsConfig(mode: _tunAppsModeOff, packages: <String>[]);
  }

  /// Persist `tun_apps`. Caller передаёт финальный shape, мы только проверяем
  /// валидность. Дубликаты в `packages` schлопываются (idempotent).
  static Future<void> setTunApps(TunAppsConfig cfg) async {
    if (![_tunAppsModeOff, _tunAppsModeAllow, _tunAppsModeDeny]
        .contains(cfg.mode)) {
      throw ArgumentError('tun_apps.mode must be off|allow|deny: ${cfg.mode}');
    }
    final dedup = <String>{};
    for (final p in cfg.packages) {
      final t = p.trim();
      if (t.isEmpty) continue;
      dedup.add(t);
    }
    final data = await _load();
    data['tun_apps'] = {
      'mode': cfg.mode,
      'packages': dedup.toList()..sort(),
    };
    _cache = data;
    await _save();
  }
}

/// Typed wrapper over `tun_apps` storage shape (§046).
class TunAppsConfig {
  const TunAppsConfig({required this.mode, required this.packages});

  /// `"off"` | `"allow"` | `"deny"`.
  final String mode;
  final List<String> packages;

  bool get isOff => mode == 'off';
  bool get isAllow => mode == 'allow';
  bool get isDeny => mode == 'deny';

  TunAppsConfig copyWith({String? mode, List<String>? packages}) =>
      TunAppsConfig(
        mode: mode ?? this.mode,
        packages: packages ?? this.packages,
      );

  Map<String, Object?> toJson() => {'mode': mode, 'packages': packages};
}
