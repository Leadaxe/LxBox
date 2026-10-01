import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/builder/post_steps.dart';

import '../contract_paths.dart';

/// §393 — глобальный `tls_fragment` и masque-outbound'ы.
///
/// До миграции схемы у masque не было блока `tls{}`, и post-step проходил мимо.
/// Новая схема даёт `tls.fragment`, но фрагментация осмысленна только на
/// `vhttp: h2` (TCP+TLS); при h3 ядро её игнорирует с предупреждением.
Map<String, dynamic> _masque({String? vhttp, Map<String, dynamic>? tls}) => {
      'tag': 'masque-out',
      'type': 'masque',
      'vhttp': ?vhttp,
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
  // Контракт 1.1.64 — годность поля судит реестр по телу (fieldAllowedOn).
  setUpAll(loadTestRegistry);

  test('h2 получает fragment во вложенном tls{}', () {
    final ob = _masque(vhttp: 'h2');
    applyTlsFragment(_config([ob]), _on);
    final tls = ob['tls'] as Map<String, dynamic>;
    expect(tls['fragment'], isTrue);
    expect(tls['record_fragment'], isTrue);
    expect(tls['fragment_fallback_delay'], '700ms');
  });

  test('h2 с уже заданным SNI не теряет server_name', () {
    // Map строим явно изменяемым: post-step дописывает в него на месте.
    final ob = _masque(
      vhttp: 'h2',
      tls: <String, dynamic>{'server_name': 'www.cloudflare.com'},
    );
    applyTlsFragment(_config([ob]), _on);
    final tls = ob['tls'] as Map<String, dynamic>;
    expect(tls['server_name'], 'www.cloudflare.com');
    expect(tls['fragment'], isTrue);
  });

  test('h3 пропускается молча — блок tls не создаётся', () {
    final ob = _masque(vhttp: 'h3');
    applyTlsFragment(_config([ob]), _on);
    expect(ob.containsKey('tls'), isFalse);
  });

  test('legacy `network: h2` (конфиг до миграции) тоже фрагментируется', () {
    final ob = <String, dynamic>{
      'tag': 'masque-out',
      'type': 'masque',
      'network': 'h2',
    };
    applyTlsFragment(_config([ob]), _on);
    expect((ob['tls'] as Map)['fragment'], isTrue);
  });

  test('vhttp не задан → у ядра auto (есть h2-плечо) → фрагментируется', () {
    // Контракт 1.1.64: связь masque_tls_fragment_h3 действует только при
    // vhttp = h3; пустой vhttp у ядра — auto.
    final ob = _masque();
    applyTlsFragment(_config([ob]), _on);
    expect((ob['tls'] as Map)['fragment'], isTrue);
  });

  test('naive — поле запрещено схемой (forbidden_for) → пропуск', () {
    final ob = <String, dynamic>{
      'tag': 'n',
      'type': 'naive',
      'tls': <String, dynamic>{'enabled': true},
    };
    applyTlsFragment(_config([ob]), _on);
    expect((ob['tls'] as Map).containsKey('fragment'), isFalse);
  });

  test('masque под detour не трогаем (inner hop уже в туннеле)', () {
    final ob = _masque(vhttp: 'h2')..['detour'] = 'parent';
    applyTlsFragment(_config([ob]), _on);
    expect(ob.containsKey('tls'), isFalse);
  });

  test('тумблеры выключены → h2 тоже не трогаем', () {
    final ob = _masque(vhttp: 'h2');
    applyTlsFragment(_config([ob]), const {});
    expect(ob.containsKey('tls'), isFalse);
  });
}
