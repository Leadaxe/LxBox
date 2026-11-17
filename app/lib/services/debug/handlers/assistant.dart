import 'dart:convert';

import '../../../vpn/box_vpn_client.dart';
import '../../assistant/assistant_actions.dart';
import '../../assistant/assistant_index.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';
import '_shared.dart';

/// §750 — `/assistant/*`: тот же набор, что у функций ИИ-ассистента
/// (AppFunctions), для агента на компьютере. Подтверждение не спрашивается —
/// доступ к Debug API уже выдан владельцем устройства.
///
/// Чтения и проверки делает натив (методы канала `assistant*`, ответ
/// пробрасывается как есть); `{"error":{code,message}}` натива → HTTP-ошибка:
/// `not_found` → 404, `invalid_argument` → 400, `vpn_off` / `busy` /
/// `locked` / `source_off` → 409, прочее → 500. Код натива
/// остаётся первым словом сообщения (`vpn_off: …`).
///
/// Routes:
/// - `GET  /assistant/overview`
/// - `GET  /assistant/exits?direction=&q=`
/// - `POST /assistant/check-url`    `{url, app?}`
/// - `POST /assistant/check-exit`   `{direction}`
/// - `GET  /assistant/apps?q=`
/// - `GET  /assistant/app-route?app=`
/// - `POST /assistant/exit`         `{direction, exit}`
/// - `POST /assistant/connection`   `{id, enabled}`
///
/// Маршрут приложения меняется общим `POST /rules` (узкая операция снята
/// решением владельца 17.11.2026). Индекс (подписи Направлений, подключения,
/// правила приложений) собирается в момент запроса и уходит нативу
/// аргументом — ничего заранее не считается. `direction` — только тег.
Future<DebugResponse> assistantHandler(DebugRequest req, DebugContext ctx) async {
  final client = BoxVpnClient.I;
  switch (req.path) {
    case '/assistant/overview':
      _requireMethod(req, 'GET');
      // Индекс собирается сейчас: натив берёт из него подписи и подключения.
      return _native(await client.assistantOverview(await _indexJson()));

    case '/assistant/exits':
      _requireMethod(req, 'GET');
      final direction = req.requiredQuery('direction');
      final q = (req.q('q') ?? '').trim();
      return _native(await client.assistantListExits(direction,
          query: q.isEmpty ? null : q));

    case '/assistant/check-url':
      _requireMethod(req, 'POST');
      final body = req.jsonBodyAsMap();
      final url = _requiredString(body, 'url');
      final app = fieldString(body, 'app')?.trim();
      return _native(await client.assistantCheckUrl(url,
          app: app == null || app.isEmpty ? null : app));

    case '/assistant/check-exit':
      _requireMethod(req, 'POST');
      final body = req.jsonBodyAsMap();
      return _native(
          await client.assistantCheckExit(_requiredString(body, 'direction')));

    case '/assistant/apps':
      _requireMethod(req, 'GET');
      return _native(await client.assistantFindApps(req.requiredQuery('q')));

    case '/assistant/app-route':
      _requireMethod(req, 'GET');
      final app = req.requiredQuery('app');
      return _native(await client.assistantAppRoute(await _indexJson(), app));

    case '/assistant/exit':
      _requireMethod(req, 'POST');
      final body = req.jsonBodyAsMap();
      return _native(await client.assistantSelectExit(
          _requiredString(body, 'direction'), _requiredString(body, 'exit')));

    case '/assistant/connection':
      _requireMethod(req, 'POST');
      final body = req.jsonBodyAsMap();
      final id = _requiredString(body, 'id');
      final enabled = fieldBool(body, 'enabled');
      if (enabled == null) {
        throw const BadRequest('body must contain "enabled": true|false');
      }
      final sub = ctx.requireSub();
      try {
        return JsonResponse(await setConnectionEnabled(
          id: id,
          enabled: enabled,
          sub: sub,
          home: ctx.home,
        ));
      } on AssistantError catch (e) {
        throw assistantDebugError(e.code, e.message);
      }
  }
  throw NotFound('assistant path: ${req.path}');
}

/// §750 — индекс ассистента, собранный сейчас, строкой JSON.
Future<String> _indexJson() async => jsonEncode(await collectAssistantIndex());

void _requireMethod(DebugRequest req, String method) {
  if (req.method != method) {
    throw BadRequest('${req.path} requires $method, got ${req.method}');
  }
}

String _requiredString(Map<String, dynamic> body, String key) {
  final v = fieldString(body, key)?.trim();
  if (v == null || v.isEmpty) {
    throw BadRequest('body must contain non-empty "$key"');
  }
  return v;
}

/// Ответ натива: данные — как есть; `{"error":{...}}` — HTTP-ошибка.
DebugResponse _native(Object? r) {
  if (r is Map && r['error'] is Map) {
    final err = r['error'] as Map;
    throw assistantDebugError(
      '${err['code'] ?? 'core_error'}',
      '${err['message'] ?? ''}',
    );
  }
  if (r == null) {
    throw assistantDebugError('core_error', 'empty answer from the app');
  }
  return JsonResponse(r);
}

/// §750 — код ошибки ассистента → класс ошибки Debug API (статус HTTP).
DebugError assistantDebugError(String code, String message) {
  final text = message.isEmpty ? code : '$code: $message';
  return switch (code) {
    'not_found' => NotFound(text),
    'invalid_argument' => BadRequest(text),
    'vpn_off' || 'busy' || 'locked' || 'source_off' =>
      Conflict(text),
    _ => InternalError(text),
  };
}
