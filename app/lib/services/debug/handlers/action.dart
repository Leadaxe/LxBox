import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../../models/custom_rule.dart';
import '../../app_log.dart';
import '../../error_humanize.dart';
import '../../rule_set_downloader.dart';
import '../../settings_storage.dart';
import '../../subscription/auto_updater.dart';
import '../../update_checker.dart';
import '../../../screens/about_screen.dart';
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
    '/action/ping-all' => _pingAll(ctx),
    '/action/ping-node' => _pingNode(req, ctx),
    '/action/run-urltest' => _runUrltest(req, ctx),
    '/action/switch-node' => _switchNode(req, ctx),
    '/action/set-group' => _setGroup(req, ctx),
    '/action/start-vpn' => _startVpn(ctx),
    '/action/stop-vpn' => _stopVpn(ctx),
    '/action/rebuild-config' => _rebuildConfig(ctx),
    '/action/refresh-subs' => _refreshSubs(req, ctx),
    '/action/download-srs' => _downloadSrs(req, ctx),
    '/action/clear-srs' => _clearSrs(req, ctx),
    '/action/toast' => _toast(req, ctx),
    '/action/emulate-error' => _emulateError(req, ctx),
    '/action/check-updates' => _checkUpdates(req, ctx),
    _ => throw NotFound('action: ${req.path}'),
  };
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
    localVersion: AboutScreen.versionString,
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

Future<DebugResponse> _pingAll(DebugContext ctx) async {
  final home = ctx.requireHome();
  unawaited(home.pingAllNodes());
  return _ok('ping-all');
}

Future<DebugResponse> _pingNode(DebugRequest req, DebugContext ctx) async {
  final home = ctx.requireHome();
  final tag = req.requiredQuery('tag');
  unawaited(home.pingNode(tag));
  return _ok('ping-node', {'tag': tag});
}

Future<DebugResponse> _runUrltest(DebugRequest req, DebugContext ctx) async {
  final home = ctx.requireHome();
  final group = req.requiredQuery('group');
  if (!home.state.tunnelUp) {
    throw const Conflict('tunnel not connected');
  }
  unawaited(home.runGroupUrltest(group));
  return _ok('run-urltest', {'group': group});
}

Future<DebugResponse> _switchNode(DebugRequest req, DebugContext ctx) async {
  final home = ctx.requireHome();
  final tag = req.requiredQuery('tag');
  if (home.state.selectedGroup == null) {
    throw const Conflict('no group selected — use /action/set-group first');
  }
  unawaited(home.switchNode(tag));
  return _ok('switch-node', {'tag': tag});
}

Future<DebugResponse> _setGroup(DebugRequest req, DebugContext ctx) async {
  final home = ctx.requireHome();
  final group = req.requiredQuery('group');
  home.setSelectedGroup(group);
  unawaited(home.applyGroup(group));
  return _ok('set-group', {'group': group});
}

Future<DebugResponse> _startVpn(DebugContext ctx) async {
  final home = ctx.requireHome();
  unawaited(home.start());
  return _ok('start-vpn');
}

Future<DebugResponse> _stopVpn(DebugContext ctx) async {
  final home = ctx.requireHome();
  unawaited(home.stop());
  return _ok('stop-vpn');
}

Future<DebugResponse> _rebuildConfig(DebugContext ctx) async {
  final sub = ctx.requireSub();
  final home = ctx.requireHome();
  final json = await sub.generateConfig();
  if (json == null) {
    throw UpstreamError('generate failed: ${sub.lastError}');
  }
  final saved = await home.saveParsedConfig(json);
  if (!saved) {
    throw const UpstreamError('saveParsedConfig returned false');
  }
  return _ok('rebuild-config', {'bytes': json.length});
}

Future<DebugResponse> _refreshSubs(DebugRequest req, DebugContext ctx) async {
  final updater = ctx.autoUpdater;
  if (updater == null) {
    throw const Conflict('auto updater not ready');
  }
  final force = req.qBool('force');
  unawaited(updater.maybeUpdateAll(UpdateTrigger.manual, force: force));
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
const _methodChannel = MethodChannel('com.leadaxe.lxbox/methods');

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
