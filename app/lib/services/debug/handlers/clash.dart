import 'dart:async';

import 'package:http/http.dart' as http;

import '../../../config/clash_endpoint.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';

/// `/clash/*` — прозрачный прокси на Clash API sing-box'а. Подмешиваем
/// `Authorization: Bearer <secret>`, форвардим метод/path/query/body,
/// отдаём upstream-статус как есть (включая 204, 4xx, 5xx).
///
/// Зачем: разработчику через adb не нужно знать рандомный `secret` из
/// config'а — достаточно bearer'а Debug API.
Future<DebugResponse> clashHandler(DebugRequest req, DebugContext ctx) async {
  final home = ctx.requireHome();
  final endpoint = ClashEndpoint.fromConfigJson(home.state.configRaw);
  if (endpoint == null) {
    throw const Conflict('Clash API not configured in current config');
  }

  // `/clash/proxies/foo` → upstream `/proxies/foo`
  final upstreamPath = req.path.substring('/clash'.length);
  if (upstreamPath.isEmpty) {
    throw const BadRequest('empty upstream path');
  }

  final base = endpoint.baseUri.toString();
  final origin = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  final upstreamUri = Uri.parse('$origin$upstreamPath').replace(
    queryParameters: req.uri.queryParameters.isEmpty
        ? null
        : req.uri.queryParameters,
  );

  // Upstream timeout — чуть короче requestTimeout pipeline'а, чтобы
  // апстрим успел отвалиться с UpstreamError до того как сам pipeline
  // рубанёт RequestTimeout. Пять секунд запаса на пост-обработку.
  final upstreamTimeout =
      ctx.config.requestTimeout - const Duration(seconds: 5);
  final effectiveTimeout = upstreamTimeout.isNegative
      ? ctx.config.requestTimeout
      : upstreamTimeout;

  final client = http.Client();
  try {
    final upstreamReq = http.Request(req.method, upstreamUri);
    if (endpoint.secret.isNotEmpty) {
      upstreamReq.headers['Authorization'] = 'Bearer ${endpoint.secret}';
    }
    if (req.body.isNotEmpty) {
      upstreamReq.bodyBytes = req.body;
      final ct = req.header('content-type');
      if (ct != null) upstreamReq.headers['content-type'] = ct;
    }
    final streamed = await client.send(upstreamReq).timeout(effectiveTimeout);
    final bytes = await streamed.stream.toBytes();
    final contentType =
        streamed.headers['content-type'] ?? 'application/octet-stream';
    return BytesResponse(
      bytes,
      status: streamed.statusCode,
      contentType: contentType,
    );
  } on TimeoutException {
    throw const UpstreamError('Clash API timeout');
  } on http.ClientException catch (e) {
    throw UpstreamError('Clash API: ${e.message}');
  } finally {
    client.close();
  }
}
