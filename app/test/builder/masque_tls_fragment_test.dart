import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/builder/post_steps.dart';

/// §393 — глобальный `tls_fragment` и masque-outbound'ы.
///
/// До миграции схемы у masque не было блока `tls{}`, и post-step проходил мимо.
/// Новая схема даёт `tls.fragment`, но фрагментация осмысленна только на
/// `transport: h2` (TCP+TLS); при h3 ядро её игнорирует с предупреждением.
Map<String, dynamic> _masque({String? transport, Map<String, dynamic>? tls}) => {
      'tag': 'masque-out',
      'type': 'masque',
      'transport': ?transport,
      'tls': ?tls,
    };

Map<String, dynamic> _config(List<Map<String, dynamic>> outbounds) => {
      'outbounds': outbounds,
    };

const _on = {
  'tls_fragment': 'true',
  'tls_record_fragment': 'true',
  'tls_fragment_fallback_delay': '700ms',
};

void main() {
  test('h2 получает fragment во вложенном tls{}', () {
    final ob = _masque(transport: 'h2');
    applyTlsFragment(_config([ob]), _on);
    final tls = ob['tls'] as Map<String, dynamic>;
    expect(tls['fragment'], isTrue);
    expect(tls['record_fragment'], isTrue);
    expect(tls['fragment_fallback_delay'], '700ms');
  });

  test('h2 с уже заданным SNI не теряет server_name', () {
    final ob = _masque(transport: 'h2', tls: {'server_name': 'www.cloudflare.com'});
    applyTlsFragment(_config([ob]), _on);
    final tls = ob['tls'] as Map<String, dynamic>;
    expect(tls['server_name'], 'www.cloudflare.com');
    expect(tls['fragment'], isTrue);
  });

  test('h3 пропускается молча — блок tls не создаётся', () {
    final ob = _masque(transport: 'h3');
    applyTlsFragment(_config([ob]), _on);
    expect(ob.containsKey('tls'), isFalse);
  });

  test('transport не задан → дефолт ядра h3 → пропуск', () {
    final ob = _masque();
    applyTlsFragment(_config([ob]), _on);
    expect(ob.containsKey('tls'), isFalse);
  });

  test('masque под detour не трогаем (inner hop уже в туннеле)', () {
    final ob = _masque(transport: 'h2')..['detour'] = 'parent';
    applyTlsFragment(_config([ob]), _on);
    expect(ob.containsKey('tls'), isFalse);
  });

  test('тумблеры выключены → h2 тоже не трогаем', () {
    final ob = _masque(transport: 'h2');
    applyTlsFragment(_config([ob]), const {});
    expect(ob.containsKey('tls'), isFalse);
  });
}
