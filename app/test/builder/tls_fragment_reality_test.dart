import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/tls_policy.dart';
import 'package:lxbox/services/builder/post_steps.dart';

import '../contract_paths.dart';

/// §665 — REALITY наследует фрагментацию TLS как любой узел (правило §627
/// снято): глобальный `true` доходит, `false` на узле или источнике снимает.
Map<String, dynamic> _vless({bool reality = false}) => <String, dynamic>{
      'tag': 'v',
      'type': 'vless',
      'server': '10.0.0.1',
      'server_port': 443,
      'uuid': '11111111-2222-3333-4444-555555555555',
      'flow': 'xtls-rprx-vision',
      'tls': <String, dynamic>{
        'enabled': true,
        'server_name': 'a.example',
        if (reality)
          'reality': <String, dynamic>{
            'enabled': true,
            'public_key': '2NtvNsBpKxbXdM10sXCDOedKkdZ3gwAs3WUnwqbv5Hs',
            'short_id': '01bd983cc160a26a',
          },
      },
    };

const _vars = {'tls_fragment': 'true', 'tls_record_fragment': 'true'};

void main() {
  setUpAll(loadTestRegistry);

  test('REALITY-узел получает глобальную фрагментацию', () {
    final ob = _vless(reality: true);
    applyTlsFragment({
      'outbounds': [ob],
    }, _vars);
    final tls = ob['tls'] as Map<String, dynamic>;
    expect(tls['fragment'], isTrue);
    expect(tls['record_fragment'], isTrue);
    expect(tls['fragment_fallback_delay'], '500ms');
  });

  test('REALITY: false на узле снимает глобальную фрагментацию', () {
    final ob = _vless(reality: true);
    applyTlsFragment({
      'outbounds': [ob],
    }, _vars, byTag: const {
      'v': TlsLayers(
          node: TlsPolicy(fragment: false, recordFragment: false)),
    });
    final tls = ob['tls'] as Map<String, dynamic>;
    expect(tls.containsKey('fragment'), isFalse);
    expect(tls.containsKey('record_fragment'), isFalse);
    expect(tls.containsKey('fragment_fallback_delay'), isFalse);
  });

  test('REALITY: false на источнике снимает глобальную фрагментацию', () {
    final ob = _vless(reality: true);
    applyTlsFragment({
      'outbounds': [ob],
    }, _vars, byTag: const {
      'v': TlsLayers(
          source: TlsPolicy(fragment: false, recordFragment: false)),
    });
    final tls = ob['tls'] as Map<String, dynamic>;
    expect(tls.containsKey('fragment'), isFalse);
    expect(tls.containsKey('record_fragment'), isFalse);
    expect(tls.containsKey('fragment_fallback_delay'), isFalse);
  });

  test('обычный TLS-узел фрагментацию получает', () {
    final ob = _vless();
    applyTlsFragment({
      'outbounds': [ob],
    }, _vars);
    final tls = ob['tls'] as Map<String, dynamic>;
    expect(tls['fragment'], isTrue);
    expect(tls['record_fragment'], isTrue);
    expect(tls['fragment_fallback_delay'], '500ms');
  });
}
