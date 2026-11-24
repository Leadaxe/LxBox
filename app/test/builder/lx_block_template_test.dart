// §709 итер. 3 (контракт 1.1.151) — корневой блок `lx` ядра пишет `config`
// шаблона: переменные секций Network / WireGuard / QUIC, ключ — только при
// значении, отличном от дефолта ядра; зависимости строк — `#enable`
// объявлений.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/if_engine.dart';
import 'package:lxbox/services/builder/sniff_guard.dart';

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

  test('дефолты шаблона: сон 30s/5m, lazy, build_max 5 в lx.wg.idle, read_datagram_count 8, sniff_guard; send_by_mtu/connected_socket, clamp и masque off не пишутся', () {
    expect(lx({}), {
      'sniff_guard': {
        'nodes': {'sni_mismatch': true},
        'tls': {'method': 'record_fragment'},
        'quic': {
          'method': 'decoy_first_byte',
          'detour_type': {'socks': 'never'},
        },
      },
      'wg': {
        'idle': {
          'suspend': '30s',
          'suspend_reachable': '5m',
          'lazy_build': true,
          'build_max': 5,
        },
        'buffers': {'read_datagram_count': 8},
      },
    });
  });

  const guardDefault = {
    'nodes': {'sni_mismatch': true},
    'tls': {'method': 'record_fragment'},
    'quic': {
      'method': 'decoy_first_byte',
      'detour_type': {'socks': 'never'},
    },
  };

  test('729 — sniff_guard: методы, фильтр и persist из переменных; off снимает секцию, оба off — блок', () {
    final r = lx({'sniff_guard_tls': 'delay', 'sniff_guard_quic': 'off'}) as Map;
    expect(r['sniff_guard'], {
      'nodes': {'sni_mismatch': true},
      'tls': {'method': 'delay'},
    });
    expect(
        (lx({
          'sniff_guard_tls': 'off',
          'sniff_guard_quic': 'delay',
          'sniff_guard_sni_mismatch': 'false',
          'sniff_guard_persist': 'true',
        }) as Map)['sniff_guard'],
        {
          // Явный false: без ключа ядро (с lx.34) фильтр включает.
          'nodes': {'sni_mismatch': false},
          'quic': {
            'method': 'delay',
            'detour_type': {'socks': 'never'},
            'persist': true,
          },
        });
    expect((lx({'sniff_guard_persist': 'true'}) as Map)['sniff_guard'], {
      'nodes': {'sni_mismatch': true},
      'tls': {'method': 'record_fragment', 'persist': true},
      'quic': {
        'method': 'decoy_first_byte',
        'detour_type': {'socks': 'never'},
        'persist': true,
      },
    });
    expect(
        (lx({'sniff_guard_tls': 'off', 'sniff_guard_quic': 'off'}) as Map)
            .containsKey('sniff_guard'),
        isFalse);
    // Сохранённые значения снятых переменных ядру не уходят.
    final old = lx({
      'quic_sniff_decoy': 'all',
      'quic_sniff_decoy_send': 'always',
      'quic_sniff_decoy_outbounds': 'masque',
      'quic_sniff_decoy_detours': 'vless',
    }) as Map;
    expect(old.containsKey('quic_sniff_decoy'), isFalse);
    expect(old['sniff_guard'], guardDefault);
    expect(raw.toString().contains('quic_sniff_decoy'), isFalse);
  });

  test('729 — гейт: ниже lx.34 блок снимается, без версии остаётся', () {
    Map<String, dynamic> gated(Map<String, String> vars, String core) {
      final config = <String, dynamic>{'lx': (lx(vars) as Map).cast<String, dynamic>()};
      applySniffGuardGate(config, coreVersion: core);
      return (config['lx'] as Map).cast<String, dynamic>();
    }

    expect(gated({}, '1.14.4-lx.34')['sniff_guard'], guardDefault);
    expect(gated({}, '1.14.4-lx.35')['sniff_guard'], guardDefault);
    expect(gated({}, '')['sniff_guard'], guardDefault);
    expect(gated({}, '1.14.4-lx.33').containsKey('sniff_guard'), isFalse);
    expect(gated({}, '1.14.4-lx.34-rc.1').containsKey('sniff_guard'), isFalse);
  });

  test('729 — probe: тот же блок без persist, по умолчаниям шаблона', () {
    Map<String, dynamic> strip(Map m) => {
          for (final e in m.entries)
            '${e.key}': {...(e.value as Map)}..remove('persist'),
        };
    // Умолчания probe при пустых vars = умолчания шаблона.
    expect(defaults['sniff_guard_sni_mismatch'], 'true');
    expect(defaults['sniff_guard_persist'], 'false');
    for (final vars in <Map<String, String>>[
      {},
      {'sniff_guard_persist': 'true'},
      {'sniff_guard_sni_mismatch': 'false'},
      {'sniff_guard_tls': 'fragment', 'sniff_guard_quic': 'delay'},
      {'sniff_guard_tls': 'off'},
      {'sniff_guard_quic': 'off'},
    ]) {
      expect(probeSniffGuard(vars, coreVersion: '1.14.4-lx.34'),
          strip((lx(vars) as Map)['sniff_guard'] as Map),
          reason: '$vars');
    }
    expect(
        probeSniffGuard({'sniff_guard_tls': 'off', 'sniff_guard_quic': 'off'},
            coreVersion: '1.14.4-lx.34'),
        isNull);
    expect(probeSniffGuard({}, coreVersion: '1.14.4-lx.33'), isNull);
  });

  test('720 отменена — awg_masquerade ядру не уходит ни при каком значении', () {
    for (final v in ['all', 'direct']) {
      expect((lx({'awg_masquerade': v}) as Map).containsKey('awg_masquerade'), isFalse, reason: v);
    }
  });

  test('сон off и буферы как у ядра (128) — блока wg нет, reachable и lazy не пишутся', () {
    final r = lx({
      'wg_idle_suspend': 'off',
      'wg_read_datagram_count': '128',
      'sniff_guard_tls': 'off',
      'sniff_guard_quic': 'off',
    });
    expect(r, isEmpty);
  });

  test('reachable off и lazy выключен', () {
    final r = lx({
      'wg_idle_suspend_reachable': 'off',
      'wg_lazy_build': 'false',
    }) as Map;
    expect(r['wg'], {
      'idle': {'suspend': '30s'},
      'buffers': {'read_datagram_count': 8},
    });
  });

  test('build_max — целое, 0 пишется как 0', () {
    final r = lx({'wg_build_max': '0'}) as Map;
    expect(((r['wg'] as Map)['idle'] as Map)['build_max'], 0);
  });

  test('758 — ядро lx.36: прежние плоские ключи сна не пишутся (ошибка загрузки)', () {
    for (final vars in <Map<String, String>>[
      {},
      {'wg_read_datagram_count': '8', 'wg_send_by_mtu': 'false', 'wg_connected_socket': 'true'},
    ]) {
      final wg = (lx(vars) as Map)['wg'] as Map;
      for (final old in [
        'idle_suspend',
        'idle_suspend_reachable',
        'idle_teardown',
        'lazy_build',
        'build_max',
        'build_overflow',
      ]) {
        expect(wg.containsKey(old), isFalse, reason: '$old в $vars');
      }
    }
  });

  test('758 — buffers и connected_socket: пишутся только при отличии от дефолта ядра', () {
    final r = lx({
      'wg_read_datagram_count': '8',
      'wg_send_by_mtu': 'false',
      'wg_connected_socket': 'true',
    }) as Map;
    expect((r['wg'] as Map)['buffers'], {'read_datagram_count': 8, 'send_by_mtu': false});
    expect((r['wg'] as Map)['connected_socket'], true);
    expect(((lx({'wg_read_datagram_count': '1'}) as Map)['wg'] as Map)['buffers'],
        {'read_datagram_count': 1});
    expect(
        ((lx({'wg_read_datagram_count': '128', 'wg_send_by_mtu': 'false'}) as Map)['wg']
            as Map)['buffers'],
        {'send_by_mtu': false});
    // Умолчание LxBox — 8 (решение владельца 24.11): ключ пишется всегда,
    // кроме выбранного 128 — умолчания самого ядра.
    final def = (lx({}) as Map)['wg'] as Map;
    expect(def['buffers'], {'read_datagram_count': 8});
    expect(def.containsKey('connected_socket'), isFalse);
    final core = (lx({'wg_read_datagram_count': '128'}) as Map)['wg'] as Map;
    expect(core.containsKey('buffers'), isFalse);
  });

  test('758 — сон off: buffers и connected_socket живут без idle', () {
    final off = {
      'wg_idle_suspend': 'off',
      'wg_read_datagram_count': '128',
      'sniff_guard_tls': 'off',
      'sniff_guard_quic': 'off',
    };
    expect(lx({...off, 'wg_connected_socket': 'true'}), {
      'wg': {'connected_socket': true},
    });
    expect(lx({...off, 'wg_read_datagram_count': '2'}), {
      'wg': {
        'buffers': {'read_datagram_count': 2},
      },
    });
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
    for (final name in ['sniff_guard_sni_mismatch', 'sniff_guard_persist']) {
      expect(on(name, {}), isTrue, reason: name);
      expect(on(name, {'sniff_guard_tls': 'off'}), isTrue, reason: name);
      expect(on(name, {'sniff_guard_tls': 'off', 'sniff_guard_quic': 'off'}),
          isFalse, reason: name);
    }
  });
}
