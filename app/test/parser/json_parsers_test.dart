import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/json_parsers.dart';

void main() {
  group('parseSingboxEntry', () {
    test('§115: raw sing-box JSON flow=vision + transport → emit гасит flow',
        () {
      // parseSingboxEntry читает flow напрямую (spec.flow=vision), но
      // универсальный net на эмиссии (§115) убирает flow при транспорте —
      // покрывает путь, который парсерные guard'ы URI/Xray не трогают.
      final spec = parseSingboxEntry({
        'type': 'vless',
        'tag': 't',
        'server': 'h.example',
        'server_port': 443,
        'uuid': '11111111-2222-3333-4444-555555555555',
        'flow': 'xtls-rprx-vision',
        'tls': {'enabled': true, 'server_name': 'w.example'},
        'transport': {'type': 'ws', 'path': '/x'},
      }) as VlessSpec;
      final emitted = spec.emit(TemplateVars.empty).map;
      expect(emitted['flow'], isNull, reason: 'flow+transport невалидно');
      expect(emitted['transport'], isNotNull);
    });

    test('vless outbound fixture', () {
      final j = jsonDecode(
        File('test/fixtures/json/singbox_vless_outbound.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final spec = parseSingboxEntry(j);
      expect(spec, isA<VlessSpec>());
      final v = spec! as VlessSpec;
      expect(v.uuid, '11111111-2222-3333-4444-555555555555');
      expect(v.flow, 'xtls-rprx-vision');
      expect(v.tls.reality?.publicKey, isNotEmpty);
    });

    test('wireguard endpoint fixture', () {
      final j = jsonDecode(
        File('test/fixtures/json/singbox_wg_endpoint.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final spec = parseSingboxEntry(j);
      expect(spec, isA<WireguardSpec>());
      final wg = spec! as WireguardSpec;
      expect(wg.peers, hasLength(1));
      expect(wg.mtu, 1420);
    });

    test('§219 wireguard: reserved из peer парсится (WARP client_id)', () {
      final spec = parseSingboxEntry({
        'type': 'wireguard',
        'tag': 'wg',
        'address': ['172.16.0.2/32'],
        'private_key': 'PRIV==',
        'peers': [
          {
            'address': '162.159.192.1',
            'port': 2408,
            'public_key': 'PUB==',
            'allowed_ips': ['0.0.0.0/0'],
            'reserved': [1, 2, 3],
          }
        ],
      });
      expect(spec, isA<WireguardSpec>());
      final wg = spec! as WireguardSpec;
      expect(wg.peers.single.reserved, [1, 2, 3]);
    });

    test('§219 wireguard: plain WG без mtu → дефолт 1408 (как URI-парсер)', () {
      final spec = parseSingboxEntry({
        'type': 'wireguard',
        'tag': 'wg',
        'address': ['172.16.0.2/32'],
        'private_key': 'PRIV==',
        'peers': [
          {
            'address': '1.2.3.4',
            'port': 51820,
            'public_key': 'PUB==',
            'allowed_ips': ['0.0.0.0/0'],
          }
        ],
      });
      expect((spec! as WireguardSpec).mtu, 1408);
    });

    test('§130 masque round-trip: emit → parseSingboxEntry ≈ spec', () {
      final orig = MasqueSpec(
        id: 'x',
        tag: '🔥🎭 WARP (MASQUE)',
        label: 'l',
        server: '162.159.198.2',
        port: 443,
        rawUri: '',
        privateKeyDer: 'PRIVDER==',
        publicKeyDer: 'PUBDER==',
        localAddresses: ['172.16.0.2/32', '2606:4700:110::2/128'],
        network: 'h2',
        sni: '4pda.to',
        mtu: 1280,
        idleTimeout: '10m',
        keepAlive: '45s',
      );
      // emit пишет sing-box JSON — читаем обратно через parseSingboxEntry.
      final json = orig.emit(TemplateVars.empty).map;
      final back = parseSingboxEntry(json.cast<String, dynamic>());
      expect(back, isA<MasqueSpec>());
      final m = back! as MasqueSpec;
      expect(m.privateKeyDer, orig.privateKeyDer);
      expect(m.publicKeyDer, orig.publicKeyDer);
      expect(m.server, orig.server);
      expect(m.port, orig.port);
      expect(m.network, 'h2');
      expect(m.sni, '4pda.to');
      expect(m.localAddresses, containsAll(orig.localAddresses));
      expect(m.idleTimeout, '10m');
      expect(m.keepAlive, '45s');
    });

    test('masque без ключей → null', () {
      expect(
        parseSingboxEntry(
            {'type': 'masque', 'server': 'h', 'server_port': 443}),
        isNull,
      );
    });

    test('unknown type → null', () {
      expect(parseSingboxEntry({'type': 'bogus'}), isNull);
    });
  });

  group('parseXrayOutbound', () {
    test('reality array fixture', () {
      final j = jsonDecode(
        File('test/fixtures/json/xray_array_reality.json').readAsStringSync(),
      ) as List;
      final spec = parseXrayOutbound(j.first as Map<String, dynamic>);
      expect(spec, isA<VlessSpec>());
      final v = spec! as VlessSpec;
      expect(v.uuid, '11111111-2222-3333-4444-555555555555');
      expect(v.tls.reality?.publicKey, isNotEmpty);
    });

    test('§115: Xray REALITY+tcp без flow → flow ПУСТОЙ (не навязываем)', () {
      final spec = parseXrayOutbound({
        'outbounds': [
          {
            'tag': 'proxy',
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'h.example',
                  'port': 443,
                  'users': [
                    {'id': '11111111-2222-3333-4444-555555555555'}
                  ],
                }
              ],
            },
            'streamSettings': {
              'network': 'tcp',
              'security': 'reality',
              // §169 — валидный X25519 (43-симв base64url). `PK` (2 симв)
              // теперь невалиден и дал бы plain TLS без reality.
              'realitySettings': {
                'publicKey': 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw',
                'shortId': 'abcd',
              },
            },
          }
        ],
      }) as VlessSpec;
      expect(spec.flow, '', reason: 'REALITY+tcp без flow → не vision');
      expect(spec.tls.reality?.publicKey, isNotEmpty);
    });

    test('§335: Xray users[0].encryption → плоское поле рядом с uuid', () {
      const enc = 'mlkem768x25519plus.native.0rtt.AbCd-EfGh_IjKl0123456789';
      final spec = parseXrayOutbound({
        'outbounds': [
          {
            'tag': 'proxy',
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'h.example',
                  'port': 1080,
                  'users': [
                    {
                      'id': '11111111-2222-3333-4444-555555555555',
                      'flow': '',
                      'encryption': enc,
                    }
                  ],
                }
              ],
            },
            'streamSettings': {'network': 'ws', 'wsSettings': {'path': '/ws'}},
          }
        ],
      }) as VlessSpec;
      expect(spec.encryption, enc, reason: 'вложено в users[0], берём оттуда');
      // В конфиге ядра уровень вложенности другой — плоское поле аутбаунда.
      expect(spec.emit(TemplateVars.empty).map['encryption'], enc);
    });

    test('§335: Xray без encryption → поля в конфиге нет', () {
      final spec = parseXrayOutbound({
        'outbounds': [
          {
            'tag': 'proxy',
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'h.example',
                  'port': 443,
                  'users': [
                    {'id': '11111111-2222-3333-4444-555555555555'}
                  ],
                }
              ],
            },
            'streamSettings': {'network': 'tcp'},
          }
        ],
      }) as VlessSpec;
      expect(spec.encryption, isEmpty);
      expect(spec.emit(TemplateVars.empty).map.containsKey('encryption'),
          isFalse);
    });

    test('§169: Xray reality + битый publicKey → plain TLS, без reality', () {
      final spec = parseXrayOutbound({
        'outbounds': [
          {
            'tag': 'proxy',
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'h.example',
                  'port': 443,
                  'users': [
                    {'id': '11111111-2222-3333-4444-555555555555'}
                  ],
                }
              ],
            },
            'streamSettings': {
              'network': 'tcp',
              'security': 'reality',
              'realitySettings': {'publicKey': 'enabled', 'shortId': 'abcd'},
            },
          }
        ],
      }) as VlessSpec;
      expect(spec.tls.enabled, isTrue, reason: 'нода рабочая (plain TLS)');
      expect(spec.tls.reality, isNull, reason: 'мусорный publicKey → нет reality');
    });
  });

  group('§310 parseXrayElement — все ноды элемента', () {
    const pbk = 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw';
    Map<String, dynamic> vless(String tag, String host) => {
          'tag': tag,
          'protocol': 'vless',
          'settings': {
            'vnext': [
              {
                'address': host,
                'port': 443,
                'users': [
                  {'id': '11111111-2222-3333-4444-555555555555'}
                ],
              }
            ],
          },
          'streamSettings': {
            'network': 'tcp',
            'security': 'reality',
            'realitySettings': {'publicKey': pbk, 'shortId': 'ab'},
          },
        };

    test('3 равноправных VLESS → 3 ноды, имена различимы', () {
      final nodes = parseXrayElement({
        'remarks': 'Main Server',
        'outbounds': [
          vless('proxy', 'node1.example'),
          vless('proxy-2', 'node3.example'),
          vless('proxy-3', 'node2n.example'),
        ],
      });
      expect(nodes.length, 3, reason: 'резервные ноды больше не теряются');
      expect(nodes.map((n) => n.server),
          ['node1.example', 'node3.example', 'node2n.example']);
      // §322 — `remarks` без добавки положен ровно одной сущности элемента.
      // Узлов несколько → тег получают ВСЕ, включая первый (раньше он брал
      // чистый `remarks` и дрался за имя с группой автовыбора).
      expect(nodes.map((n) => n.label), [
        'Main Server proxy',
        'Main Server proxy-2',
        'Main Server proxy-3',
      ]);
      expect(nodes.map((n) => n.label).toSet().length, 3,
          reason: 'в списке узлов не должно быть одинаковых строк');
    });

    test('одиночный VLESS → 1 нода, имя как до §310', () {
      final nodes = parseXrayElement({
        'remarks': 'Solo',
        'outbounds': [vless('proxy', 'h.example')],
      });
      expect(nodes.length, 1);
      expect(nodes.single.label, 'Solo');
    });

    test('§018 регрессия: dialerProxy → 1 нода с detour, цель НЕ отдельной нодой',
        () {
      final main = vless('proxy', 'main.example');
      (main['streamSettings'] as Map)['sockopt'] = {'dialerProxy': 'jump'};
      final nodes = parseXrayElement({
        'remarks': 'Chained',
        'outbounds': [main, vless('jump', 'jump.example')],
      });
      expect(nodes.length, 1, reason: 'dialer-цель не дублируется узлом');
      expect(nodes.single.server, 'main.example');
      expect(nodes.single.chained, isNotNull, reason: 'цепочка сохранена');
      expect(nodes.single.chained!.server, 'jump.example');
    });

    test('main-приоритет: тег proxy идёт первым независимо от порядка', () {
      final nodes = parseXrayElement({
        'remarks': 'R',
        'outbounds': [vless('extra', 'b.example'), vless('proxy', 'a.example')],
      });
      expect(nodes.first.server, 'a.example',
          reason: 'первый узел тот же, что и до §310');
      expect(nodes.length, 2);
    });

    test('remarks пустой → метка из тега outbound', () {
      final nodes = parseXrayElement({
        'outbounds': [vless('proxy', 'a.example'), vless('backup', 'b.example')],
      });
      expect(nodes.length, 2);
      expect(nodes[1].label, 'backup');
    });
  });

  group('§169 _tlsFromSingbox pbk validation', () {
    test('sing-box reality + битый public_key → plain TLS, без reality', () {
      final spec = parseSingboxEntry({
        'type': 'vless',
        'tag': 't',
        'server': 'h.example',
        'server_port': 443,
        'uuid': '11111111-2222-3333-4444-555555555555',
        'tls': {
          'enabled': true,
          'server_name': 'w.example',
          'reality': {'enabled': true, 'public_key': 'true', 'short_id': 'ab'},
        },
      }) as VlessSpec;
      expect(spec.tls.enabled, isTrue);
      expect(spec.tls.reality, isNull, reason: 'битый public_key → нет reality');
      expect(spec.tls.serverName, 'w.example');
    });
  });
}
