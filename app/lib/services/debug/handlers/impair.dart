import 'dart:convert';

import 'package:flutter/services.dart';

import '../../../vpn/cc_channel.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// `/impair` — §762 (ядро SPEC 164): управление тестовым outbound `impair`
/// работающего ядра без перезапуска. В интерфейсе `impair` нет (решение
/// владельца 26.11); outbound попадает в конфиг руками (`PUT /config`,
/// миксин), маршрут только меняет его линию.
///
/// Routes:
/// - `GET  /impair/{tag}`          → статус ядра как есть:
///   `{tag, link_params, counters, sublinks, schedule}`
/// - `POST /impair/{tag}/set`      → body — запись расписания без `at`
///   (JSON-объект: `link_params`, `sublinks` или оба), уходит в ядро
///   компактным JSON; ответ — статус
/// - `POST /impair/{tag}/schedule` → body `{"entries": [...], "start":
///   ""|"now"|"first_use", "repeat": ""|"60s"}`; `entries: []` — стоп
///   расписания и линия по конфигу; ответ — статус
///
/// Тег — из раскодированных сегментов пути: тег с эмодзи передаётся
/// URL-encoded. Смысл ключей проверяет ядро. Клиент недоступен (туннель не
/// поднят) → 409; ошибки ядра: `not_found` → 404, `invalid_argument` → 400,
/// `failed_precondition` / `unavailable` → 409, `unimplemented` (ядро без
/// ручки) → 501, прочее → 502; текст ядра — в `error.message`. Пути, тела и
/// коды совпадают с Debug API лаунчера (его спека 190-F-C-IMPAIR_DEBUG_API),
/// конверт ошибки — свой.
Future<DebugResponse> impairHandler(DebugRequest req, DebugContext ctx) async {
  final s = req.uri.pathSegments;
  if (s.length < 2 || s.length > 3 || s[0] != 'impair' || s[1].isEmpty) {
    throw NotFound('impair path: ${req.path}');
  }
  final tag = s[1];
  final action = s.length == 3 ? s[2] : null;
  final cc = CcChannel.instance;
  switch (action) {
    case null:
      _requireMethod(req, 'GET', '/impair/{tag}');
      return _call(() => cc.getImpairStatus(tag));
    case 'set':
      _requireMethod(req, 'POST', '/impair/{tag}/set');
      final entry = _objectBody(req);
      return _call(() => cc.setImpair(tag, entry));
    case 'schedule':
      _requireMethod(req, 'POST', '/impair/{tag}/schedule');
      final body = req.jsonBodyAsMap();
      final entries = body['entries'];
      if (entries is! List) {
        throw const BadRequest('"entries" must be a JSON array ([] resets)');
      }
      final start = _optString(body, 'start');
      if (!_kStarts.contains(start)) {
        throw BadRequest('"start" must be "", "now" or "first_use", '
            'got "$start"');
      }
      final repeat = _optString(body, 'repeat');
      return _call(() =>
          cc.scheduleImpair(tag, entries, start: start, repeat: repeat));
  }
  throw NotFound('impair path: ${req.path}');
}

const _kStarts = {'', 'now', 'first_use'};

void _requireMethod(DebugRequest req, String method, String route) {
  if (req.method != method) {
    throw BadRequest('method ${req.method} not allowed on $route');
  }
}

/// Непустой JSON-объект тела — компактным JSON (как у лаунчера, спека 190).
String _objectBody(DebugRequest req) {
  final parsed = req.jsonBodyAsMap();
  if (parsed.isEmpty) {
    throw const BadRequest(
        'body must be a non-empty JSON object: link_params, sublinks or both');
  }
  return jsonEncode(parsed);
}

String _optString(Map<String, dynamic> body, String key) {
  final v = body[key];
  if (v == null) return '';
  if (v is! String) throw BadRequest('"$key" must be a string');
  return v;
}

Future<DebugResponse> _call(
    Future<Map<String, dynamic>?> Function() run) async {
  final Map<String, dynamic>? status;
  try {
    status = await run();
  } on PlatformException catch (e) {
    final text = e.message ?? e.code;
    throw switch (e.code) {
      CcStatusError.notFound => NotFound(text),
      CcStatusError.invalidArgument => BadRequest(text),
      CcStatusError.failedPrecondition || CcStatusError.unavailable =>
        Conflict(text),
      CcStatusError.unimplemented => NotImplemented(text),
      _ => UpstreamError(text),
    };
  } on FormatException catch (e) {
    throw UpstreamError('core status is not JSON: ${e.message}');
  }
  if (status == null) {
    throw const Conflict('cc client unavailable (tunnel down?)');
  }
  return JsonResponse(status);
}
