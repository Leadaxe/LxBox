import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/transport/request.dart';

void main() {
  group('DebugRequest.forTest', () {
    test('query-params normalized', () {
      final req = DebugRequest.forTest(
        path: '/state',
        query: {'tag': 'vpn-1', 'reveal': 'true'},
      );
      expect(req.q('tag'), 'vpn-1');
      expect(req.qBool('reveal'), isTrue);
      expect(req.qBool('absent'), isFalse);
    });

    test('requiredQuery бросает BadRequest если отсутствует', () {
      final req = DebugRequest.forTest(query: {'other': 'x'});
      expect(() => req.requiredQuery('tag'), throwsA(isA<BadRequest>()));
    });

    test('requiredQuery пустая строка → BadRequest', () {
      final req = DebugRequest.forTest(query: {'tag': ''});
      expect(() => req.requiredQuery('tag'), throwsA(isA<BadRequest>()));
    });

    test('qInt валидный парсится', () {
      final req = DebugRequest.forTest(query: {'limit': '42'});
      expect(req.qInt('limit'), 42);
    });

    test('qInt невалидный → BadRequest', () {
      final req = DebugRequest.forTest(query: {'limit': 'abc'});
      expect(() => req.qInt('limit'), throwsA(isA<BadRequest>()));
    });

    test('qBool варианты truthy', () {
      expect(DebugRequest.forTest(query: {'x': 'true'}).qBool('x'), isTrue);
      expect(DebugRequest.forTest(query: {'x': 'TRUE'}).qBool('x'), isTrue);
      expect(DebugRequest.forTest(query: {'x': '1'}).qBool('x'), isTrue);
      expect(DebugRequest.forTest(query: {'x': 'yes'}).qBool('x'), isTrue);
      expect(DebugRequest.forTest(query: {'x': 'no'}).qBool('x'), isFalse);
      expect(DebugRequest.forTest(query: {'x': ''}).qBool('x'), isFalse);
    });

    test('header lowercased lookup', () {
      final req = DebugRequest.forTest(
        headers: {'Authorization': 'Bearer abc', 'X-Custom': 'v'},
      );
      expect(req.header('authorization'), 'Bearer abc');
      expect(req.header('AUTHORIZATION'), 'Bearer abc');
      expect(req.header('x-custom'), 'v');
      expect(req.header('missing'), isNull);
    });

    test('jsonBodyAsMap пустое тело → пустая мапа', () {
      final req = DebugRequest.forTest();
      expect(req.jsonBodyAsMap(), isEmpty);
    });

    test('jsonBodyAsMap парсит валидный JSON объект', () {
      final req = DebugRequest.forTest(
        body: utf8.encode('{"name": "vpn-1"}'),
      );
      expect(req.jsonBodyAsMap(), {'name': 'vpn-1'});
    });

    test('jsonBodyAsMap — невалидный JSON → BadRequest', () {
      final req = DebugRequest.forTest(body: utf8.encode('not-json'));
      expect(() => req.jsonBodyAsMap(), throwsA(isA<BadRequest>()));
    });

    test('jsonBodyAsMap — массив (не объект) → BadRequest', () {
      final req = DebugRequest.forTest(body: utf8.encode('[1, 2]'));
      expect(() => req.jsonBodyAsMap(), throwsA(isA<BadRequest>()));
    });
  });
}
