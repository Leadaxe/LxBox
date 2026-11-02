// §709 итер. 3 (контракт 1.1.151) — корневой блок `lx` ядра пишет `config`
// шаблона: переменные секций Network / WireGuard / QUIC, ключ — только при
// значении, отличном от дефолта ядра; зависимости строк — `#enable`
// объявлений.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/if_engine.dart';

void main() {
  final raw = jsonDecode(File('assets/wizard_template.json').readAsStringSync())
      as Map<String, dynamic>;
  final template = WizardTemplate.fromJson(raw);
  final byName = {for (final v in template.vars) v.name: v};
  final defaults = {for (final v in template.vars) v.name: v.defaultValue};

  dynamic lx(Map<String, String> overrides) {
    final vars = {...defaults, ...overrides};
    final fragment = jsonDecode(jsonEncode((raw['config'] as Map)['lx']));
    return walk(fragment, makeResolver(vars, byName));
  }

  test('дефолты шаблона: сон 30s/5m, lazy, build_max 5, decoy; clamp и masque off не пишутся', () {
    expect(lx({}), {
      'wg': {
        'idle_suspend': '30s',
        'idle_suspend_reachable': '5m',
        'lazy_build': true,
        'build_max': 5,
      },
      'quic_sniff_decoy': true,
    });
  });

  test('сон off — блока wg нет, reachable и lazy не пишутся', () {
    final r = lx({'wg_idle_suspend': 'off', 'quic_sniff_decoy': 'false'});
    expect(r, isEmpty);
  });

  test('reachable off и lazy выключен', () {
    final r = lx({
      'wg_idle_suspend_reachable': 'off',
      'wg_lazy_build': 'false',
    }) as Map;
    expect(r['wg'], {'idle_suspend': '30s'});
  });

  test('build_max — целое, 0 пишется как 0', () {
    final r = lx({'wg_build_max': '0'}) as Map;
    expect((r['wg'] as Map)['build_max'], 0);
  });

  test('mtu_align fill/off строкой, masque_idle_timeout во вложенный masque', () {
    final r = lx({'mtu_align': 'fill', 'masque_idle_timeout': '5m'}) as Map;
    expect(r['mtu_align'], 'fill');
    expect(r['masque'], {'idle_timeout': '5m'});
    expect((lx({'mtu_align': 'off'}) as Map)['mtu_align'], 'off');
  });

  test('#enable объявлений: reachable/lazy от сна, build_max ещё и от lazy', () {
    bool on(String name, Map<String, String> vars) => evalCond(
        byName[name]!.enable, makeResolver({...defaults, ...vars}, byName));
    expect(on('wg_idle_suspend_reachable', {}), isTrue);
    expect(on('wg_idle_suspend_reachable', {'wg_idle_suspend': 'off'}), isFalse);
    expect(on('wg_lazy_build', {'wg_idle_suspend': 'off'}), isFalse);
    expect(on('wg_build_max', {'wg_lazy_build': 'false'}), isFalse);
    expect(on('wg_build_max', {}), isTrue);
  });
}
