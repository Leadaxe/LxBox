import 'dart:convert';

import '../../../models/server_list.dart';
import '../../../vpn/box_vpn_client.dart';
import '../../settings_storage.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// `/backup/*` — экспорт/импорт пользовательских данных (config + vars +
/// server_lists). Симметрично друг другу: что отдаёт `GET /backup/export`
/// — принимает `POST /backup/import`. Кеши (cache.db, stderr.log, SRS-blob,
/// runtime node-tags) не включаются — restore их пересоздаст.
///
/// `/diag/dump` (см. handlers/diag.dart) тоже совместим с `/backup/import`:
/// поля `debug_log`/`stderr_log`/`exit_info`/`logcat_tail` игнорируются.
Future<DebugResponse> backupHandler(DebugRequest req, DebugContext ctx) async {
  return switch ('${req.method} ${req.path}') {
    'GET /backup/export' => _export(req),
    'POST /backup/import' => _import(req, ctx),
    _ => throw NotFound('backup: ${req.method} ${req.path}'),
  };
}

const _allParts = {'config', 'vars', 'subs'};

/// `GET /backup/export[?include=config,vars,subs]` → JSON.
/// Default `include` — все три. Каждая часть опциональна; пустое или
/// отсутствующее поле в выходе означает «нечего экспортировать».
Future<DebugResponse> _export(DebugRequest req) async {
  final raw = (req.query['include'] ?? 'config,vars,subs');
  final include = raw
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .where(_allParts.contains)
      .toSet();
  final out = <String, dynamic>{
    'app': 'lxbox',
    'kind': 'backup',
    'version': 1,
  };
  if (include.contains('config')) {
    final cfg = await BoxVpnClient().getConfig();
    if (cfg.isNotEmpty && cfg != '{}') {
      try {
        out['config'] = jsonDecode(cfg);
      } catch (_) {
        out['config'] = cfg;
      }
    } else {
      out['config'] = null;
    }
  }
  if (include.contains('vars')) {
    out['vars'] = await SettingsStorage.getAllVars();
  }
  if (include.contains('subs')) {
    final lists = await SettingsStorage.getServerLists();
    // Только persisted-shape (URL/name/meta), без runtime node-blob'ов.
    out['server_lists'] = lists.map((l) => l.toJson()).toList();
  }
  return JsonResponse(out, pretty: true);
}

/// `POST /backup/import[?merge=false&rebuild=false]`. Body — JSON объект
/// с любыми из полей `config`, `vars`, `server_lists`.
/// - `merge=false` (default) — replace существующие данные.
/// - `merge=true` — добавить к существующим (vars upsert, subs append-by-id).
/// - `rebuild=true` — после restore зовёт `SubscriptionController.generateConfig`
///   и сохраняет в HomeState (то же что `POST /action/rebuild-config`).
Future<DebugResponse> _import(DebugRequest req, DebugContext ctx) async {
  final body = req.jsonBodyAsMap();
  final merge = req.qBool('merge');
  final rebuild = req.qBool('rebuild');
  final applied = <String, dynamic>{};

  // Config
  final cfg = body['config'];
  if (cfg != null) {
    final raw = cfg is String ? cfg : jsonEncode(cfg);
    final ok = await BoxVpnClient().saveConfig(raw);
    applied['config'] = ok;
  }

  // Vars
  final vars = body['vars'];
  if (vars is Map) {
    if (!merge) {
      // Replace mode — стираем текущие vars перед applying.
      final current = await SettingsStorage.getAllVars();
      for (final k in current.keys) {
        await SettingsStorage.removeVar(k);
      }
    }
    var n = 0;
    for (final entry in vars.entries) {
      final v = entry.value;
      if (v == null) continue;
      await SettingsStorage.setVar(entry.key.toString(), v.toString());
      n++;
    }
    applied['vars'] = n;
  }

  // Server lists
  final subs = body['server_lists'];
  if (subs is List) {
    final parsed = subs
        .whereType<Map<String, dynamic>>()
        .map(ServerList.fromJson)
        .toList();
    if (merge) {
      final existing = await SettingsStorage.getServerLists();
      final ids = existing.map((e) => e.id).toSet();
      for (final p in parsed) {
        if (!ids.contains(p.id)) existing.add(p);
      }
      await SettingsStorage.saveServerLists(existing);
    } else {
      await SettingsStorage.saveServerLists(parsed);
    }
    applied['server_lists'] = parsed.length;
  }

  // Optional rebuild — то же что `/action/rebuild-config`.
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
