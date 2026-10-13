import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/tls_policy.dart';
import 'package:lxbox/services/builder/post_steps.dart';

import '../contract_paths.dart';

/// Контракт 1.1.118 (§591 п.7) — `tls.fragment` / `record_fragment` /
/// `fragment_fallback_delay` запрещены у hysteria, hysteria2 и tuic
/// (`forbidden_for`, код `tls_not_applicable_quic`): QUIC не режется.
/// Код этого не знает — `applyTlsFragment` спрашивает реестр
/// (`fieldAllowedOn`), и флаги не дописываются ни глобальным тумблером, ни
/// уровнем узла (§636).
Map<String, dynamic> _ob(String type, String tag) => {
      'tag': tag,
      'type': type,
      'tls': <String, dynamic>{'enabled': true, 'server_name': 'h.example'},
    };

const _on = {
  'tls_fragment': 'true',
  'tls_record_fragment': 'true',
  'tls_fragment_fallback_delay': '700ms',
};

void main() {
  setUpAll(loadTestRegistry);

  for (final type in const ['hysteria2', 'tuic', 'hysteria']) {
    test('$type: глобальный тумблер и флаг узла флагов не дописывают', () {
      final global = _ob(type, 'g');
      final perNode = _ob(type, 'n');
      applyTlsFragment(
        {
          'outbounds': [global, perNode],
        },
        _on,
        byTag: const {
          'n': TlsLayers(
            node: TlsPolicy(fragment: true, recordFragment: true),
          ),
        },
      );
      for (final ob in [global, perNode]) {
        final tls = ob['tls'] as Map<String, dynamic>;
        expect(tls.containsKey('fragment'), isFalse, reason: ob['tag']);
        expect(tls.containsKey('record_fragment'), isFalse, reason: ob['tag']);
        expect(tls.containsKey('fragment_fallback_delay'), isFalse,
            reason: ob['tag']);
      }
    });
  }

  test('TCP-узел рядом фрагментируется как прежде', () {
    final ob = _ob('trojan', 't');
    applyTlsFragment({
      'outbounds': [ob]
    }, _on);
    expect((ob['tls'] as Map)['fragment'], isTrue);
  });
}
