import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:package_info_plus/package_info_plus.dart';

import '../models/server_list.dart';
import 'settings_storage.dart';

/// Backup categories — параллельно с UI-toggle'ами в [BackupScreen].
/// Спека: docs/spec/features/040 backup restore ui/spec.md
enum BackupCategory {
  serverLists,
  routing,
  appSettings,
  debugConfig,
}

/// Wire-format `version` для текущей schema.
/// Изменяется при breaking changes в формате — старые backup'ы reject'ятся.
const int kBackupSchemaVersion = 1;

/// Sentinel-keys которые относятся к [BackupCategory.routing].
/// Всё что в `vars` под этими ключами — экспортится только при routing=true.
const _routingKeys = {'custom_rules', 'route_final'};

/// Sentinel-keys которые относятся к [BackupCategory.debugConfig].
/// Sensitive: token даёт полный доступ к app'у через HTTP API.
const _debugKeys = {'debug_enabled', 'debug_token', 'debug_port'};

/// Контейнер распарсенного backup-файла. Поля — по категориям; null означает
/// «эта категория отсутствует в файле» (юзер при экспорте снял галочку).
class BackupContents {
  const BackupContents({
    required this.schemaVersion,
    this.createdAt,
    this.sourceAppVersion,
    this.serverLists,
    this.routingVars,
    this.appVars,
    this.debugVars,
  });

  final int schemaVersion;
  final DateTime? createdAt;
  final String? sourceAppVersion;

  /// `category: serverLists`. null если в файле нет server_lists.
  final List<ServerList>? serverLists;

  /// `category: routing`. Map с ключами из [_routingKeys].
  final Map<String, dynamic>? routingVars;

  /// `category: appSettings`. Map с остальными vars (не routing, не debug).
  final Map<String, dynamic>? appVars;

  /// `category: debugConfig`. Map с ключами из [_debugKeys].
  final Map<String, dynamic>? debugVars;

  /// Какие категории присутствуют в файле — для UI checkbox state'а
  /// (показываем только то, что есть).
  Set<BackupCategory> availableCategories() {
    return {
      if (serverLists != null && serverLists!.isNotEmpty)
        BackupCategory.serverLists,
      if (routingVars != null && routingVars!.isNotEmpty)
        BackupCategory.routing,
      if (appVars != null && appVars!.isNotEmpty) BackupCategory.appSettings,
      if (debugVars != null && debugVars!.isNotEmpty) BackupCategory.debugConfig,
    };
  }

  /// Counts для UI preview: сколько server_lists, routing-rules и т.д.
  int countFor(BackupCategory cat) {
    return switch (cat) {
      BackupCategory.serverLists => serverLists?.length ?? 0,
      BackupCategory.routing => () {
          final rules = routingVars?['custom_rules'];
          if (rules is List) return rules.length;
          if (rules is String) {
            try {
              return (jsonDecode(rules) as List).length;
            } catch (_) {
              return 0;
            }
          }
          return 0;
        }(),
      BackupCategory.appSettings => appVars?.length ?? 0,
      BackupCategory.debugConfig => debugVars?.length ?? 0,
    };
  }

  /// Опциональные «полезные при preview» детали — например, текущий final
  /// outbound, чтобы юзер видел «Routing → final: vpn-1».
  String? get routingFinalOutbound => routingVars?['route_final'] as String?;

  /// Из serverLists — сколько типа SubscriptionServers и сколько UserServer
  /// (для UI-надписи «3 subs, 1 custom»). ServerList sealed: `type` поле
  /// дискриминатор — `'subscription'` vs `'user'`.
  ({int subs, int custom}) splitServerLists() {
    final list = serverLists ?? const [];
    var subs = 0;
    var custom = 0;
    for (final l in list) {
      if (l is SubscriptionServers) {
        subs++;
      } else {
        custom++;
      }
    }
    return (subs: subs, custom: custom);
  }
}

/// Результат применения import'а — используется UI для SnackBar'а.
class BackupApplyResult {
  const BackupApplyResult({
    this.serverListsApplied = 0,
    this.routingVarsApplied = 0,
    this.appVarsApplied = 0,
    this.debugVarsApplied = 0,
    this.errors = const [],
  });

  final int serverListsApplied;
  final int routingVarsApplied;
  final int appVarsApplied;
  final int debugVarsApplied;
  final List<String> errors;

  bool get hasErrors => errors.isNotEmpty;
}

/// Service-слой над export/import-логикой. UI ([BackupScreen]) использует
/// только это API; SettingsStorage и BoxVpnClient напрямую не дёргает.
///
/// Wire-format **симметричен** существующему HTTP `/backup/*` (см.
/// `lib/services/debug/handlers/backup.dart`): файл из UI можно скормить
/// в `POST /backup/import` через curl, и наоборот.
class BackupService {
  const BackupService();

  /// Build JSON-string для export'а согласно [include]'у.
  /// Возвращает pretty-printed JSON (для читаемости — backup'ы редко large).
  Future<String> buildExport({required Set<BackupCategory> include}) async {
    final out = <String, dynamic>{
      'app': 'lxbox',
      'kind': 'backup',
      'version': kBackupSchemaVersion,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };

    // App version — для debugging при mismatch (может помочь юзеру понять
    // что backup со старой/новой версии).
    try {
      final info = await PackageInfo.fromPlatform();
      out['source_app_version'] = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // PackageInfo может упасть в test environment — graceful skip.
    }

    if (include.contains(BackupCategory.serverLists)) {
      final lists = await SettingsStorage.getServerLists();
      out['server_lists'] = lists.map((l) => l.toJson()).toList();
    }

    final allVars = await SettingsStorage.getAllVars();
    final filteredVars = _filterVars(
      allVars,
      include: include,
    );
    if (filteredVars.isNotEmpty) {
      out['vars'] = filteredVars;
    }

    return const JsonEncoder.withIndent('  ').convert(out);
  }

  /// Parse + validate import JSON. Throws [FormatException] на invalid format,
  /// [BackupVersionException] на schema-mismatch.
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

    final ver = decoded['version'];
    final schemaVersion = ver is int ? ver : (ver is num ? ver.toInt() : -1);
    if (schemaVersion != kBackupSchemaVersion) {
      throw BackupVersionException(
        fileVersion: schemaVersion,
        appVersion: kBackupSchemaVersion,
      );
    }

    DateTime? createdAt;
    final createdRaw = decoded['created_at']?.toString();
    if (createdRaw != null) {
      createdAt = DateTime.tryParse(createdRaw);
    }

    // Server lists
    List<ServerList>? serverLists;
    final rawLists = decoded['server_lists'];
    if (rawLists is List) {
      serverLists = rawLists
          .whereType<Map<String, dynamic>>()
          .map(ServerList.fromJson)
          .toList();
    }

    // Vars — расщепляем на 3 категории.
    Map<String, dynamic>? routingVars;
    Map<String, dynamic>? appVars;
    Map<String, dynamic>? debugVars;
    final rawVars = decoded['vars'];
    if (rawVars is Map) {
      final routing = <String, dynamic>{};
      final appS = <String, dynamic>{};
      final debug = <String, dynamic>{};
      for (final entry in rawVars.entries) {
        final key = entry.key.toString();
        final v = entry.value;
        if (_routingKeys.contains(key)) {
          routing[key] = v;
        } else if (_debugKeys.contains(key)) {
          debug[key] = v;
        } else {
          appS[key] = v;
        }
      }
      if (routing.isNotEmpty) routingVars = routing;
      if (appS.isNotEmpty) appVars = appS;
      if (debug.isNotEmpty) debugVars = debug;
    }

    return BackupContents(
      schemaVersion: schemaVersion,
      createdAt: createdAt,
      sourceAppVersion: decoded['source_app_version']?.toString(),
      serverLists: serverLists,
      routingVars: routingVars,
      appVars: appVars,
      debugVars: debugVars,
    );
  }

  /// Apply import согласно [include] (юзер мог снять галочки в preview-dialog'е).
  /// `merge=true` — добавить к существующим (vars upsert, server_lists append-by-id);
  /// `merge=false` — replace existing полностью в указанных категориях.
  Future<BackupApplyResult> applyImport(
    BackupContents contents, {
    required bool merge,
    required Set<BackupCategory> include,
  }) async {
    final errors = <String>[];
    var serverListsApplied = 0;
    var routingApplied = 0;
    var appApplied = 0;
    var debugApplied = 0;

    // Server lists
    if (include.contains(BackupCategory.serverLists) &&
        contents.serverLists != null) {
      try {
        if (merge) {
          final existing = await SettingsStorage.getServerLists();
          final existingIds = existing.map((e) => e.id).toSet();
          for (final p in contents.serverLists!) {
            if (!existingIds.contains(p.id)) {
              existing.add(p);
              serverListsApplied++;
            }
          }
          await SettingsStorage.saveServerLists(existing);
        } else {
          await SettingsStorage.saveServerLists(contents.serverLists!);
          serverListsApplied = contents.serverLists!.length;
        }
      } catch (e) {
        errors.add('Server lists: $e');
      }
    }

    // Vars — поочерёдно по категориям. Каждая категория checked independently.
    final varsToApply = <String, dynamic>{};
    final varsToWipe = <String>{};

    if (include.contains(BackupCategory.routing) && contents.routingVars != null) {
      varsToApply.addAll(contents.routingVars!);
      if (!merge) varsToWipe.addAll(_routingKeys);
      routingApplied = contents.routingVars!.length;
    }
    if (include.contains(BackupCategory.appSettings) && contents.appVars != null) {
      varsToApply.addAll(contents.appVars!);
      if (!merge) {
        // Replace mode для App settings: стираем все vars, не относящиеся к
        // routing/debug (т.е. категория "rest"). Делается через get-all + filter.
        final all = await SettingsStorage.getAllVars();
        for (final k in all.keys) {
          if (!_routingKeys.contains(k) && !_debugKeys.contains(k)) {
            varsToWipe.add(k);
          }
        }
      }
      appApplied = contents.appVars!.length;
    }
    if (include.contains(BackupCategory.debugConfig) &&
        contents.debugVars != null) {
      varsToApply.addAll(contents.debugVars!);
      if (!merge) varsToWipe.addAll(_debugKeys);
      debugApplied = contents.debugVars!.length;
    }

    // Wipe (для replace mode) перед применением новых.
    for (final key in varsToWipe) {
      try {
        await SettingsStorage.removeVar(key);
      } catch (e) {
        errors.add('Wipe $key: $e');
      }
    }

    // Применяем.
    for (final entry in varsToApply.entries) {
      final v = entry.value;
      if (v == null) continue;
      try {
        await SettingsStorage.setVar(entry.key, v.toString());
      } catch (e) {
        errors.add('${entry.key}: $e');
      }
    }

    return BackupApplyResult(
      serverListsApplied: serverListsApplied,
      routingVarsApplied: routingApplied,
      appVarsApplied: appApplied,
      debugVarsApplied: debugApplied,
      errors: errors,
    );
  }

  /// Suggested filename для export'а: `lxbox-backup-v{appver}-{YYYYMMDD-HHMM}.json`.
  /// Используется UI при сохранении через share_plus.
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

  /// Filter all vars по category-toggles. Visible for tests.
  @visibleForTesting
  static Map<String, dynamic> filterVarsForExport(
    Map<String, dynamic> all, {
    required Set<BackupCategory> include,
  }) {
    return _filterVars(all, include: include);
  }

  static Map<String, dynamic> _filterVars(
    Map<String, dynamic> all, {
    required Set<BackupCategory> include,
  }) {
    final routing = include.contains(BackupCategory.routing);
    final app = include.contains(BackupCategory.appSettings);
    final debug = include.contains(BackupCategory.debugConfig);
    final out = <String, dynamic>{};
    for (final entry in all.entries) {
      final key = entry.key;
      final inRouting = _routingKeys.contains(key);
      final inDebug = _debugKeys.contains(key);
      if (inRouting && routing) {
        out[key] = entry.value;
      } else if (inDebug && debug) {
        out[key] = entry.value;
      } else if (!inRouting && !inDebug && app) {
        out[key] = entry.value;
      }
    }
    return out;
  }
}

/// Schema-mismatch exception при import'е. UI показывает user-facing message.
class BackupVersionException implements Exception {
  const BackupVersionException({
    required this.fileVersion,
    required this.appVersion,
  });

  final int fileVersion;
  final int appVersion;

  String get userMessage {
    if (fileVersion < 0) {
      return 'Backup file is missing version field.';
    }
    if (fileVersion > appVersion) {
      return 'Backup is from a newer LxBox version (file: v$fileVersion, '
          'this app: v$appVersion). Please update LxBox.';
    }
    return 'Backup is from an older LxBox version (file: v$fileVersion, '
        'this app: v$appVersion). Migration not yet supported.';
  }

  @override
  String toString() => userMessage;
}
