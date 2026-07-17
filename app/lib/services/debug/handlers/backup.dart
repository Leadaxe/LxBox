import 'package:package_info_plus/package_info_plus.dart';

import '../../l10n/locale_controller.dart';
import '../../settings_storage.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// `/backup/*` — экспорт/импорт пользовательских данных. Wire-format
/// симметричен `BackupService` (см. `lib/services/backup_service.dart`):
/// файл из UI можно скормить в `POST /backup/import` через curl, и наоборот.
///
/// Каждый запрос содержит блоки:
/// - `storage` — `lxbox_settings.json` целиком (Flutter side)
/// - `vpn_settings` — native VPN toggles (auto_start, keep_on_exit,
///   background_mode, core_logs_enabled, allow_bypass)
///
/// Кеши (cache.db, stderr.log, SRS-blob, runtime node-tags) не включаются —
/// restore их пересоздаст.
Future<DebugResponse> backupHandler(DebugRequest req, DebugContext ctx) async {
  return switch ('${req.method} ${req.path}') {
    'GET /backup/export' => _export(req),
    'POST /backup/import' => _import(req, ctx),
    _ => throw NotFound('backup: ${req.method} ${req.path}'),
  };
}

const _allParts = {'storage', 'vpn_settings'};

/// `GET /backup/export[?include=storage,vpn_settings]` → JSON.
/// Default `include` — всё. Каждая часть опциональна; пустое или
/// отсутствующее поле в выходе означает «нечего экспортировать».
Future<DebugResponse> _export(DebugRequest req) async {
  final raw = (req.query['include'] ?? 'storage,vpn_settings');
  final include = raw
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .where(_allParts.contains)
      .toSet();
  final out = <String, dynamic>{
    'app': 'lxbox',
    'kind': 'backup',
    'created_at': DateTime.now().toUtc().toIso8601String(),
  };
  try {
    final info = await PackageInfo.fromPlatform();
    out['source_app_version'] = '${info.version}+${info.buildNumber}';
  } catch (_) {}

  if (include.contains('storage')) {
    out['storage'] = await SettingsStorage.exportRaw();
  }
  if (include.contains('vpn_settings')) {
    // §189 — единая сериализация (делегат NativePrefs, как BackupService).
    out['vpn_settings'] = await SettingsStorage.exportNativePrefsBackup();
  }
  return JsonResponse(out, pretty: true);
}

/// `POST /backup/import[?merge=false&rebuild=false]`. Body — JSON объект
/// с полями `storage` и/или `vpn_settings`.
/// - `merge=false` (default) — replace existing.
/// - `merge=true` — top-level merge (vars upsert, остальные ключи overwrite).
/// - `rebuild=true` — после restore зовёт `SubscriptionController.generateConfig`
///   и сохраняет в HomeState (то же что `POST /action/rebuild-config`).
Future<DebugResponse> _import(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final merge = req.qBool('merge');
  final rebuild = req.qBool('rebuild');
  final applied = <String, dynamic>{};

  final storage = body['storage'];
  if (storage is Map<String, dynamic>) {
    // §159 — replaceRaw применяет allowlist (default-deny). Отброшенные
    // неизвестные/чужеродные ключи возвращаются и отдаются в ответе.
    final dropped = await SettingsStorage.replaceRaw(storage, merge: merge);
    applied['storage_keys'] = storage.length;
    if (dropped.isNotEmpty) applied['dropped_keys'] = dropped;
    // §279 — restore мог привезти другой app_language: полный пайплайн смены
    // локали через владеющий контроллер (не голое значение в сторадже).
    await LocaleController.I.reloadFromStorage();
  } else if (storage != null) {
    throw const BadRequest('storage must be a JSON object');
  }

  final vpn = body['vpn_settings'];
  if (vpn is Map<String, dynamic>) {
    // §189 — единая сериализация (делегат NativePrefs, как BackupService).
    applied['vpn_settings'] = await SettingsStorage.applyNativePrefsBackup(vpn);
  } else if (vpn != null) {
    throw const BadRequest('vpn_settings must be a JSON object');
  }

  if (rebuild) {
    final sub = ctx.sub;
    final home = ctx.home;
    if (sub != null && home != null) {
      final json = await sub.generateConfig();
      if (json != null) {
        await home.saveParsedConfig(json);
        applied['rebuilt'] = true;
      } else {
        applied['rebuilt'] = false;
        applied['rebuild_error'] = sub.lastError?.renderEn() ?? '';
      }
    }
  }

  return JsonResponse({'applied': applied}, pretty: true);
}
