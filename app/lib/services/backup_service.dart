import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:package_info_plus/package_info_plus.dart';

import '../models/codec/chain_record.dart' show kSourceKindChain;
import '../models/custom_rule.dart';
import '../models/server_list.dart';
import '../models/source_chain.dart';
import 'app_log.dart';
import 'json_clone.dart';
import 'settings_storage.dart';
import 'settings_storage_keys.dart';
import 'storage_migration/migrate_storage.dart';
import 'template_loader.dart';

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
///
/// §439 — `sources[]` делится по виду записи: цепочки — Routing, прочие
/// источники — Server lists ([_filterStorage]); `storage_version` пишется при
/// любом наборе категорий.
const _topLevelRoutingKeys = {
  kRulesKey,
  'route_final',
  // §219/§221 — directions + guard миграции. КРИТИЧНО: без них backup/restore на
  // новом устройстве терял всю модель роутинг-Направлений §125 (directions в allowlist
  // restore, но забыт в export — асимметрия). directions_migrated нужен, чтобы
  // one-shot миграция не пере-сработала поверх восстановленных Направлений.
  'directions',
  'directions_migrated',
  'route_idle_suspend', // §215 — idle-suspend threshold (route.lx_idle_suspend)
  'route_idle_suspend_reachable', // §272 — reachable idle window
  'urltest_passive_check', // §272 — passive health check
  'enabled_groups', // §125 — DEPRECATED (legacy, читается только миграцией)
  'tun_apps',
  'vpn_mode',
  kDnsKey,
};

/// §393 C2 — запись цепочки в `sources[]`. Категория именно Routing, а не
/// Server lists: цепочка — маршрут, а не набор серверов, её позиции ссылаются
/// на теги Направлений, и восстановить её без них бессмысленно. Пара
/// «Направления + цепочки» обязана переезжать одним куском.
bool _isChainRecord(Object? record) =>
    record is Map && record['kind'] == kSourceKindChain;

/// Top-level storage keys относящиеся к App settings (служебные timestamps,
/// UI-предпочтения, ping options, WARP-аккаунт).
const _topLevelAppKeys = {
  'ping_options',
  'last_global_update',
  'presets_migrated',
  'warp_account',
  'masque_account', // §130 — MASQUE-WARP аккаунт (ECDSA-ключи + endpoint)
  'interrupt_connections_on_switch',
  'node_sort_mode',
  'node_manual_order',
  'profiler_retention_sec', // §219/§221 — окно Live-журнала (был в allowlist, не в export)
};

/// Sub-keys внутри `vars` относящиеся к Debug API category.
/// Sensitive: token даёт полный доступ к app'у через HTTP API.
const _varDebugKeys = SettingsStorage.debugApiVarKeys;

/// Container распарсенного backup-файла. `storage` — содержимое
/// `lxbox_settings.json` целиком; `vpnSettings` — native-side VPN toggles.
///
/// §439 §3.4 — блок `storage` формы 2.23.2 и раньше мигрирует в форму 1.0 при
/// создании контейнера ([migrateStorageDoc]): превью, категорийный фильтр и
/// применение видят уже мигрированный блок. Отчёт — [storageMigration].
///
/// Источники, цепочки и правила блока `storage` читаются моделями через
/// репозиторий ([SettingsStorage.serverListsOf], [SettingsStorage.chainsOf],
/// [SettingsStorage.customRulesOf]) — тем же чтением, что живое хранение;
/// счётчики, разбивка и слияние идут на моделях. Документ целиком (`storage`)
/// остаётся для `replaceRaw`.
class BackupContents {
  /// [presetIdByDnsServerTag] — `ref` preset-серверов DNS при миграции блока
  /// (см. [presetIdsByDnsServerTag]); пусто — `ref` = тег.
  /// [subscriptionBodies] — тела подписок из `sub_cache` для перевода ссылок
  /// на их узлы (§439 п. 8, тот же словарь, что у `_load`).
  BackupContents({
    this.createdAt,
    this.sourceAppVersion,
    Map<String, dynamic>? storage,
    this.vpnSettings,
    Map<String, String> presetIdByDnsServerTag = const {},
    Map<String, String> subscriptionBodies = const {},
  }) : storageMigration = storage == null
            ? null
            : migrateStorageDoc(storage,
                presetIdByDnsServerTag: presetIdByDnsServerTag,
                subscriptionBodies: subscriptionBodies);

  final DateTime? createdAt;
  final String? sourceAppVersion;

  /// Итог миграции блока `storage`; null — блока нет.
  final StorageMigrationResult? storageMigration;

  /// Содержимое `lxbox_settings.json` в форме 1.0 (top-level keys: vars,
  /// sources, rules, dns, storage_version, tun_apps, и т.д.). null если в
  /// файле нет блока `storage`.
  Map<String, dynamic>? get storage => storageMigration?.doc;

  /// Native-side VPN system toggles. null если в файле нет блока
  /// `vpn_settings`.
  final Map<String, dynamic>? vpnSettings;

  /// Источники блока [storage]. Читаются один раз: разбор одиночного сервера
  /// перечитывает его тело, а превью спрашивает счётчики на каждой перерисовке.
  late final _EntitiesRead<ServerList> _serverLists =
      _readEntities(storage, SettingsStorage.serverListsOf);

  /// Правила блока [storage].
  late final _EntitiesRead<CustomRule> _rules =
      _readEntities(storage, SettingsStorage.customRulesOf);

  /// Цепочки блока [storage] (записи `kind: chain` в `sources[]`) — для
  /// merge-импорта категории Routing.
  late final _EntitiesRead<SourceChain> _chains =
      _readEntities(storage, SettingsStorage.chainsOf);

  /// Какие категории присутствуют в файле — для UI checkbox state'а.
  Set<BackupCategory> availableCategories() {
    final s = storage;
    return {
      if (_serverLists.count > 0) BackupCategory.serverLists,
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
      BackupCategory.serverLists => _serverLists.count,
      BackupCategory.routing => _rules.count,
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

  /// Сколько источников — подписки, сколько прочие (для UI-надписи). Битая
  /// запись считается прочей.
  ({int subs, int custom}) splitServerLists() {
    final subs =
        _serverLists.items.whereType<SubscriptionServers>().length;
    return (subs: subs, custom: _serverLists.count - subs);
  }

  static bool _hasAnyRouting(Map<String, dynamic> s) {
    final sources = s[kSourcesKey];
    if (sources is List && sources.any(_isChainRecord)) return true;
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

/// Сущности документа, прочитанные репозиторием: модели и ошибки битых
/// записей. Битая запись входит в [count] — превью показывает, сколько записей
/// в файле, а не сколько из них прочиталось.
typedef _EntitiesRead<T> = ({List<T> items, List<Object> corrupt});

extension<T> on _EntitiesRead<T> {
  int get count => items.length + corrupt.length;
}

_EntitiesRead<T> _readEntities<T>(
  Map<String, dynamic>? doc,
  List<T> Function(
    Map<String, dynamic> doc, {
    void Function(Object error)? onCorrupt,
  }) read,
) {
  final corrupt = <Object>[];
  final items = doc == null ? <T>[] : read(doc, onCorrupt: corrupt.add);
  return (items: items, corrupt: corrupt);
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
///                     core_logs_enabled, allow_bypass, auto_redirect,
///                     memory_limit }
/// }
/// ```
///
/// Симметрично с HTTP `/backup/*` (см.
/// `lib/services/debug/handlers/backup.dart`).
class BackupService {
  const BackupService();

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

    final legacy = storageDocNeedsMigration(storage);
    return BackupContents(
      createdAt: createdAt,
      sourceAppVersion: decoded['source_app_version']?.toString(),
      storage: storage,
      vpnSettings: vpn,
      presetIdByDnsServerTag: legacy
          ? await SettingsStorage.presetIdsForMigration()
          : const {},
      // §439 п. 8 — без тел подписок позиция цепочки на узел подписки
      // («PR DE-1») оставалась корневой ссылкой и не разрешалась на сборке.
      subscriptionBodies: legacy
          ? await SettingsStorage.subscriptionBodiesForMigration(storage)
          : const {},
    );
  }

  /// Apply import согласно [include] (юзер мог снять галочки в preview-dialog'е).
  /// `merge=true` — top-level merge (vars upsert, источники append-by-id);
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
      final migration = contents.storageMigration;
      if (migration != null && migration.migrated) {
        AppLog.I.info('Backup import: storage block migrated to '
            'storage_version ${storageDocVersion(migration.doc)}'
            '${migration.summary.isEmpty ? '' : ' — ${migration.summary}'}');
      }
      if (migration != null && migration.warnings.isNotEmpty) {
        AppLog.I.warning('Backup import: storage migration losses: '
            '${migration.warnings.join('; ')}');
      }

      // merge: источники дописываются по `id` на моделях, цепочки заменяют
      // часть цепочек — в документ для replaceRaw `sources` не идёт, иначе
      // upsert затёр бы весь список (§439: цепочки и прочие источники — один
      // ключ).
      final mergeServerLists =
          merge && include.contains(BackupCategory.serverLists);
      final mergeChains = merge && include.contains(BackupCategory.routing);
      final filtered = _filterStorage(raw, include: include);
      if (merge) filtered.remove(kSourcesKey);

      if (mergeServerLists) {
        for (final e in contents._serverLists.corrupt) {
          errors.add('Server list parse: $e');
        }
        try {
          final existing = await SettingsStorage.getServerLists();
          final ids = existing.map((e) => e.id).toSet();
          for (final list in contents._serverLists.items) {
            if (ids.add(list.id)) {
              existing.add(list);
              serverLists++;
            }
          }
          if (serverLists > 0) await SettingsStorage.saveServerLists(existing);
        } catch (e) {
          errors.add('Server lists: $e');
        }
      } else if (include.contains(BackupCategory.serverLists)) {
        serverLists = contents.countFor(BackupCategory.serverLists);
      }

      if (mergeChains) {
        for (final e in contents._chains.corrupt) {
          errors.add('Chain parse: $e');
        }
        // Цепочки архива заменяют цепочки хранения целиком; архив без цепочек
        // текущие не трогает.
        if (contents._chains.items.isNotEmpty) {
          try {
            await SettingsStorage.setChains(contents._chains.items);
          } catch (e) {
            errors.add('Chains: $e');
          }
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

      // §393 A2 — порядок restore→migrate. Легаси-пару `channels` уже
      // переименовала миграция блока; вызов держит seed и vpn-1 для архива без
      // Направлений. Идемпотентен — на новом архиве это дешёвый no-op.
      try {
        final template = await TemplateLoader.load();
        await SettingsStorage.migrateDirectionsIfNeeded(
          template.groupTemplates,
          varDefaults: {
            for (final v in template.vars) v.name: v.defaultValue,
          },
        );
      } catch (e) {
        errors.add('Directions migration: $e');
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
  ///
  /// §279 Phase 5 — timestamp в ИМЕНИ ФАЙЛА сознательно locale-invariant
  /// (machine-поверхность, спека §5): ручная композиция, не intl DateFormat.
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

  /// Filter storage map по category-toggles для ЗАПИСИ в архив. Visible for tests.
  @visibleForTesting
  static Map<String, dynamic> filterStorageForExport(
    Map<String, dynamic> raw, {
    required Set<BackupCategory> include,
  }) {
    return _filterStorage(raw, include: include);
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
  ///
  /// §439 — на импорте блок уже в форме 1.0 ([BackupContents] мигрирует его
  /// при разборе): легаси-ключей здесь не бывает.
  static Map<String, dynamic> _filterStorage(
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
      if (key == kStorageVersionKey) {
        // Признак формы едет при любом наборе категорий: без него блок
        // читался бы как форма 2.23.2.
        out[key] = value;
      } else if (key == kSourcesKey) {
        if (value is List && (wantServers || wantRouting)) {
          out[key] = [
            for (final r in value)
              if (_isChainRecord(r) ? wantRouting : wantServers)
                deepCloneJson(r),
          ];
        }
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
