import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/parse_all.dart';

/// §321 — Xray-массив парсится по всем протоколам, а не только по VLESS.
///
/// До §321 фильтр `protocol == 'vless'` отбрасывал элемент целиком и молча:
/// на подписке Liberty так потерялись три платных hysteria2-узла (GAMING).
void main() {
  Map<String, dynamic> element(String remarks, List<Map<String, dynamic>> obs) =>
      {
        'remarks': remarks,
        'outbounds': [
          ...obs,
          {'tag': 'direct', 'protocol': 'freedom'},
          {'tag': 'block', 'protocol': 'blackhole'},
        ],
      };

  Map<String, dynamic> vless(String addr, {String uuid = 'u-1', int port = 443}) =>
      {
        'tag': 'proxy',
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {
              'address': addr,
              'port': port,
              'users': [
                {'id': uuid, 'encryption': 'none'}
              ],
            }
          ],
        },
        'streamSettings': {'network': 'tcp', 'security': 'none'},
      };

  group('протоколы помимо VLESS', () {
    test('trojan → TrojanSpec', () {
      final n = parseXrayElement(element('T', [
        {
          'tag': 'proxy',
          'protocol': 'trojan',
          'settings': {
            'servers': [
              {'address': '1.2.3.4', 'port': 443, 'password': 'pw'}
            ],
          },
          'streamSettings': {'network': 'tcp', 'security': 'tls'},
        }
      ]));
      expect(n, hasLength(1));
      final t = n.first as TrojanSpec;
      expect(t.server, '1.2.3.4');
      expect(t.password, 'pw');
      expect(t.tls.enabled, isTrue);
      expect(t.label, 'T');
    });

    test('vmess → VmessSpec с alterId/security', () {
      final n = parseXrayElement(element('V', [
        {
          'tag': 'proxy',
          'protocol': 'vmess',
          'settings': {
            'vnext': [
              {
                'address': '5.6.7.8',
                'port': 80,
                'users': [
                  {'id': 'uuid-v', 'alterId': 4, 'security': 'aes-128-gcm'}
                ],
              }
            ],
          },
          'streamSettings': {'network': 'tcp'},
        }
      ]));
      final v = n.single as VmessSpec;
      expect(v.uuid, 'uuid-v');
      expect(v.alterId, 4);
      expect(v.security, 'aes-128-gcm');
    });

    test('shadowsocks → ShadowsocksSpec', () {
      final n = parseXrayElement(element('S', [
        {
          'tag': 'proxy',
          'protocol': 'shadowsocks',
          'settings': {
            'servers': [
              {
                'address': '9.9.9.9',
                'port': 8388,
                'method': 'aes-256-gcm',
                'password': 'ss-pw',
              }
            ],
          },
        }
      ]));
      final s = n.single as ShadowsocksSpec;
      expect(s.method, 'aes-256-gcm');
      expect(s.password, 'ss-pw');
      expect(s.port, 8388);
    });
  });

  group('hysteria (форк-специфичная форма)', () {
    Map<String, dynamic> hy(int version) => {
          'tag': 'proxy',
          'protocol': 'hysteria',
          'settings': {'address': '45.196.193.40', 'port': 8449, 'version': version},
          'streamSettings': {
            'network': 'hysteria',
            'security': 'tls',
            'hysteriaSettings': {'auth': 'auth-uuid', 'version': version},
            'tlsSettings': {
              'serverName': 'gt-ch-02.live',
              'alpn': ['h3'],
              'fingerprint': 'firefox',
            },
            'finalmask': {
              'quicParams': {'congestion': 'bbr', 'debug': false}
            },
          },
        };

    test('version 2 → Hysteria2Spec', () {
      final n = parseXrayElement(element('🎮 GAMING', [hy(2)]));
      final h = n.single as Hysteria2Spec;
      expect(h.server, '45.196.193.40');
      expect(h.port, 8449);
      expect(h.password, 'auth-uuid');
      expect(h.tls.enabled, isTrue);
      expect(h.tls.serverName, 'gt-ch-02.live');
      expect(h.label, '🎮 GAMING');
    });

    test('finalmask (расширение форка) не уезжает в конфиг', () {
      final n = parseXrayElement(element('G', [hy(2)]));
      final emitted = n.single.emitRaw(const TemplateVars()).map;
      expect(emitted.keys, isNot(contains('finalmask')));
      expect(emitted.toString(), isNot(contains('quicParams')));
    });

    test('version 1 → узла нет (Hysteria1Spec у нас отсутствует)', () {
      expect(parseXrayElement(element('old', [hy(1)])), isEmpty);
    });
  });

  group('служебные outbound-ы', () {
    test('элемент из одних freedom/blackhole → узлов нет', () {
      expect(parseXrayElement(element('empty', const [])), isEmpty);
    });

    test('freedom/blackhole/dns узлами не становятся', () {
      final n = parseXrayElement(element('mix', [
        vless('1.1.1.1'),
        {'tag': 'dns-out', 'protocol': 'dns'},
      ]));
      expect(n, hasLength(1));
      expect(n.single.server, '1.1.1.1');
    });
  });

  test('смешанный массив: vless + hysteria2 доезжают оба', () {
    final body = '''[
      ${_json(element('🇩🇪 Германия', [vless('10.0.0.1')]))},
      ${_json(element('🎮 GAMING', [
          {
            'tag': 'proxy',
            'protocol': 'hysteria',
            'settings': {'address': '10.0.0.2', 'port': 8449, 'version': 2},
            'streamSettings': {
              'network': 'hysteria',
              'security': 'tls',
              'hysteriaSettings': {'auth': 'a', 'version': 2},
            },
          }
        ]))}
    ]''';
    final nodes = parseAll(decode(body));
    expect(nodes.map((n) => n.protocol), containsAll(['vless', 'hysteria2']));
    expect(nodes, hasLength(2));
  });
  group('§321 P5 — неподдержанный протокол не пропадает молча', () {
    Map<String, dynamic> ob(String proto, String tag) => {
          'tag': tag,
          'protocol': proto,
          'settings': {
            'vnext': [
              {
                'address': '1.1.1.1',
                'port': 443,
                'users': [
                  {'id': 'u'}
                ]
              }
            ]
          },
          'streamSettings': {'network': 'tcp', 'security': 'none'},
        };

    List<NodeSpec> parse(List<Map<String, dynamic>> obs) =>
        parseAll(decode(jsonEncode([
          {'remarks': 'X', 'outbounds': obs}
        ])));

    test('warning висит на соседе по элементу', () {
      final r = parse([ob('vless', 'v'), ob('wireguard', 'w')]);
      expect(r, hasLength(1));
      expect(r.first.warnings.whereType<UnsupportedProtocolWarning>(),
          hasLength(1));
    });

    test('один warning на протокол, не на каждый outbound', () {
      final r = parse([
        ob('vless', 'v'),
        ob('wireguard', 'w1'),
        ob('wireguard', 'w2'),
      ]);
      expect(r.first.warnings.whereType<UnsupportedProtocolWarning>(),
          hasLength(1));
    });

    test('разные протоколы → разные warnings', () {
      final r = parse([ob('vless', 'v'), ob('wireguard', 'w'), ob('ssh', 's')]);
      expect(r.first.warnings.whereType<UnsupportedProtocolWarning>(),
          hasLength(2));
    });

    test('поддержанные протоколы warnings не порождают', () {
      // Оба vless: у trojan своя схема (`settings.servers`), и хелпер `ob`
      // с `vnext` дал бы ложный warning — проверяем не это.
      final r = parse([ob('vless', 'v1'), ob('vless', 'v2')]);
      for (final n in r) {
        expect(n.warnings.whereType<UnsupportedProtocolWarning>(), isEmpty);
      }
    });
  });

}

String _json(Map<String, dynamic> m) => _encode(m);
String _encode(Object? v) {
  if (v is Map) {
    return '{${v.entries.map((e) => '"${e.key}":${_encode(e.value)}').join(',')}}';
  }
  if (v is List) return '[${v.map(_encode).join(',')}]';
  if (v is String) return '"$v"';
  return '$v';

}
