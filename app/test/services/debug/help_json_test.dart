import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/help.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';
import 'package:lxbox/services/debug/transport/server.dart';

/// Репро для бага /help?format=json (HTTP 000, пустой ответ). Проверяем, что
/// body ответа РЕАЛЬНО сериализуется тем же JsonEncoder, что в
/// JsonResponse.writeTo — если кинет, это и есть причина обрыва соединения.
void main() {
  DebugContext ctx() => DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2020),
      );

  DebugRequest req(String fmt) => DebugRequest(
        method: 'GET',
        uri: Uri.parse('http://127.0.0.1:9269/help?format=$fmt'),
        headers: const {},
        body: Uint8List(0),
        receivedAt: DateTime.utc(2026),
      );

  test('/help?format=json → JsonResponse, body сериализуется', () async {
    final resp = await helpHandler(req('json'), ctx());
    expect(resp, isA<JsonResponse>());
    final body = (resp as JsonResponse).body;
    // Ровно операция из JsonResponse.writeTo — тут воспроизведётся баг.
    final out = const JsonEncoder.withIndent('  ').convert(body);
    expect(out, isNotEmpty);
  });

  test('все ключи вложенных Map — String (иначе JsonEncoder падает)', () async {
    final resp = await helpHandler(req('json'), ctx()) as JsonResponse;
    final bad = <String>[];
    void walk(Object? o, String path) {
      if (o is List) {
        for (var i = 0; i < o.length; i++) {
          walk(o[i], '$path[$i]');
        }
      } else if (o is Map) {
        for (final k in o.keys) {
          if (k is! String) bad.add('$path: не-String ключ ($k)');
        }
        o.forEach((k, v) => walk(v, '$path.$k'));
      }
    }

    walk(resp.body, r'$');
    expect(bad, isEmpty, reason: bad.join('\n'));
  });

  test('/help?format=text → markdown, работает', () async {
    final resp = await helpHandler(req('text'), ctx());
    expect(resp, isA<BytesResponse>());
  });

  test('/help json и text содержат реальные пути', () async {
    final jsonResp = await helpHandler(req('json'), ctx()) as JsonResponse;
    final body = jsonResp.body as Map;
    final endpoints = (body['endpoints'] as List).cast<Map>();
    final paths = [for (final e in endpoints) e['path'] as String];

    expect(paths, contains('/core_reject/reset'));
    expect(paths, contains('/action/start-vpn-headless'));
    expect(paths, contains('/action/check-config'));
    expect(paths, contains('/subs/{id}'));

    final reset = endpoints.singleWhere(
      (e) => e['method'] == 'POST' && e['path'] == '/core_reject/reset',
    );
    expect(reset['description'], contains('409'));

    final check = endpoints.singleWhere(
      (e) => e['method'] == 'POST' && e['path'] == '/action/check-config',
    );
    expect(check['body'], contains('JSON'));

    final sub = endpoints.singleWhere(
      (e) => e['method'] == 'GET' && e['path'] == '/subs/{id}',
    );
    expect(sub['description'], contains('origin_kind'));
    expect(sub['description'], contains('source_kind'));
    expect(sub['description'], contains('every node'));

    final textResp = await helpHandler(req('text'), ctx()) as BytesResponse;
    final text = utf8.decode(textResp.bytes);
    expect(text, contains('POST /core_reject/reset'));
    expect(text, contains('origin_kind'));
    expect(text, contains('source_kind'));

    final router = buildDebugRouter();
    final missing = <String>[];
    for (final raw in paths) {
      final concrete = raw.replaceAll(RegExp(r'\{[^}]+\}'), 'x');
      if (router.resolve(concrete) == null) missing.add(raw);
    }
    expect(missing, isEmpty, reason: 'help json paths not mounted: $missing');
  });

  // Ревью после v2.25.1, L1: `/pool` был в тексте `/help`, но не в JSON —
  // инструмент, строящий список путей по JSON, считал роут несуществующим.
  test('каждый смонтированный префикс роутера есть в /help?format=json',
      () async {
    final jsonResp = await helpHandler(req('json'), ctx()) as JsonResponse;
    final endpoints =
        ((jsonResp.body as Map)['endpoints'] as List).cast<Map>();
    final paths = [for (final e in endpoints) e['path'] as String];

    final undocumented = [
      for (final prefix in buildDebugRouter().prefixes)
        if (!paths.any((p) => p == prefix || p.startsWith('$prefix/')))
          prefix,
    ];
    expect(undocumented, isEmpty,
        reason: 'mounted but absent from /help json: $undocumented');
  });
}
