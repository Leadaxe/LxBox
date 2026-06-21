import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../../models/custom_rule.dart';
import '../../app_log.dart';
import '../../automation/handlers.dart' as automation;
import '../../error_humanize.dart';
import '../../platform_channels.dart';
import '../../rule_set_downloader.dart';
import '../../settings_storage.dart';
import '../../update_checker.dart';
import '../../version_info.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// `/action/*` — side-effect triggers. Все endpoints требуют POST.
///
/// Контракт ответа: если action сматчен и handler дошёл до конца — ответ
/// всегда `{"ok": true, "action": "<name>", ...extras}`. Любой failure
/// (missing param, precondition, upstream crash) — соответствующий
/// [DebugError]. Юзер сверху получает либо 200 + ok=true, либо 4xx/5xx
/// — никаких `ok: false` в 200 ответах.
///
/// Большинство триггеров fire-and-forget: домен работает асинхронно,
/// статус читается через `/state`. Это матчит UI ("нажал — отпустил")
/// и даёт консистентные тайминги.
Future<DebugResponse> actionHandler(
  DebugRequest req,
  DebugContext ctx,
) async {
  if (req.method != 'POST') {
    throw const BadRequest('actions require POST');
  }
  return switch (req.path) {
    '/action/urltest' => _urltest(req, ctx),
    '/action/switch-node' => _switchNode(req, ctx),
    '/action/set-group' => _setGroup(req, ctx),
    '/action/start-vpn' => _startVpn(ctx),
    '/action/stop-vpn' => _stopVpn(ctx),
    '/action/force-stop-vpn' => _forceStopVpn(ctx),
    '/action/set-transient-timeout' => _setTransientTimeout(req, ctx),
    '/action/reset-network' => _resetNetwork(ctx),
    '/action/rebuild-config' => _rebuildConfig(ctx),
    '/action/refresh-subs' => _refreshSubs(req, ctx),
    '/action/download-srs' => _downloadSrs(req, ctx),
    '/action/clear-srs' => _clearSrs(req, ctx),
    '/action/toast' => _toast(req, ctx),
    '/action/emulate-error' => _emulateError(req, ctx),
    '/action/check-updates' => _checkUpdates(req, ctx),
    '/action/preview-empty-state' => _previewEmptyState(req, ctx),
    _ => throw NotFound('action: ${req.path}'),
  };
}

/// POST /action/preview-empty-state?on=true|false
///
/// UI-only override: HomeScreen рендерит empty-state как при чистой
/// инсталляции (`Add a server` CTA вместо узлов и Start), реальные
/// данные не стираются. Полезно для скриншотов / regression-теста UX
/// без `pm clear`.
///
/// Возвращает: `{"ok": true, "action": "preview-empty-state", "on": <bool>}`.
Future<DebugResponse> _previewEmptyState(
  DebugRequest req,
  DebugContext ctx,
) async {
  final home = ctx.home;
  if (home == null) throw const Conflict('home controller not ready');
  final on = (req.query['on'] ?? 'true').toLowerCase() == 'true';
  home.setPreviewEmpty(on);
  return JsonResponse({
    'ok': true,
    'action': 'preview-empty-state',
    'on': on,
  });
}

/// Force update check (bypass 24h cap + auto_check_updates toggle).
/// Mirrors UI "Check now" button. Returns the result so the caller can
/// see what UpdateChecker found, без захода в /logs.
///
/// Body: none. Query: none.
/// Response: {"ok": true, "action": "check-updates", "kind": "newer|upToDate|failed|skipped",
///            "tag": "v1.5.0", "html_url": "...", "message": "...", "dismissed": false}
Future<DebugResponse> _checkUpdates(DebugRequest req, DebugContext ctx) async {
  final result = await UpdateChecker.I.forceCheck(
    localVersion: VersionInfo.I.version,
  );
  final body = <String, Object?>{
    'ok': true,
    'action': 'check-updates',
    'kind': result.kind.name,
  };
  final info = result.info;
  if (info != null) {
    body['tag'] = info.tag;
    body['name'] = info.name;
    body['html_url'] = info.htmlUrl;
    body['published_at'] = info.publishedAt?.toUtc().toIso8601String();
    body['dismissed'] = result.dismissed;
  }
  if (result.localVersion != null) body['local_version'] = result.localVersion;
  if (result.message != null) body['message'] = result.message;
  return JsonResponse(body);
}

/// Эмулирует ошибку для демонстрации humanizeError'а.
/// POST /action/emulate-error?kind=<socket|timeout|http-401|http-404|
///   http-410|http-429|http-503|format|fs|plain|all>
///
/// Writes humanized samples to AppLog (строка вида
/// `emulate-error [kind=...]: <humanized>`). Просмотр — через `/logs`.
/// `kind=all` прогоняет весь набор.
Future<DebugResponse> _emulateError(
  DebugRequest req,
  DebugContext ctx,
) async {
  final kind = req.requiredQuery('kind');

  Exception buildException(String k) => switch (k) {
        'socket' => const SocketException('emulated: host lookup failed'),
        'timeout' => TimeoutException('emulated: request timeout'),
        'http-401' =>
          const HttpException('HTTP 401 for https://provider.example/sub/***'),
        'http-404' =>
          const HttpException('HTTP 404 for https://provider.example/sub/***'),
        'http-410' =>
          const HttpException('HTTP 410 for https://provider.example/sub/***'),
        'http-429' =>
          const HttpException('HTTP 429 for https://provider.example/sub/***'),
        'http-503' =>
          const HttpException('HTTP 503 for https://provider.example/sub/***'),
        'format' => const FormatException('emulated: not valid JSON'),
        'fs' => const FileSystemException('emulated: permission denied'),
        'plain' => Exception('emulated plain exception text'),
        _ => throw BadRequest(
            'kind must be one of socket|timeout|http-401|http-404|'
            'http-410|http-429|http-503|format|fs|plain|all, got "$k"'),
      };

  final kinds = kind == 'all'
      ? [
          'socket',
          'timeout',
          'http-401',
          'http-404',
          'http-410',
          'http-429',
          'http-503',
          'format',
          'fs',
          'plain',
        ]
      : [kind];

  final samples = <Map<String, String>>[];
  for (final k in kinds) {
    final e = buildException(k);
    final humanized = humanizeError(e);
    samples.add({'kind': k, 'humanized': humanized});
    AppLog.I.error('emulate-error [kind=$k]: $humanized');
  }

  return _ok('emulate-error', {'samples': samples});
}

/// Единый конструктор успешного ответа.
JsonResponse _ok(String action, [Map<String, Object?> extras = const {}]) {
  return JsonResponse({
    'ok': true,
    'action': action,
    ...extras,
  });
}

/// `/action/urltest` — единый endpoint для запуска URLTest. Scope
/// определяется query-param'ом (ровно один из):
///
/// - `?tag=<node>`  — single-node URLTest через clash `/proxies/<tag>/delay`
/// - `?group=<tag>` — group URLTest через clash `/group/<tag>/delay` (требует tunnel up)
/// - `?all=true`    — mass URLTest всех нод активной группы (concurrency 10)
Future<DebugResponse> _urltest(DebugRequest req, DebugContext ctx) async {
  final home = ctx.requireHome();
  final tag = req.query['tag'];
  final group = req.query['group'];
  final all = req.query['all'];
  final scopes = [
    if (tag != null) 'tag',
    if (group != null) 'group',
    if (all != null) 'all',
  ];
  if (scopes.isEmpty) {
    throw const BadRequest('one of "tag" / "group" / "all" required');
  }
  if (scopes.length > 1) {
    throw BadRequest('exactly one of "tag" / "group" / "all" — got ${scopes.join("+")}');
  }
  if (tag != null) {
    if (tag.isEmpty) throw const BadRequest('"tag" empty');
    unawaited(home.runNodeUrltest(tag));
    return _ok('urltest', {'scope': 'node', 'tag': tag});
  }
  if (group != null) {
    if (group.isEmpty) throw const BadRequest('"group" empty');
    if (!home.state.tunnelUp) {
      throw const Conflict('tunnel not connected');
    }
    unawaited(home.runGroupUrltest(group));
    return _ok('urltest', {'scope': 'group', 'group': group});
  }
  // all=true (or any value — presence-only flag)
  unawaited(home.runMassUrltest());
  return _ok('urltest', {'scope': 'mass'});
}

Future<DebugResponse> _switchNode(DebugRequest req, DebugContext ctx) async {
  final tag = req.requiredQuery('tag');
  await automation.actionSwitchNode(tag, ctx);
  return _ok('switch-node', {'tag': tag});
}

Future<DebugResponse> _setGroup(DebugRequest req, DebugContext ctx) async {
  final group = req.requiredQuery('group');
  await automation.actionSetGroup(group, ctx);
  return _ok('set-group', {'group': group});
}

Future<DebugResponse> _startVpn(DebugContext ctx) async {
  await automation.actionStartVpn(ctx);
  return _ok('start-vpn');
}

Future<DebugResponse> _stopVpn(DebugContext ctx) async {
  await automation.actionStopVpn(ctx);
  return _ok('stop-vpn');
}

/// `POST /action/force-stop-vpn` — §140, debug/diagnostics.
///
/// Напрямую дёргает native `forceStopVPN` (минуя transient-таймаут): тот же
/// путь `doForceStop`, что и при зависшем ядре. Освобождает Clash-порт 63130
/// (teardown ПЕРЕД `stopSelf`, §140), сервис убивается жёстко. В отличие от
/// `stop-vpn` (кооперативный, ждёт Stopped от ядра) — fire-and-forget.
///
/// Назначение: on-device проверка `doForceStop`-пути и того, что повторный старт
/// после force-stop НЕ падает с `bind: address already in use`.
/// Возвращает `{"ok": true, "action": "force-stop-vpn", "native_ok": <bool>}`.
Future<DebugResponse> _forceStopVpn(DebugContext ctx) async {
  final home = ctx.requireHome();
  final ok = await home.debugForceStopVpn();
  return _ok('force-stop-vpn', {'native_ok': ok});
}

/// `POST /action/set-transient-timeout?connecting=<ms>&stopping=<ms>` — §140.
///
/// Переопределяет пороги transient-таймаута (`_armTransientTimeout`) в
/// миллисекундах. Любой из параметров опционален — не переданный не меняется.
/// Минимум хотя бы один параметр. Для on-device теста force-stop'а: поставить
/// `connecting=500`, чтобы `_armTransientTimeout` сработал быстро, не дожидаясь
/// реального зависона ядра (issue #2).
///
/// Возвращает текущие (применённые) значения:
/// `{"ok": true, "action": "set-transient-timeout", "connecting_ms": N, "stopping_ms": N}`.
Future<DebugResponse> _setTransientTimeout(
  DebugRequest req,
  DebugContext ctx,
) async {
  final home = ctx.requireHome();
  final connectingRaw = req.q('connecting');
  final stoppingRaw = req.q('stopping');
  if (connectingRaw == null && stoppingRaw == null) {
    throw const BadRequest(
        'at least one of connecting/stopping (ms) required');
  }
  final connectingMs = _parsePositiveMs(connectingRaw, 'connecting');
  final stoppingMs = _parsePositiveMs(stoppingRaw, 'stopping');
  final applied = home.debugSetTransientTimeouts(
    connectingMs: connectingMs,
    stoppingMs: stoppingMs,
  );
  return _ok('set-transient-timeout', {
    'connecting_ms': applied.connectingMs,
    'stopping_ms': applied.stoppingMs,
  });
}

/// Парсит положительный int (мс) из query. `null` raw → `null` (не менять).
int? _parsePositiveMs(String? raw, String name) {
  if (raw == null) return null;
  final v = int.tryParse(raw);
  if (v == null || v <= 0) {
    throw BadRequest('$name must be a positive integer (ms), got "$raw"');
  }
  return v;
}

/// `POST /action/reset-network` — light recovery без recreate'а box runtime.
///
/// Дёргает `commandServer.resetNetwork()` через MethodChannel. Внутри sing-box:
///   - закрывает все active connections (`connectionManager.CloseAll()`)
///   - flush'ит DNS cache + reset'ит DoH/DoT/UDP transports
///   - передёргивает interface bindings у inbound/outbound/endpoint dialer'ов
/// БЕЗ recreate'а box, БЕЗ recreate'а Service, БЕЗ touch'а TUN fd, БЕЗ
/// перечитывания config'а. Tunnel остаётся `connected`. См. spec 031.
///
/// Требует tunnel up — без него resetNetwork no-op в libbox (нет instance).
/// Возвращает `{"ok": true, "action": "reset-network"}` независимо — реальный
/// эффект асинхронен и наблюдается через `/clash/connections` (counter
/// связей упадёт до ~0 моментально, потом начнёт заполняться заново).
Future<DebugResponse> _resetNetwork(DebugContext ctx) async {
  final ok = await automation.actionResetNetwork(ctx);
  return _ok('reset-network', {'native_ok': ok});
}

Future<DebugResponse> _rebuildConfig(DebugContext ctx) async {
  // §037: явный 409 если lock включён — обрабатывается внутри
  // automation.actionRebuildConfig (общий путь с Automation API).
  final bytes = await automation.actionRebuildConfig(ctx);
  return _ok('rebuild-config', {'bytes': bytes});
}

Future<DebugResponse> _refreshSubs(DebugRequest req, DebugContext ctx) async {
  final force = req.qBool('force');
  await automation.actionRefreshSubs(force, ctx);
  return _ok('refresh-subs', {'force': force});
}

Future<DebugResponse> _downloadSrs(DebugRequest req, DebugContext ctx) async {
  final id = req.requiredQuery('ruleId');
  final rules = await SettingsStorage.getCustomRules();
  CustomRule? rule;
  for (final r in rules) {
    if (r.id == id) {
      rule = r;
      break;
    }
  }
  if (rule == null) throw NotFound('rule: $id');
  if (rule.srsUrl.isEmpty) throw const Conflict('rule has no srsUrl');
  final path = await RuleSetDownloader.download(id, rule.srsUrl);
  if (path == null) throw const UpstreamError('srs download failed');
  return _ok('download-srs', {'rule_id': id, 'path': path});
}

Future<DebugResponse> _clearSrs(DebugRequest req, DebugContext ctx) async {
  final id = req.requiredQuery('ruleId');
  await RuleSetDownloader.delete(id);
  return _ok('clear-srs', {'rule_id': id});
}

/// Native platform channel для Toast. Расширяет существующий
/// `com.leadaxe.lxbox/methods` (см. `VpnPlugin.kt`) методом `showToast`.
/// Сообщение обрезается до 200 символов (Android Toast всё равно больше
/// не показывает).
const _methodChannel = MethodChannel(PlatformChannels.methods);

Future<DebugResponse> _toast(DebugRequest req, DebugContext ctx) async {
  final msg = req.requiredQuery('msg');
  final duration = req.q('duration') ?? 'short';
  if (duration != 'short' && duration != 'long') {
    throw BadRequest('duration must be "short" or "long", got "$duration"');
  }
  final trimmed = msg.length > 200 ? msg.substring(0, 200) : msg;
  try {
    await _methodChannel.invokeMethod('showToast', {
      'msg': trimmed,
      'duration': duration,
    });
  } on PlatformException catch (e) {
    throw UpstreamError('toast failed: ${e.message}');
  } on MissingPluginException {
    throw const Conflict('showToast not implemented in native plugin');
  }
  return _ok('toast', {'msg': trimmed, 'duration': duration});
}
