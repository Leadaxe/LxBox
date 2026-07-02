import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/help.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/debug/transport/response.dart';

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
}
