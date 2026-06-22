import 'package:package_info_plus/package_info_plus.dart';

import '../../../models/background_mode.dart';
import '../../../vpn/box_vpn_client.dart';
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
    final c = BoxVpnClient();
    final mode = await c.getBackgroundMode();
    out['vpn_settings'] = {
      'auto_start': await c.getAutoStart(),
      'keep_on_exit': await c.getKeepOnExit(),
      'background_mode': mode.wireValue,
      'core_logs_enabled': await c.getCoreLogsEnabled(),
      'allow_bypass': await c.getAllowBypass(),
    };
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
  } else if (storage != null) {
    throw const BadRequest('storage must be a JSON object');
  }

  final vpn = body['vpn_settings'];
  if (vpn is Map<String, dynamic>) {
    final c = BoxVpnClient();
    var n = 0;
    if (vpn.containsKey('auto_start')) {
      await c.setAutoStart(vpn['auto_start'] == true);
      n++;
    }
    if (vpn.containsKey('keep_on_exit')) {
      await c.setKeepOnExit(vpn['keep_on_exit'] == true);
      n++;
    }
    if (vpn.containsKey('background_mode')) {
      await c.setBackgroundMode(
          BackgroundMode.fromNative(vpn['background_mode']?.toString()));
      n++;
    }
    if (vpn.containsKey('core_logs_enabled')) {
      await c.setCoreLogsEnabled(vpn['core_logs_enabled'] == true);
      n++;
    }
    if (vpn.containsKey('allow_bypass')) {
      await c.setAllowBypass(vpn['allow_bypass'] == true);
      n++;
    }
    applied['vpn_settings'] = n;
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
        applied['rebuild_error'] = sub.lastError;
      }
    }
  }

  return JsonResponse({'applied': applied}, pretty: true);
}
