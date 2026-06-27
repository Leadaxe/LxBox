import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:package_info_plus/package_info_plus.dart';

import '../models/server_list.dart';
import '../vpn/box_vpn_client.dart';
import 'app_log.dart';
import 'json_clone.dart';
import 'settings_storage.dart';

/// Backup categories — параллельно с UI-toggle'ами в [BackupScreen].
/// Спека: docs/spec/features/040 backup restore ui/spec.md
enum BackupCategory {
  serverLists,
  routing,
  appSettings,
  debugConfig,
  vpnSettings,
}

/// Top-level storage keys относящиеся к Routing категории.
const _topLevelRoutingKeys = {
  'custom_rules',
  'route_final',
  'enabled_groups',
  'tun_apps',
  'vpn_mode',
  'excluded_nodes',
  'dns_options',
};

/// Top-level storage keys относящиеся к App settings (служебные timestamps,
/// UI-предпочтения, ping options, WARP-аккаунт).
const _topLevelAppKeys = {
  'ping_options',
  'last_global_update',
  'presets_migrated',
  'warp_account',
  'interrupt_connections_on_switch',
  'node_sort_mode',
  'node_manual_order',
};

/// Sub-keys внутри `vars` относящиеся к Debug API category.
/// Sensitive: token даёт полный доступ к app'у через HTTP API.
const _varDebugKeys = {'debug_enabled', 'debug_token', 'debug_port'};

/// Container распарсенного backup-файла. `storage` — содержимое
/// `lxbox_settings.json` целиком; `vpnSettings` — native-side VPN toggles.
class BackupContents {
  const BackupContents({
    this.createdAt,
    this.sourceAppVersion,
    this.storage,
    this.vpnSettings,
  });

  final DateTime? createdAt;
  final String? sourceAppVersion;

  /// Содержимое `lxbox_settings.json` (top-level keys: vars, server_lists,
  /// custom_rules, tun_apps, и т.д.). null если в файле нет блока `storage`.
  final Map<String, dynamic>? storage;

  /// Native-side VPN system toggles. null если в файле нет блока
  /// `vpn_settings`.
  final Map<String, dynamic>? vpnSettings;

  /// Какие категории присутствуют в файле — для UI checkbox state'а.
  Set<BackupCategory> availableCategories() {
    final s = storage;
    return {
      if (s != null && s['server_lists'] is List &&
          (s['server_lists'] as List).isNotEmpty)
        BackupCategory.serverLists,
      if (s != null && _hasAnyRouting(s)) BackupCategory.routing,
      if (s != null && _hasAnyApp(s)) BackupCategory.appSettings,
      if (s != null && _hasAnyDebug(s)) BackupCategory.debugConfig,
      if (vpnSettings != null && vpnSettings!.isNotEmpty)
        BackupCategory.vpnSettings,
    };
  }

  /// Counts для UI preview.
  int countFor(BackupCategory cat) {
    final s = storage ?? const <String, dynamic>{};
    return switch (cat) {
      BackupCategory.serverLists => () {
          final v = s['server_lists'];
          return v is List ? v.length : 0;
        }(),
      BackupCategory.routing => () {
          final rules = s['custom_rules'];
          return rules is List ? rules.length : 0;
        }(),
      BackupCategory.appSettings => () {
          final vars = s['vars'];
          if (vars is! Map) return 0;
          return vars.keys
              .where((k) => !_varDebugKeys.contains(k.toString()))
              .length;
        }(),
      BackupCategory.debugConfig => () {
          final vars = s['vars'];
          if (vars is! Map) return 0;
          return vars.keys
              .where((k) => _varDebugKeys.contains(k.toString()))
              .length;
        }(),
      BackupCategory.vpnSettings => vpnSettings?.length ?? 0,
    };
  }

  /// Опциональные «полезные при preview» детали — текущий final outbound.
  String? get routingFinalOutbound => storage?['route_final'] as String?;

  /// Из server_lists — сколько subscriptions vs custom (для UI-надписи).
  ({int subs, int custom}) splitServerLists() {
    final raw = storage?['server_lists'];
    if (raw is! List) return (subs: 0, custom: 0);
    var subs = 0;
    var custom = 0;
    for (final m in raw.whereType<Map<String, dynamic>>()) {
      try {
        final list = ServerList.fromJson(m);
        if (list is SubscriptionServers) {
          subs++;
        } else {
          custom++;
        }
      } catch (_) {
        custom++;
      }
    }
    return (subs: subs, custom: custom);
  }

  static bool _hasAnyRouting(Map<String, dynamic> s) {
    for (final k in _topLevelRoutingKeys) {
      final v = s[k];
      if (v is List && v.isNotEmpty) return true;
      if (v is Map && v.isNotEmpty) return true;
      if (v is String && v.isNotEmpty) return true;
    }
    return false;
  }

  static bool _hasAnyApp(Map<String, dynamic> s) {
    final vars = s['vars'];
    if (vars is Map) {
      for (final k in vars.keys) {
        if (!_varDebugKeys.contains(k.toString())) return true;
      }
    }
    for (final k in _topLevelAppKeys) {
      if (s[k] != null) return true;
    }
    return false;
  }

  static bool _hasAnyDebug(Map<String, dynamic> s) {
    final vars = s['vars'];
    if (vars is! Map) return false;
    for (final k in vars.keys) {
      if (_varDebugKeys.contains(k.toString())) return true;
    }
    return false;
  }
}

/// Результат применения import'а — используется UI для SnackBar'а.
class BackupApplyResult {
  const BackupApplyResult({
    this.serverListsApplied = 0,
    this.routingApplied = 0,
    this.appSettingsApplied = 0,
    this.debugConfigApplied = 0,
    this.vpnSettingsApplied = 0,
    this.droppedKeys = const [],
    this.errors = const [],
  });

  final int serverListsApplied;
  final int routingApplied;
  final int appSettingsApplied;
  final int debugConfigApplied;
  final int vpnSettingsApplied;

  /// §159 — ключи, отброшенные allowlist'ом при импорте (неизвестные top-level
  /// или `vars.<key>`). Пусто для «чистого» нашего бэкапа; непусто для
  /// чужеродного/устаревшего файла. UI показывает count исчезающим снэкбаром.
  final List<String> droppedKeys;

  final List<String> errors;

  bool get hasErrors => errors.isNotEmpty;
}

/// Service-слой над export/import-логикой. UI ([BackupScreen]) использует
/// только это API; SettingsStorage и BoxVpnClient напрямую не дёргает.
///
/// Wire-format:
/// ```json
/// {
///   "app": "lxbox",
///   "kind": "backup",
///   "created_at": "...",
///   "source_app_version": "...",
///   "storage": { ...lxbox_settings.json целиком... },
///   "vpn_settings": { auto_start, keep_on_exit, background_mode,
///                     core_logs_enabled, allow_bypass }
/// }
/// ```
///
/// Симметрично с HTTP `/backup/*` (см.
/// `lib/services/debug/handlers/backup.dart`).
class BackupService {
  const BackupService({BoxVpnClient? vpn}) : _vpn = vpn;

  // §189 — _vpn больше не используется напрямую (vpn_settings ходят через
  // SettingsStorage.getNativePrefs/setNativeBool). Поле сохранено для
  // обратной совместимости конструктора (тесты могут передавать мок).
  // ignore: unused_field
  final BoxVpnClient? _vpn;

  /// Build JSON-string для export'а согласно [include]'у.
  Future<String> buildExport({required Set<BackupCategory> include}) async {
    final out = <String, dynamic>{
      'app': 'lxbox',
      'kind': 'backup',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };

    try {
      final info = await PackageInfo.fromPlatform();
      out['source_app_version'] = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // PackageInfo может упасть в test environment — graceful skip.
    }

    final raw = await SettingsStorage.exportRaw();
    final filtered = filterStorageForExport(raw, include: include);
    if (filtered.isNotEmpty) {
      out['storage'] = filtered;
    }

    if (include.contains(BackupCategory.vpnSettings)) {
      out['vpn_settings'] = await _readVpnSettings();
    }

    return const JsonEncoder.withIndent('  ').convert(out);
  }

  /// Parse + validate import JSON. Throws [FormatException] на invalid format.
  Future<BackupContents> parseImport(String raw) async {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      throw const FormatException(
          'Not a valid JSON file. Make sure you picked a LxBox backup file.');
    }

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Backup root must be a JSON object.');
    }

    final app = decoded['app']?.toString();
    final kind = decoded['kind']?.toString();
    if (app != 'lxbox' || kind != 'backup') {
      throw const FormatException(
          'Not a LxBox backup file (missing or invalid app/kind markers).');
    }

    final storage = decoded['storage'];
    if (storage is! Map<String, dynamic>) {
      throw const FormatException(
          'Unsupported backup format. Re-export from a recent app version.');
    }

    DateTime? createdAt;
    final createdRaw = decoded['created_at']?.toString();
    if (createdRaw != null) {
      createdAt = DateTime.tryParse(createdRaw);
    }

    Map<String, dynamic>? vpn;
    final rawVpn = decoded['vpn_settings'];
    if (rawVpn is Map<String, dynamic>) {
      vpn = Map<String, dynamic>.from(rawVpn);
    }

    return BackupContents(
      createdAt: createdAt,
      sourceAppVersion: decoded['source_app_version']?.toString(),
      storage: storage,
      vpnSettings: vpn,
    );
  }

  /// Apply import согласно [include] (юзер мог снять галочки в preview-dialog'е).
  /// `merge=true` — top-level merge (vars upsert, server_lists append-by-id);
  /// `merge=false` — replace (overwrite целиком в указанных категориях).
  Future<BackupApplyResult> applyImport(
    BackupContents contents, {
    required bool merge,
    required Set<BackupCategory> include,
  }) async {
    final errors = <String>[];
    final droppedKeys = <String>[];
    var serverLists = 0;
    var routing = 0;
    var appS = 0;
    var debug = 0;
    var vpn = 0;

    final raw = contents.storage;
    if (raw != null) {
      final filtered = _filterStorageForImport(raw, include: include);

      // server_lists merge mode handled in-Map (append-by-id).
      if (merge && include.contains(BackupCategory.serverLists)) {
        final incoming = filtered['server_lists'];
        if (incoming is List) {
          try {
            final existing = await SettingsStorage.getServerLists();
            final ids = existing.map((e) => e.id).toSet();
            for (final m in incoming.whereType<Map<String, dynamic>>()) {
              try {
                final p = ServerList.fromJson(m);
                if (!ids.contains(p.id)) {
                  existing.add(p);
                  serverLists++;
                }
              } catch (e) {
                errors.add('Server list parse: $e');
              }
            }
            await SettingsStorage.saveServerLists(existing);
          } catch (e) {
            errors.add('Server lists: $e');
          }
          filtered.remove('server_lists');
        }
      } else if (include.contains(BackupCategory.serverLists)) {
        final incoming = filtered['server_lists'];
        if (incoming is List) {
          serverLists = incoming.length;
        }
      }

      try {
        // §159 — replaceRaw применяет allowlist (default-deny) и возвращает
        // отброшенные ключи. Для нашего бэкапа пусто; для чужого/устаревшего —
        // непусто (логируем + покажем юзеру).
        final dropped = await SettingsStorage.replaceRaw(filtered, merge: merge);
        droppedKeys.addAll(dropped);
        if (dropped.isNotEmpty) {
          AppLog.I.warning(
              'Backup import dropped ${dropped.length} unknown key(s): '
              '${dropped.join(', ')}');
        }
      } catch (e) {
        errors.add('Storage: $e');
      }

      routing = contents.countFor(BackupCategory.routing);
      appS = contents.countFor(BackupCategory.appSettings);
      debug = contents.countFor(BackupCategory.debugConfig);
      if (!include.contains(BackupCategory.routing)) routing = 0;
      if (!include.contains(BackupCategory.appSettings)) appS = 0;
      if (!include.contains(BackupCategory.debugConfig)) debug = 0;
    }

    if (include.contains(BackupCategory.vpnSettings) &&
        contents.vpnSettings != null) {
      vpn = await _applyVpnSettings(contents.vpnSettings!, errors);
    }

    return BackupApplyResult(
      serverListsApplied: serverLists,
      routingApplied: routing,
      appSettingsApplied: appS,
      debugConfigApplied: debug,
      vpnSettingsApplied: vpn,
      droppedKeys: droppedKeys,
      errors: errors,
    );
  }

  // §189 — делегируем единой сериализации NativePrefs (состав/дефолты/типы в
  // одном месте, см. settings_storage/native_prefs.dart). Wire-формат бэкапа
  // НЕ меняется — старые бэкапы импортируются.
  Future<Map<String, dynamic>> _readVpnSettings() =>
      SettingsStorage.exportNativePrefsBackup();

  Future<int> _applyVpnSettings(
          Map<String, dynamic> data, List<String> errors) =>
      SettingsStorage.applyNativePrefsBackup(data,
          onError: (key, e) => errors.add('vpn_settings.$key: $e'));

  /// Suggested filename для export'а: `lxbox-backup-v{appver}-{YYYYMMDD-HHMM}.json`.
  static Future<String> suggestedFilename() async {
    String appVersion = '0';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = info.version;
    } catch (_) {}
    final now = DateTime.now();
    String pad(int n) => n.toString().padLeft(2, '0');
    final date =
        '${now.year}${pad(now.month)}${pad(now.day)}-${pad(now.hour)}${pad(now.minute)}';
    return 'lxbox-backup-v$appVersion-$date.json';
  }

  /// Filter storage map по category-toggles. Visible for tests.
  @visibleForTesting
  static Map<String, dynamic> filterStorageForExport(
    Map<String, dynamic> raw, {
    required Set<BackupCategory> include,
  }) {
    return _filterStorageForImport(raw, include: include);
  }

  /// Категорийный filter для top-level + vars subkeys по category-toggles
  /// (Server lists / Routing / App / Debug). Это UX-выбор юзера («что
  /// выгрузить / что применить»), НЕ защита от мусора.
  ///
  /// Используется на export-time (что записать в файл) и на import-time (что
  /// применить, если юзер снял галочки в preview). §159 — строгая чистка
  /// чужеродных/«мёртвых» ключей делается отдельно на ВХОДЕ в
  /// `SettingsStorage.replaceRaw` (allowlist default-deny); здесь else-ветки
  /// «unknown → куда-нибудь» нет.
  static Map<String, dynamic> _filterStorageForImport(
    Map<String, dynamic> raw, {
    required Set<BackupCategory> include,
  }) {
    final wantServers = include.contains(BackupCategory.serverLists);
    final wantRouting = include.contains(BackupCategory.routing);
    final wantApp = include.contains(BackupCategory.appSettings);
    final wantDebug = include.contains(BackupCategory.debugConfig);

    final out = <String, dynamic>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key == 'server_lists') {
        if (wantServers) out[key] = deepCloneJson(value);
      } else if (key == 'vars') {
        if (value is Map) {
          final filteredVars = <String, dynamic>{};
          for (final v in value.entries) {
            final vk = v.key.toString();
            final isDebug = _varDebugKeys.contains(vk);
            if (isDebug && wantDebug) {
              filteredVars[vk] = deepCloneJson(v.value);
            } else if (!isDebug && wantApp) {
              filteredVars[vk] = deepCloneJson(v.value);
            }
          }
          if (filteredVars.isNotEmpty) out[key] = filteredVars;
        }
      } else if (_topLevelRoutingKeys.contains(key)) {
        if (wantRouting) out[key] = deepCloneJson(value);
      } else if (_topLevelAppKeys.contains(key)) {
        if (wantApp) out[key] = deepCloneJson(value);
      }
      // §159 — НЕТ else-ветки «unknown → App settings». Категорийный фильтр
      // работает только по известным ключам; чистка чужеродного/«мёртвого»
      // мусора — строгий allowlist на ВХОДЕ (`SettingsStorage.replaceRaw`), а
      // не здесь. Все валидные top-level ключи перечислены в категориях выше
      // (route/app); новый ключ — добавить в нужную категорию + в
      // [SettingsStorage.allowedTopLevelKeys].
    }
    return out;
  }

}
