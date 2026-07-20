import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/if_engine.dart';
import 'package:lxbox/services/settings_storage.dart' show VpnModeConfig;

/// §119/§120 — VPN-mode теперь декларативен: tun-in/mixed-in/route-rules
/// собираются `#if`-walker'ом в substitution-фазе по `@vpn_mode`/`@proxy_*`.
/// `applyVpnMode` удалён. Эти тесты гоняют тот же шаблонный фрагмент
/// (inbounds + route.rules) через [walk] с разными `VpnModeConfig` и проверяют
/// семантику (вместо вызова удалённого императивного шага).

/// Фрагмент шаблона §120: inbounds + route.rules с `#if`. Соответствует
/// `wizard_template.json` (tun-in / mixed-in / resolve / sniff / hijack-dns).
Map<String, dynamic> _templateConfig() => {
      'inbounds': <dynamic>[
        {
          '#if': {
            'and': [
              {
                '@vpn_mode': {
                  '#in': ['vpn', 'vpn_proxy'],
                },
              },
            ],
            'value': {
              'type': 'tun',
              'tag': 'tun-in',
              'address': [
                '@tun_address',
                {'#if': {'and': ['@ipv6_enabled'], 'value': '@tun_address6'}},
              ],
              // §232 — route_address за галкой route_address_enable (вложенный
              // map-spread #if внутри value внешнего vpn_mode-#if).
              '#if': {
                'and': ['@route_address_enable'],
                'value': {
                  'route_address': ['0.0.0.0/1', '128.0.0.0/1', '::/1', '8000::/1'],
                },
              },
              'mtu': '@tun_mtu',
              'auto_route': '@tun_auto_route',
            },
          },
        },
        {
          '#if': {
            'and': [
              {
                '@vpn_mode': {
                  '#in': ['proxy', 'vpn_proxy'],
                },
              },
            ],
            'value': {
              'type': '@proxy_type',
              'tag': 'mixed-in',
              'listen': '@proxy_listen',
              'listen_port': '@proxy_port',
              '#if': {
                'and': ['@proxy_auth'],
                'value': {
                  'users': [
                    {'username': '@proxy_user', 'password': '@proxy_pass'},
                  ],
                },
              },
            },
          },
        },
      ],
      'route': <String, dynamic>{
        'rules': <dynamic>[
          {
            'action': 'resolve',
            'inbound': <dynamic>[
              {
                '#if': {
                  'and': [
                    {
                      '@vpn_mode': {
                        '#in': ['vpn', 'vpn_proxy'],
                      },
                    },
                  ],
                  'value': 'tun-in',
                },
              },
              {
                '#if': {
                  'and': [
                    {
                      '@vpn_mode': {
                        '#in': ['proxy', 'vpn_proxy'],
                      },
                    },
                  ],
                  'value': 'mixed-in',
                },
              },
            ],
            'strategy': '@resolve_strategy',
          },
          {
            '#if': {
              'and': ['@sniff_enabled'],
              'value': {
                'action': 'sniff',
                'inbound': <dynamic>[
                  {
                    '#if': {
                      'and': [
                        {
                          '@vpn_mode': {
                            '#in': ['vpn', 'vpn_proxy'],
                          },
                        },
                      ],
                      'value': 'tun-in',
                    },
                  },
                  {
                    '#if': {
                      'and': [
                        {
                          '@vpn_mode': {
                            '#in': ['proxy', 'vpn_proxy'],
                          },
                        },
                      ],
                      'value': 'mixed-in',
                    },
                  },
                ],
                'timeout': '1s',
              },
            },
          },
          {'protocol': 'dns', 'action': 'hijack-dns'},
        ],
        'final': 'vpn-1',
      },
    };

/// Ноды переменных §120 (type metadata, как в шаблоне).
final _nodes = <String, WizardVar>{
  'vpn_mode': WizardVar(name: 'vpn_mode', type: 'enum', defaultValue: 'vpn'),
  'proxy_type': WizardVar(name: 'proxy_type', type: 'text', defaultValue: 'mixed'),
  'proxy_listen':
      WizardVar(name: 'proxy_listen', type: 'text', defaultValue: '127.0.0.1'),
  'proxy_port': WizardVar(name: 'proxy_port', type: 'int', defaultValue: '2080'),
  'proxy_user': WizardVar(name: 'proxy_user', type: 'text', defaultValue: 'user'),
  'proxy_pass': WizardVar(name: 'proxy_pass', type: 'secret', defaultValue: ''),
  'proxy_auth': WizardVar(name: 'proxy_auth', type: 'bool', defaultValue: 'false'),
  'tun_mtu': WizardVar(name: 'tun_mtu', type: 'int', defaultValue: '1492'),
  'tun_auto_route':
      WizardVar(name: 'tun_auto_route', type: 'bool', defaultValue: 'true'),
  'sniff_enabled':
      WizardVar(name: 'sniff_enabled', type: 'bool', defaultValue: 'true'),
  'resolve_strategy': WizardVar(
      name: 'resolve_strategy', type: 'enum', defaultValue: 'prefer_ipv4'),
  'tun_address':
      WizardVar(name: 'tun_address', type: 'text', defaultValue: ''),
  'tun_address6':
      WizardVar(name: 'tun_address6', type: 'text', defaultValue: ''),
  'ipv6_enabled':
      WizardVar(name: 'ipv6_enabled', type: 'bool', defaultValue: 'false'),
  'route_address_enable': WizardVar(
      name: 'route_address_enable', type: 'bool', defaultValue: 'false'),
};

/// Прогоняет шаблон через walk, повторяя проброс §120 из build_config:
/// прямое присваивание vpn_mode/proxy_* из VpnModeConfig в плоский vars,
/// proxy_auth = effectiveAuth && непустой пароль.
Map<String, dynamic> _build(VpnModeConfig? cfg,
    {bool sniff = true, bool ipv6 = false, bool customRoutes = false}) {
  final config = _templateConfig();
  final vars = <String, String>{
    'tun_mtu': '1492',
    'tun_auto_route': 'true',
    'tun_address': '172.16.0.1/30',
    'tun_address6': 'fdfe::1/126',
    'ipv6_enabled': ipv6 ? 'true' : 'false',
    'route_address_enable': customRoutes ? 'true' : 'false',
    'resolve_strategy': 'prefer_ipv4',
    'sniff_enabled': sniff ? 'true' : 'false',
  };
  if (cfg != null) {
    vars['vpn_mode'] = cfg.mode;
    vars['proxy_type'] = cfg.proxyProtocol;
    vars['proxy_listen'] = cfg.proxyListen;
    vars['proxy_port'] = '${cfg.proxyPort}';
    vars['proxy_user'] = cfg.proxyUsername;
    vars['proxy_pass'] = cfg.proxyPassword;
    vars['proxy_auth'] =
        (cfg.effectiveAuth && cfg.proxyPassword.isNotEmpty) ? 'true' : 'false';
  } else {
    vars['vpn_mode'] = 'vpn';
  }
  walk(config, makeResolver(vars, _nodes));
  return config;
}

List<Map<String, dynamic>> _inbounds(Map<String, dynamic> cfg) =>
    (cfg['inbounds'] as List).cast<Map<String, dynamic>>();

List<Map<String, dynamic>> _rules(Map<String, dynamic> cfg) =>
    ((cfg['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();

Map<String, dynamic>? _firstWhere(
        List<Map<String, dynamic>> list, bool Function(Map) p) =>
    list.cast<Map<String, dynamic>?>().firstWhere(
          (e) => e != null && p(e),
          orElse: () => null,
        );

/// inbound теперь Listable[string] (array). Хелпер: содержит ли rule тег.
bool _ruleHasInbound(Map r, String tag) {
  final inb = r['inbound'];
  if (inb is List) return inb.contains(tag);
  return inb == tag;
}

const _proxyAuth = VpnModeConfig(
  mode: 'proxy',
  proxyProtocol: 'mixed',
  proxyPort: 2080,
  proxyListen: '127.0.0.1',
  proxyAuthEnabled: true,
  proxyUsername: 'user',
  proxyPassword: 'deadbeef',
);

void main() {
  group('VPN-mode declarative #if (§119/§120)', () {
    test('mode=vpn → только tun-in, нет mixed', () {
      final cfg = _build(const VpnModeConfig.defaults());
      final inb = _inbounds(cfg);
      expect(inb.length, 1);
      expect(inb.first['type'], 'tun');
      expect(_firstWhere(inb, (i) => i['tag'] == 'mixed-in'), isNull);
      // resolve inbound = [tun-in].
      final resolve = _firstWhere(_rules(cfg), (r) => r['action'] == 'resolve')!;
      expect(_ruleHasInbound(resolve, 'tun-in'), true);
      expect(_ruleHasInbound(resolve, 'mixed-in'), false);
    });

    test('mode=vpn → tun_mtu коэрсится в int (Часть 1)', () {
      final cfg = _build(const VpnModeConfig.defaults());
      final tun = _inbounds(cfg).first;
      expect(tun['mtu'], 1492);
      expect(tun['mtu'], isA<int>());
      expect(tun['auto_route'], true);
      expect(tun['auto_route'], isA<bool>());
    });

    test('mode=proxy → tun удалён, mixed добавлен', () {
      final cfg = _build(_proxyAuth);
      final inb = _inbounds(cfg);
      expect(_firstWhere(inb, (i) => i['type'] == 'tun'), isNull);
      final mixed = _firstWhere(inb, (i) => i['tag'] == 'mixed-in')!;
      expect(mixed['type'], 'mixed');
      expect(mixed['listen'], '127.0.0.1');
      expect(mixed['listen_port'], 2080);
      expect(mixed['listen_port'], isA<int>());
    });

    test('mode=proxy → нет dangling tun-in в rules', () {
      final cfg = _build(_proxyAuth);
      final rules = _rules(cfg);
      expect(rules.any((r) => _ruleHasInbound(r, 'tun-in')), false);
      final resolve = _firstWhere(rules, (r) => r['action'] == 'resolve')!;
      expect(_ruleHasInbound(resolve, 'mixed-in'), true);
      final sniff = _firstWhere(rules, (r) => r['action'] == 'sniff')!;
      expect(_ruleHasInbound(sniff, 'mixed-in'), true);
    });

    test('mode=proxy → hijack-dns нетронут (без inbound)', () {
      final cfg = _build(_proxyAuth);
      final hijack = _firstWhere(_rules(cfg), (r) => r['action'] == 'hijack-dns');
      expect(hijack, isNotNull);
      expect(hijack!.containsKey('inbound'), false);
    });

    test('mode=vpn_proxy → оба inbound (tun первый)', () {
      final cfg = _build(_proxyAuth.copyWith(mode: 'vpn_proxy'));
      final inb = _inbounds(cfg);
      expect(inb.length, 2);
      expect(inb.first['type'], 'tun'); // tun первый → applyTunPackages находит
      expect(_firstWhere(inb, (i) => i['tag'] == 'mixed-in'), isNotNull);
    });

    test('mode=vpn_proxy → resolve/sniff inbound = [tun-in, mixed-in]', () {
      final cfg = _build(_proxyAuth.copyWith(mode: 'vpn_proxy'));
      final resolve = _firstWhere(_rules(cfg), (r) => r['action'] == 'resolve')!;
      expect(_ruleHasInbound(resolve, 'tun-in'), true);
      expect(_ruleHasInbound(resolve, 'mixed-in'), true);
      final sniff = _firstWhere(_rules(cfg), (r) => r['action'] == 'sniff')!;
      expect(_ruleHasInbound(sniff, 'tun-in'), true);
      expect(_ruleHasInbound(sniff, 'mixed-in'), true);
    });

    test('sniffEnabled=false → sniff-rule отсутствует целиком', () {
      final cfg = _build(_proxyAuth.copyWith(mode: 'vpn_proxy'), sniff: false);
      final rules = _rules(cfg);
      expect(rules.any((r) => r['action'] == 'sniff'), false);
      expect(rules.any((r) => r['action'] == 'resolve'), true);
    });

    test('auth: непустой пароль → users присутствует', () {
      final cfg = _build(_proxyAuth);
      final mixed = _firstWhere(_inbounds(cfg), (i) => i['tag'] == 'mixed-in')!;
      final users = mixed['users'] as List;
      expect(users.length, 1);
      expect((users.first as Map)['username'], 'user');
      expect((users.first as Map)['password'], 'deadbeef');
    });

    test('proxy_pass числовой → остаётся строкой (secret, Часть 1)', () {
      final cfg = _build(_proxyAuth.copyWith(proxyPassword: '1234'));
      final mixed = _firstWhere(_inbounds(cfg), (i) => i['tag'] == 'mixed-in')!;
      final pass = (mixed['users'] as List).first as Map;
      expect(pass['password'], '1234');
      expect(pass['password'], isA<String>());
    });

    test('protocol=http → type=http (tag остаётся mixed-in)', () {
      final cfg = _build(_proxyAuth.copyWith(proxyProtocol: 'http'));
      final inb = _firstWhere(_inbounds(cfg), (i) => i['tag'] == 'mixed-in')!;
      expect(inb['type'], 'http');
      expect((inb['users'] as List).first,
          {'username': 'user', 'password': 'deadbeef'});
    });

    test('protocol=socks → type=socks', () {
      final cfg = _build(_proxyAuth.copyWith(proxyProtocol: 'socks'));
      final inb = _firstWhere(_inbounds(cfg), (i) => i['tag'] == 'mixed-in')!;
      expect(inb['type'], 'socks');
    });

    test('auth off (127.0.0.1) → users отсутствует', () {
      final cfg = _build(_proxyAuth.copyWith(proxyAuthEnabled: false));
      final mixed = _firstWhere(_inbounds(cfg), (i) => i['tag'] == 'mixed-in')!;
      expect(mixed.containsKey('users'), false);
    });

    test('listen 0.0.0.0 → effectiveAuth форсится, users есть', () {
      final m = _proxyAuth.copyWith(
        proxyListen: '0.0.0.0',
        proxyAuthEnabled: false,
      );
      expect(m.effectiveAuth, true);
      final cfg = _build(m);
      final mixed = _firstWhere(_inbounds(cfg), (i) => i['tag'] == 'mixed-in')!;
      expect(mixed.containsKey('users'), true);
      expect(mixed['listen'], '0.0.0.0');
    });

    test('пустой пароль при auth → users отсутствует (защита 067)', () {
      final cfg = _build(_proxyAuth.copyWith(proxyPassword: ''));
      final mixed = _firstWhere(_inbounds(cfg), (i) => i['tag'] == 'mixed-in')!;
      expect(mixed.containsKey('users'), false);
    });

    test('пустой пароль + 0.0.0.0 (effectiveAuth форсится) → всё равно нет users',
        () {
      final m = _proxyAuth.copyWith(
        proxyListen: '0.0.0.0',
        proxyAuthEnabled: false,
        proxyPassword: '',
      );
      expect(m.effectiveAuth, true); // 0.0.0.0 форсит
      final cfg = _build(m);
      final mixed = _firstWhere(_inbounds(cfg), (i) => i['tag'] == 'mixed-in')!;
      // НЕ должно быть users:[{...,password:""}] — защита от broken auth.
      expect(mixed.containsKey('users'), false);
    });

    test('settings.vpnMode == null → degrade к tun-only', () {
      final cfg = _build(null);
      final inb = _inbounds(cfg);
      expect(inb.length, 1);
      expect(inb.first['type'], 'tun');
      expect(_firstWhere(inb, (i) => i['tag'] == 'mixed-in'), isNull);
    });
  });

  group('VpnModeConfig model (§119)', () {
    test('predicates', () {
      const vpn = VpnModeConfig.defaults();
      expect(vpn.isVpn, true);
      expect(vpn.hasTun, true);
      expect(vpn.hasMixed, false);

      final proxy = vpn.copyWith(mode: 'proxy');
      expect(proxy.isProxy, true);
      expect(proxy.hasTun, false);
      expect(proxy.hasMixed, true);

      final both = vpn.copyWith(mode: 'vpn_proxy');
      expect(both.isVpnProxy, true);
      expect(both.hasTun, true);
      expect(both.hasMixed, true);
    });

    test('effectiveAuth: 0.0.0.0 форсит on', () {
      const m = VpnModeConfig(
        mode: 'proxy',
        proxyProtocol: 'mixed',
        proxyPort: 2080,
        proxyListen: '0.0.0.0',
        proxyAuthEnabled: false,
        proxyUsername: 'user',
        proxyPassword: 'x',
      );
      expect(m.isPublicListen, true);
      expect(m.effectiveAuth, true);
    });

    test('effectiveAuth: 127.0.0.1 уважает authEnabled', () {
      const off = VpnModeConfig(
        mode: 'proxy',
        proxyProtocol: 'mixed',
        proxyPort: 2080,
        proxyListen: '127.0.0.1',
        proxyAuthEnabled: false,
        proxyUsername: 'user',
        proxyPassword: 'x',
      );
      expect(off.effectiveAuth, false);
    });

    test('произвольный LAN-IP (192.168.1.5) → isPublicListen, форсит auth', () {
      const lan = VpnModeConfig(
        mode: 'proxy',
        proxyProtocol: 'mixed',
        proxyPort: 2080,
        proxyListen: '192.168.1.5',
        proxyAuthEnabled: false, // снято — но не-loopback форсит
        proxyUsername: 'user',
        proxyPassword: 'x',
      );
      expect(lan.isPublicListen, true);
      expect(lan.effectiveAuth, true);
    });

    test('произвольный loopback (127.10.20.5) → auth уважает authEnabled', () {
      const lo = VpnModeConfig(
        mode: 'proxy',
        proxyProtocol: 'mixed',
        proxyPort: 2080,
        proxyListen: '127.10.20.5',
        proxyAuthEnabled: false,
        proxyUsername: 'user',
        proxyPassword: 'x',
      );
      expect(lo.isPublicListen, false);
      expect(lo.effectiveAuth, false);
    });

    test('isValidListenAddr — IPv4 валидация', () {
      expect(VpnModeConfig.isValidListenAddr('127.0.0.1'), true);
      expect(VpnModeConfig.isValidListenAddr('0.0.0.0'), true);
      expect(VpnModeConfig.isValidListenAddr('192.168.1.5'), true);
      expect(VpnModeConfig.isValidListenAddr('255.255.255.255'), true);
      expect(VpnModeConfig.isValidListenAddr('256.0.0.1'), false); // октет > 255
      expect(VpnModeConfig.isValidListenAddr('1.2.3'), false); // мало октетов
      expect(VpnModeConfig.isValidListenAddr('1.2.3.4.5'), false); // много
      expect(VpnModeConfig.isValidListenAddr('abc'), false);
      expect(VpnModeConfig.isValidListenAddr(''), false);
      expect(VpnModeConfig.isValidListenAddr('1.2.3.'), false); // пустой октет
    });

    test('isLoopback — 127.x', () {
      expect(VpnModeConfig.isLoopback('127.0.0.1'), true);
      expect(VpnModeConfig.isLoopback('127.10.20.5'), true);
      expect(VpnModeConfig.isLoopback('0.0.0.0'), false);
      expect(VpnModeConfig.isLoopback('192.168.1.5'), false);
    });

    test('toJson round-trip keys', () {
      final json = _proxyAuth.toJson();
      expect(json['mode'], 'proxy');
      expect(json['proxy_protocol'], 'mixed');
      expect(json['proxy_port'], 2080);
      expect(json['proxy_listen'], '127.0.0.1');
      expect(json['proxy_auth_enabled'], true);
      expect(json['proxy_username'], 'user');
      expect(json['proxy_password'], 'deadbeef');
    });

    test('protocol constants', () {
      expect(VpnModeConfig.protoMixed, 'mixed');
      expect(VpnModeConfig.protoHttp, 'http');
      expect(VpnModeConfig.protoSocks, 'socks');
      expect(const VpnModeConfig.defaults().proxyProtocol, 'mixed');
    });

    test('defaults = vpn mode (backward-compat)', () {
      const d = VpnModeConfig.defaults();
      expect(d.mode, 'vpn');
      expect(d.proxyPort, 2080);
      expect(d.proxyListen, '127.0.0.1');
    });
  });

  // §232 — IPv6/route_address за галками (защитный opt-in).
  group('§232 IPv6 & custom routes gating', () {
    Map<String, dynamic> tun(Map<String, dynamic> cfg) =>
        _firstWhere(_inbounds(cfg), (i) => i['tag'] == 'tun-in')!;

    test('оба OFF (дефолт) → только v4-адрес, нет route_address', () {
      final t = tun(_build(const VpnModeConfig.defaults()));
      expect(t['address'], ['172.16.0.1/30']);
      expect(t.containsKey('route_address'), isFalse);
    });

    test('ipv6 ON → v4+v6 адрес', () {
      final t = tun(_build(const VpnModeConfig.defaults(), ipv6: true));
      expect(t['address'], ['172.16.0.1/30', 'fdfe::1/126']);
    });

    test('customRoutes ON → route_address появляется (половинки)', () {
      final t =
          tun(_build(const VpnModeConfig.defaults(), customRoutes: true));
      expect(t['route_address'],
          ['0.0.0.0/1', '128.0.0.0/1', '::/1', '8000::/1']);
    });

    test('customRoutes OFF → route_address отсутствует (авто 0.0.0.0/0)', () {
      final t = tun(_build(const VpnModeConfig.defaults(), ipv6: true));
      expect(t.containsKey('route_address'), isFalse);
    });

    test('оба ON → v4+v6 адрес И route_address', () {
      final t = tun(_build(const VpnModeConfig.defaults(),
          ipv6: true, customRoutes: true));
      expect(t['address'], ['172.16.0.1/30', 'fdfe::1/126']);
      expect(t['route_address'],
          ['0.0.0.0/1', '128.0.0.0/1', '::/1', '8000::/1']);
    });
  });

  // §292 — валидаторы порта/протокола на модели (инвариант, общий для UI +
  // Debug API). Ловят мусор, который иначе дошёл бы до sing-box inbounds.
  group('§292 isValidPort', () {
    test('в диапазоне 1024..65535 → true', () {
      expect(VpnModeConfig.isValidPort(2080), isTrue);
      expect(VpnModeConfig.isValidPort(1024), isTrue);
      expect(VpnModeConfig.isValidPort(65535), isTrue);
    });
    test('привилегированные (<1024), 0, negative, >65535 → false', () {
      expect(VpnModeConfig.isValidPort(1023), isFalse);
      expect(VpnModeConfig.isValidPort(80), isFalse);
      expect(VpnModeConfig.isValidPort(0), isFalse);
      expect(VpnModeConfig.isValidPort(-1), isFalse);
      expect(VpnModeConfig.isValidPort(65536), isFalse);
      expect(VpnModeConfig.isValidPort(99999), isFalse);
    });
    test('граница совпадает с UI vpn_mode_tab (1024)', () {
      // Регресс-якорь: UI _applyPort отвергает <1024; модель обязана тоже.
      expect(VpnModeConfig.isValidPort(1024), isTrue);
      expect(VpnModeConfig.isValidPort(1023), isFalse);
    });
  });

  group('§292 isValidProtocol', () {
    test('mixed/http/socks → true', () {
      expect(VpnModeConfig.isValidProtocol(VpnModeConfig.protoMixed), isTrue);
      expect(VpnModeConfig.isValidProtocol(VpnModeConfig.protoHttp), isTrue);
      expect(VpnModeConfig.isValidProtocol(VpnModeConfig.protoSocks), isTrue);
    });
    test('мусор → false', () {
      expect(VpnModeConfig.isValidProtocol('vless'), isFalse);
      expect(VpnModeConfig.isValidProtocol(''), isFalse);
      expect(VpnModeConfig.isValidProtocol('MIXED'), isFalse);
    });
  });
}
