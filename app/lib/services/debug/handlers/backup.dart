import 'dart:async';

import 'package:package_info_plus/package_info_plus.dart';

import '../../../controllers/subscription_controller.dart';
import '../../l10n/locale_controller.dart';
import '../../record_vars.dart';
import '../../settings_storage.dart';
import '../../storage_migration/migrate_storage.dart';
import '../../template_loader.dart';
import '../../workspaces/workspace_controller.dart';
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

/// `GET /backup/export[?include=storage,vpn_settings][&from=v0_bak]` → JSON.
/// Default `include` — всё. Каждая часть опциональна; пустое или
/// отсутствующее поле в выходе означает «нечего экспортировать».
///
/// §439 §3.5 — `from=v0_bak`: блок `storage` берётся из
/// `lxbox_settings.json.v0.bak` (состояние формы 2.23.2 на момент миграции),
/// а не из живого хранения. Такой конверт принимает `POST /backup/import`
/// версии 2.23.2 — путь отката для стендов. Копии нет — 404.
Future<DebugResponse> _export(DebugRequest req) async {
  final from = req.query['from'];
  if (from != null && from != 'v0_bak') {
    throw BadRequest('from must be "v0_bak", got "$from"');
  }
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
    if (from == 'v0_bak') {
      final v0 = await SettingsStorage.exportV0Backup();
      if (v0 == null) {
        throw const NotFound(
          'backup: no lxbox_settings.json.v0.bak on this '
          'device (storage was never migrated from the 2.23.2 form)',
        );
      }
      out['storage'] = v0;
    } else {
      out['storage'] = await SettingsStorage.exportRaw();
    }
  }
  if (include.contains('vpn_settings')) {
    // §189 — единая сериализация (делегат NativePrefs, как BackupService).
    out['vpn_settings'] = await SettingsStorage.exportNativePrefsBackup();
  }
  return JsonResponse(out, pretty: true);
}

/// `POST /backup/import[?merge=false&rebuild=false]`. Body — JSON объект
/// с полями `storage` и/или `vpn_settings`.
/// - §439 §3.4 — блок `storage` формы 2.23.2 (без `storage_version`)
///   принимается и мигрирует до allowlist'а; в ответе `applied.migrated: true`
///   и отчёт `applied.migration`.
/// - `merge=false` (default) — replace existing.
/// - `merge=true` — слияние §633 (`mergeStorageDoc`): добавляется то, чего у
///   получателя нет; его записи и значения остаются. Итог — `applied.merge`.
/// - `rebuild=true` — после restore зовёт `SubscriptionController.generateConfig`
///   и сохраняет в HomeState (то же что `POST /action/rebuild-config`).
Future<DebugResponse> _import(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final merge = req.qBool('merge');
  final rebuild = req.qBool('rebuild');
  final applied = <String, dynamic>{};

  // §748 — запись идёт мимо контроллеров главного экрана: сцена
  // пересоздаётся (как импорт с экрана Backup), иначе их снимок в памяти
  // затёр бы импортированное первой же мутацией. И при сбое посреди записи.
  final oldSub = ctx.sub;
  var wrote = false;
  try {
    final storage = body['storage'];
    if (storage is Map<String, dynamic>) {
      // §439 §3.4 — форма 2.23.2 мигрирует здесь, до replaceRaw: отчёт уходит
      // в ответ. Шаблон — ради `ref` preset-серверов DNS.
      final template = await TemplateLoader.load();
      final legacy = storageDocNeedsMigration(storage);
      final migration = migrateStorageDoc(
        storage,
        presetIdByDnsServerTag: legacy
            ? presetIdsByDnsServerTag(template.selectableRules)
            : const {},
        // §439 п. 8 — ссылки на узлы подписок тем же словарём, что у `_load`.
        subscriptionBodies: legacy
            ? await SettingsStorage.subscriptionBodiesForMigration(storage)
            : const {},
        // §441 — Н2–Н4 у vars template-серверов DNS и пресетов.
        recordVars: legacy
            ? RecordVarDecls.fromTemplate(template)
            : RecordVarDecls.none,
      );
      applied['migrated'] = migration.migrated;
      if (migration.migrated || migration.warnings.isNotEmpty) {
        applied['migration'] = migration.toReportJson();
      }
      // §159 — replaceRaw применяет allowlist (default-deny). Отброшенные
      // неизвестные/чужеродные ключи возвращаются и отдаются в ответе.
      wrote = true;
      final dropped = await SettingsStorage.replaceRaw(
        migration.doc,
        merge: merge,
        onMerged: (stats) => applied['merge'] = stats.toJson(),
      );
      applied['storage_keys'] = storage.length;
      if (dropped.isNotEmpty) applied['dropped_keys'] = dropped;
      // §279 — restore мог привезти другой app_language: полный пайплайн смены
      // локали через владеющий контроллер (не голое значение в сторадже).
      await LocaleController.I.reloadFromStorage();
      // §393 A2 — порядок restore→migrate. Легаси-пару `channels` уже
      // переименовала миграция выше; вызов остаётся ради fresh-seed, когда тело
      // не принесло Направлений вовсе. Тот же вызов, что в
      // `BackupService.applyImport`; идемпотентен на новых ключах.
      await SettingsStorage.migrateDirectionsIfNeeded(
        template.groupTemplates,
        varDefaults: {for (final v in template.vars) v.name: v.defaultValue},
      );
      // §757 — ссылки на прежние теги наборов правил (архив без маркера).
      await SettingsStorage.migrateRuleSetTagRefsIfNeeded(template);
    } else if (storage != null) {
      throw const BadRequest('storage must be a JSON object');
    }

    final vpn = body['vpn_settings'];
    if (vpn is Map<String, dynamic>) {
      // §189 — единая сериализация (делегат NativePrefs, как BackupService).
      // §633 — Merge: тумблеры, которые у получателя есть, остаются его.
      var vpnKept = 0;
      wrote = true;
      applied['vpn_settings'] = await SettingsStorage.applyNativePrefsBackup(
        vpn,
        onlyMissing: merge,
        onKept: (_) => vpnKept++,
      );
      if (merge) applied['vpn_settings_kept'] = vpnKept;
    } else if (vpn != null) {
      throw const BadRequest('vpn_settings must be a JSON object');
    }
  } finally {
    if (wrote) await WorkspaceController.I.remountAfterExternalWrite();
  }
  if (wrote) applied['remounted'] = true;

  if (rebuild) {
    // §748 — старый контроллер после remount устарел: собрал бы конфиг из
    // прежнего снимка. Ждём новый (регистрируется при initState нового
    // HomeScreen; в фоне кадров нет — тогда честный `rebuilt: false`).
    final sub = wrote ? await _awaitRemountedSub(ctx, oldSub) : ctx.sub;
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
    } else if (wrote) {
      applied['rebuilt'] = false;
      applied['rebuild_error'] = 'home screen not remounted yet';
    }
  }

  return JsonResponse({'applied': applied}, pretty: true);
}

/// §748 — новый `SubscriptionController` после remount, прочитавший
/// хранилище; `null`, если за [timeout] он не появился.
Future<SubscriptionController?> _awaitRemountedSub(
  DebugContext ctx,
  SubscriptionController? old, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final sub = ctx.sub;
    if (sub != null && !identical(sub, old)) {
      try {
        await sub.rehydrationDone.timeout(deadline.difference(DateTime.now()));
        return sub;
      } on TimeoutException {
        return null;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return null;
}
