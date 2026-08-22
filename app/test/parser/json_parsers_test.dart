import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/node_identity.dart';
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
        'private_key': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=',
        'peers': [
          {
            'address': '162.159.192.1',
            'port': 2408,
            'public_key': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=',
            'allowed_ips': ['0.0.0.0/0'],
            'reserved': [1, 2, 3],
          }
        ],
      });
      expect(spec, isA<WireguardSpec>());
      final wg = spec! as WireguardSpec;
      expect(wg.peers.single.reserved, [1, 2, 3]);
    });

    // SPEC 103 D-026 — canon = Go: mtu не эмитится, когда его не было в
    // источнике (ядро само ставит 1408, transport/wireguard/endpoint.go).
    // Было закреплено, что парсер сам подставляет 1408 — неканоничное
    // поведение (свой дефолт спорил с ядром и ломал identity-хеш), тест
    // обновлён.
    test('§219 wireguard: plain WG без mtu → mtu не задан (как URI-парсер)', () {
      final spec = parseSingboxEntry({
        'type': 'wireguard',
        'tag': 'wg',
        'address': ['172.16.0.2/32'],
        'private_key': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=',
        'peers': [
          {
            'address': '1.2.3.4',
            'port': 51820,
            'public_key': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=',
            'allowed_ips': ['0.0.0.0/0'],
          }
        ],
      });
      expect((spec! as WireguardSpec).mtu, isNull);
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
        vhttp: 'h2',
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
      expect(m.vhttp, 'h2');
      expect(m.sni, '4pda.to');
      expect(m.localAddresses, containsAll(orig.localAddresses));
      expect(m.idleTimeout, '10m');
      expect(m.keepAlive, '45s');
    });

    test('§393 — masque: старая плоская схема ядра ещё читается', () {
      final m = parseSingboxEntry({
        'type': 'masque',
        'tag': 'legacy',
        'server': '162.159.198.2',
        'server_port': 443,
        'private_key': 'PRIVDER==',
        'public_key': 'PUBDER==',
        'ip': '172.16.0.2/32',
        'network': 'h2',
        'sni': '4pda.to',
      }) as MasqueSpec?;
      expect(m, isNotNull);
      expect(m!.vhttp, 'h2');
      expect(m.sni, '4pda.to');
      expect(m.disableSni, isFalse);
    });

    test('§393 — masque: новое имя сильнее старого при обоих сразу', () {
      final m = parseSingboxEntry({
        'type': 'masque',
        'tag': 'both',
        'server': '162.159.198.2',
        'server_port': 443,
        'private_key': 'PRIVDER==',
        'public_key': 'PUBDER==',
        'ip': '172.16.0.2/32',
        'network': 'h2',
        'vhttp': 'h3',
        'sni': 'old.example',
        'tls': {'server_name': 'new.example', 'disable_sni': true},
      }) as MasqueSpec?;
      expect(m!.vhttp, 'h3');
      expect(m.sni, 'new.example');
      expect(m.disableSni, isTrue);
    });

    test('§358 — hysteria2 gecko round-trip: JSON → spec → JSON', () {
      final spec = parseSingboxEntry({
        'type': 'hysteria2',
        'tag': 'hy2',
        'server': 'h.example',
        'server_port': 443,
        'password': 'secret',
        'obfs': {
          'type': 'gecko',
          'password': 'op',
          'min_packet_size': 100,
          'max_packet_size': 1200,
        },
      });
      final hy = spec! as Hysteria2Spec;
      expect(hy.obfs, 'gecko');
      expect(hy.obfsPassword, 'op');
      expect(hy.obfsMinPacketSize, 100);
      expect(hy.obfsMaxPacketSize, 1200);

      final back =
          hy.emitRaw(TemplateVars.empty).map['obfs'] as Map<String, dynamic>;
      expect(back['type'], 'gecko');
      expect(back['min_packet_size'], 100);
      expect(back['max_packet_size'], 1200);
    });

    test('§358 — hysteria2 с неизвестным obfs: тип отброшен, конфиг цел', () {
      final spec = parseSingboxEntry({
        'type': 'hysteria2',
        'tag': 'hy2',
        'server': 'h.example',
        'server_port': 443,
        'password': 'secret',
        'obfs': {'type': 'xyz', 'password': 'op'},
      });
      final hy = spec! as Hysteria2Spec;
      expect(hy.obfs, isEmpty);
      expect(hy.emitRaw(TemplateVars.empty).map.containsKey('obfs'), isFalse);
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

    test('§335+§321: dialerProxy не теряет encryption (регрессия _withChain)', () {
      const enc = 'mlkem768x25519plus.native.0rtt.AbCd-EfGh_IjKl0123456789';
      final main = vless('proxy', 'main.example');
      (main['streamSettings'] as Map)['sockopt'] = {'dialerProxy': 'jump'};
      (((main['settings'] as Map)['vnext'] as List).first['users'] as List)
          .first['encryption'] = enc;
      final nodes = parseXrayElement({
        'remarks': 'Chained',
        'outbounds': [main, vless('jump', 'jump.example')],
      });
      final spec = nodes.single as VlessSpec;
      expect(spec.chained, isNotNull, reason: 'цепочка сохранена');
      expect(spec.encryption, enc,
          reason: '_withChain пересобирает Spec и обязан пронести §335-слой');
    });

    test('§322: мусорный streamSettings строкой → пропуск узла, сосед жив', () {
      final broken = vless('proxy-bad', 'bad.example');
      broken['streamSettings'] = 'none';
      final nodes = parseXrayElement({
        'remarks': 'Mixed',
        'outbounds': [broken, vless('proxy-ok', 'ok.example')],
      });
      expect(nodes.map((n) => n.server), ['ok.example'],
          reason: 'битый outbound не роняет соседей по элементу');
      expect(nodes.single.warnings, isNotEmpty,
          reason: 'пропажа не молчаливая — P5-warning на выжившем');
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

  // §321 P4/§322 — ИНВАРИАНТ: ключ идентичности, посчитанный парсером по
  // сырому Xray-JSON (tagSynonyms), обязан посимвольно совпадать с
  // nodeIdentityKey готового NodeSpec — иначе резолв пула на билде
  // (server_list_build) молча выкидывает члена.
  group('идентичность parser ↔ builder', () {
    Map<String, dynamic> balancer(List<String> selector) => {
          'balancers': [
            {
              'tag': 'auto',
              'selector': selector,
              'strategy': {'type': 'leastPing'},
            }
          ],
        };

    test('hysteria (форма форка) → ключ hysteria2|…, порт как у конвертера',
        () {
      final nodes = parseXrayElement({
        'remarks': 'HY',
        'outbounds': [
          {
            'tag': 'hy-1',
            'protocol': 'hysteria',
            'settings': {'address': 'hy.example', 'port': 8443, 'version': 2},
            'streamSettings': {
              'network': 'hysteria',
              'hysteriaSettings': {'auth': 'secret', 'version': 2},
            },
          },
        ],
        'routing': balancer(['hy-1']),
      });
      final hy = nodes.whereType<Hysteria2Spec>().single;
      final auto = nodes.whereType<AutoSelectSpec>().single;
      final syn = auto.tagSynonyms['hy-1'];
      expect(syn, startsWith('hysteria2|'),
          reason: 'Spec-протокол hysteria2, не сырой "hysteria"');
      expect(syn, nodeIdentityKeyRaw(hy));
    });

    test('vless без порта и с vision-udp443 → порт ключа как у конвертера',
        () {
      final nodes = parseXrayElement({
        'remarks': 'V',
        'outbounds': [
          {
            'tag': 'no-port',
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'a.example',
                  'users': [
                    {'id': 'u-1'}
                  ],
                }
              ],
            },
            'streamSettings': {'network': 'tcp'},
          },
          {
            'tag': 'udp443',
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'b.example',
                  'port': 8443,
                  'users': [
                    {'id': 'u-2', 'flow': 'xtls-rprx-vision-udp443'}
                  ],
                }
              ],
            },
            'streamSettings': {'network': 'tcp'},
          },
        ],
        'routing': balancer(['no-port', 'udp443']),
      });
      final auto = nodes.whereType<AutoSelectSpec>().single;
      final byServer = {
        for (final n in nodes.whereType<VlessSpec>()) n.server: n,
      };
      expect(auto.tagSynonyms['no-port'],
          nodeIdentityKeyRaw(byServer['a.example']!),
          reason: 'дефолт порта — 443, как в _xrayVlessToSpec');
      expect(auto.tagSynonyms['udp443'],
          nodeIdentityKeyRaw(byServer['b.example']!),
          reason: 'vision-udp443 переписывает порт узла на 443 — и ключа тоже');
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
