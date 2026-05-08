import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../contract/errors.dart';

/// Типизированный ответ. Handlers возвращают `DebugResponse` —
/// транспорт сам пишет в `HttpResponse` через [writeTo]. Подклассы:
/// JSON (построен из Map), RawJson (pre-encoded строка), Bytes (файл
/// in-memory), Stream (стрим больших тел), Error (DebugError → JSON).
sealed class DebugResponse {
  const DebugResponse();

  int get status;
  Map<String, String> get headers;

  /// Пишет ответ в сокет и закрывает `HttpResponse`. Может бросить
  /// `SocketException` если клиент отвалился — caller ловит и логирует.
  Future<void> writeTo(HttpResponse out);

  void _applyHeaders(HttpResponse out) {
    out.statusCode = status;
    for (final e in headers.entries) {
      out.headers.set(e.key, e.value);
    }
  }
}

/// JSON-ответ из Dart-объекта (Map/List/primitives).
class JsonResponse extends DebugResponse {
  const JsonResponse(this.body, {this.status = 200, this.pretty = false});

  final Object? body;
  @override
  final int status;
  final bool pretty;

  @override
  Map<String, String> get headers =>
      const {'content-type': 'application/json; charset=utf-8'};

  @override
  Future<void> writeTo(HttpResponse out) async {
    _applyHeaders(out);
    final encoder =
        pretty ? const JsonEncoder.withIndent('  ') : const JsonEncoder();
    out.write(encoder.convert(body));
    await out.close();
  }
}

/// Pre-encoded JSON-строка. Для `/config` — отдаём то что лежит на диске
/// без round-trip через jsonDecode+jsonEncode (sing-box чувствителен к
/// стабильности байтов, плюс лишняя работа).
class RawJsonResponse extends DebugResponse {
  const RawJsonResponse(this.raw, {this.status = 200});

  final String raw;
  @override
  final int status;

  @override
  Map<String, String> get headers =>
      const {'content-type': 'application/json; charset=utf-8'};

  @override
  Future<void> writeTo(HttpResponse out) async {
    _applyHeaders(out);
    out.write(raw);
    await out.close();
  }
}

/// In-memory байты. Для `/files/srs`, Clash-proxy ответов.
class BytesResponse extends DebugResponse {
  BytesResponse(
    this.bytes, {
    this.status = 200,
    this.contentType = 'application/octet-stream',
    this.filename,
    Map<String, String> extraHeaders = const {},
  }) : _extra = extraHeaders;

  final List<int> bytes;
  @override
  final int status;
  final String contentType;
  final String? filename;
  final Map<String, String> _extra;

  @override
  Map<String, String> get headers => {
        'content-type': contentType,
        'content-length': bytes.length.toString(),
        if (filename != null)
          'content-disposition': 'attachment; filename="$filename"',
        ..._extra,
      };

  @override
  Future<void> writeTo(HttpResponse out) async {
    _applyHeaders(out);
    out.add(bytes);
    await out.close();
  }
}

/// §044: Server-Sent Events stream. Не закрывается до окончания
/// stream'а / disconnect клиента. Каждый emit из [events] кодируется
/// как SSE-frame `event: <name>\ndata: <json>\n\n`.
///
/// Fire-and-forget: `Last-Event-ID` мы не поддерживаем; на reconnect
/// клиент подхватит с нового момента.
class SseResponse extends DebugResponse {
  SseResponse(this.events);

  /// Each event must contain `event` (string) и `data` (JSON-encodable).
  final Stream<Map<String, Object?>> events;

  @override
  int get status => 200;

  @override
  Map<String, String> get headers => const {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache',
        'connection': 'keep-alive',
        'x-accel-buffering': 'no',
      };

  @override
  Future<void> writeTo(HttpResponse out) async {
    _applyHeaders(out);
    // Flush headers immediately.
    await out.flush();
    final completer = Completer<void>();
    final sub = events.listen(
      (e) {
        try {
          final ev = e['event']?.toString() ?? 'message';
          final data = jsonEncode(e['data'] ?? {});
          out.write('event: $ev\n');
          out.write('data: $data\n\n');
          out.flush();
        } catch (_) {/* socket dead */}
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: false,
    );
    // detect client disconnect via response done future.
    out.done.then((_) {
      sub.cancel();
      if (!completer.isCompleted) completer.complete();
    }).catchError((_) {
      sub.cancel();
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    try {
      await out.close();
    } catch (_) {}
  }
}

/// Ответ-ошибка. Тело — `{"error": {"code": ..., "message": ..., "details": {...}}}`.
/// Создаётся `errorMapper` middleware из пойманного [DebugError].
class ErrorResponse extends DebugResponse {
  const ErrorResponse(this.error);

  final DebugError error;

  @override
  int get status => error.status;

  @override
  Map<String, String> get headers =>
      const {'content-type': 'application/json; charset=utf-8'};

  @override
  Future<void> writeTo(HttpResponse out) async {
    _applyHeaders(out);
    out.write(jsonEncode(error.toJson()));
    await out.close();
  }
}
