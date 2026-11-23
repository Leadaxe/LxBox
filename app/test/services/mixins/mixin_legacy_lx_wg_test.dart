// §758 — ядро v1.14.4-lx.36: ключи сна WireGuard переехали в `lx.wg.idle`,
// старые имена — ошибка загрузки. Миксин пользователя со старым именем
// переписывается при чтении (хранилище, бэкап).
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/mixin.dart';
import 'package:lxbox/services/mixins/mixin_legacy_lx_wg.dart';

void main() {
  ({String target, Object? value}) m(String t, String op, Object? v) =>
      migrateLegacyLxWgMixin(t, op, v);

  test('цель-ключ: каждое из шести старых имён → lx.wg.idle.<новое>', () {
    const expected = {
      'idle_suspend': 'suspend',
      'idle_suspend_reachable': 'suspend_reachable',
      'idle_teardown': 'teardown',
      'lazy_build': 'lazy_build',
      'build_max': 'build_max',
      'build_overflow': 'build_overflow',
    };
    for (final e in expected.entries) {
      expect(m('lx.wg.${e.key}', 'set', '1m').target, 'lx.wg.idle.${e.value}');
    }
  });

  test('новые пути и чужие ключи не трогаются (идемпотентно)', () {
    for (final t in [
      'lx.wg.idle.suspend',
      'lx.wg.idle',
      'lx.wg.buffers.read_datagram_count',
      'lx.wg.connected_socket',
      'lx.mtu_align',
      'outbounds[tag=a]',
    ]) {
      final r = m(t, 'set', 1);
      expect(r.target, t);
      expect(r.value, 1);
    }
    final already = {
      'idle': {'suspend': '1m'},
      'connected_socket': true,
    };
    expect(identical(m('lx.wg', 'merge', already).value, already), isTrue);
  });

  test('объект у lx.wg / lx / корня: старые ключи уходят в idle, новое сильнее', () {
    expect(
        m('lx.wg', 'merge', {
          'idle_suspend': '1m',
          'lazy_build': false,
          'connected_socket': true,
        }).value,
        {
          'connected_socket': true,
          'idle': {'suspend': '1m', 'lazy_build': false},
        });
    expect(
        m('lx', 'merge', {
          'mtu_align': 'fill',
          'wg': {
            'build_max': 3,
            'idle': {'build_max': 8},
          },
        }).value,
        {
          'mtu_align': 'fill',
          'wg': {
            'idle': {'build_max': 8},
          },
        });
    expect(
        m('', 'merge', {
          'lx': {
            'wg': {'idle_suspend': '2m'},
          },
        }).value,
        {
          'lx': {
            'wg': {
              'idle': {'suspend': '2m'},
            },
          },
        });
  });

  test('remove списком старых ключей → lx.wg.idle, смешанный список не трогается', () {
    final r = m('lx.wg', 'remove', ['idle_suspend', 'build_max']);
    expect(r.target, 'lx.wg.idle');
    expect(r.value, ['suspend', 'build_max']);
    final mixed = m('lx.wg', 'remove', ['idle_suspend', 'connected_socket']);
    expect(mixed.target, 'lx.wg');
    expect(mixed.value, ['idle_suspend', 'connected_socket']);
  });

  test('Mixin.fromJson читает старый миксин на новой раскладке', () {
    final mx = Mixin.fromJson({
      'id': 'x',
      'target': 'lx.wg.idle_suspend_reachable',
      'op': 'set',
      'value': '15m',
    });
    expect(mx.target, 'lx.wg.idle.suspend_reachable');
    expect(mx.value, '15m');
    expect(Mixin.fromJson(mx.toJson()).toJson(), mx.toJson());
  });
}
