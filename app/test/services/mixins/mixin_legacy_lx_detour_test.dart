// §761 — ядро v1.14.4-lx.37-rc.2: `lx.mtu_align` переехал в
// `lx.detour.mtu_align`, `except` — в `lx.detour.except_outbounds`. Миксин
// пользователя со старым путём переписывается при чтении.
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/mixin.dart';
import 'package:lxbox/services/mixins/mixin_legacy_lx_detour.dart';

void main() {
  ({String target, Object? value}) m(String t, String op, Object? v) =>
      migrateLegacyLxDetourMixin(t, op, v);

  test('цель lx.mtu_align со строкой → lx.detour.mtu_align', () {
    final r = m('lx.mtu_align', 'set', 'fill');
    expect(r.target, 'lx.detour.mtu_align');
    expect(r.value, 'fill');
  });

  test('цель lx.mtu_align с объектом → lx.detour с новыми именами', () {
    final r = m('lx.mtu_align', 'set', {
      'mode': 'off',
      'except': ['wg-1'],
    });
    expect(r.target, 'lx.detour');
    expect(r.value, {
      'mtu_align': 'off',
      'except_outbounds': ['wg-1'],
    });
  });

  test('цели mode / except', () {
    expect(m('lx.mtu_align.mode', 'set', 'off').target, 'lx.detour.mtu_align');
    final e = m('lx.mtu_align.except', 'set', ['a']);
    expect(e.target, 'lx.detour.except_outbounds');
    expect(e.value, ['a']);
  });

  test('объект у lx и корня: mtu_align уходит в detour, новое сильнее', () {
    expect(
        m('lx', 'merge', {
          'mtu_align': 'fill',
          'wg': {'connected_socket': true},
        }).value,
        {
          'wg': {'connected_socket': true},
          'detour': {'mtu_align': 'fill'},
        });
    expect(
        m('lx', 'merge', {
          'mtu_align': {'mode': 'off', 'except': ['x']},
          'detour': {'mtu_align': 'clamp'},
        }).value,
        {
          'detour': {'mtu_align': 'clamp', 'except_outbounds': ['x']},
        });
    expect(
        m('', 'merge', {
          'lx': {'mtu_align': 'off'},
          'log': {'level': 'debug'},
        }).value,
        {
          'lx': {
            'detour': {'mtu_align': 'off'},
          },
          'log': {'level': 'debug'},
        });
  });

  test('новые пути и чужие ключи не трогаются (идемпотентно)', () {
    for (final t in [
      'lx.detour.mtu_align',
      'lx.detour',
      'lx.wg.idle.suspend',
      'outbounds[tag=a]',
    ]) {
      final r = m(t, 'set', 1);
      expect(r.target, t);
      expect(r.value, 1);
    }
    final already = {
      'detour': {'mtu_align': 'off'},
    };
    expect(identical(m('lx', 'merge', already).value, already), isTrue);
    final root = {
      'lx': {'detour': false},
    };
    expect(identical(m('', 'merge', root).value, root), isTrue);
    // `detour: false` у lx — не объект, старый ключ не переносится.
    final boolDetour = {'mtu_align': 'off', 'detour': false};
    expect(identical(m('lx', 'merge', boolDetour).value, boolDetour), isTrue);
  });

  test('Mixin.fromJson читает старый миксин на новой раскладке', () {
    final mx = Mixin.fromJson({
      'id': 'x',
      'target': 'lx.mtu_align',
      'op': 'set',
      'value': 'off',
    });
    expect(mx.target, 'lx.detour.mtu_align');
    expect(mx.value, 'off');
    expect(Mixin.fromJson(mx.toJson()).toJson(), mx.toJson());
  });
}
