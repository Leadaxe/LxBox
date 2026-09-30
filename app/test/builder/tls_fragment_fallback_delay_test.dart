import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/builder/post_steps.dart';

import '../contract_paths.dart';

/// §606 — `tls_fragment_fallback_delay`, который ядро не разберёт как
/// duration, в конфиг не уходит: подставляется умолчание `500ms`.
Map<String, dynamic> _vless() => <String, dynamic>{
      'tag': 'v',
      'type': 'vless',
      'server': '10.0.0.1',
      'server_port': 443,
      'uuid': '11111111-2222-3333-4444-555555555555',
      'tls': <String, dynamic>{'enabled': true, 'server_name': 'a.example'},
    };

String? _delayFor(String? delay) {
  final ob = _vless();
  applyTlsFragment({
    'outbounds': [ob],
  }, {
    'tls_fragment': 'true',
    'tls_fragment_fallback_delay': ?delay,
  });
  final tls = ob['tls'] as Map<String, dynamic>;
  expect(tls['fragment'], isTrue);
  return tls['fragment_fallback_delay'] as String?;
}

void main() {
  setUpAll(loadTestRegistry);

  test('валидные длительности — как есть', () {
    expect(_delayFor('1s'), '1s');
    expect(_delayFor('250ms'), '250ms');
    expect(_delayFor('1.5s'), '1.5s');
  });

  test('невалидные — умолчание 500ms', () {
    for (final bad in ['500', 'fast', '1 s', ' 500ms', '', '10x']) {
      expect(_delayFor(bad), '500ms', reason: bad);
    }
  });

  test('переменной нет — умолчание 500ms', () {
    expect(_delayFor(null), '500ms');
  });
}
