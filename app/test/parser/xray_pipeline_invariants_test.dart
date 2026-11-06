import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../contract_paths.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/parse_warnings.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

/// §472 шаг 8, раздел 3 спеки — инварианты переезда Xray-JSON на конвейер.
///
/// Снимок `pipeline_identity_before.json` снят СТАРЫМ путём ДО правки
/// (19.09.2026): на каждый вход — тело `emit()`, тег, имя, `rawSource`,
/// identity-хеш, звено цепочки и число отбраковок. Расхождений быть не должно
/// нигде, кроме двух объявленных ниже — и оба требует КОРПУС либо реестр.
const _identityFixture = 'test/fixtures/xray/pipeline_identity_before.json';

Map<String, dynamic> _fixture() =>
    (jsonDecode(File(_identityFixture).readAsStringSync()) as Map)
        .cast<String, dynamic>();

List<NodeSpec> _parse(Object? input, List<NodeWarning> dropped) =>
    parseAll(decode(jsonEncode(input)), dropped: dropped);

/// Вход снимка — ТЕКСТ, а не разобранный объект: порядок ключей входа
/// нормативен, он уезжает в `rawSource` узла байт в байт (§454). Пройди он
/// через `Map`, ключи пересобрались бы, и сверка `rawSource` ловила бы
/// артефакт теста, а не расхождение кода.
List<NodeSpec> _parseText(String body, List<NodeWarning> dropped) =>
    parseAll(decode(body), dropped: dropped);

List<RegistryWarning> _registry(NodeSpec n) =>
    n.warnings.whereType<RegistryWarning>().toList();

RegistryWarning? _codeOf(NodeSpec n, String code) {
  for (final w in _registry(n)) {
    if (w.code == code) return w;
  }
  return null;
}

void main() {

  setUpAll(loadTestRegistry);

  group('§472 инвариант 4 — identity Xray не меняется', () {
    test('оба объявленных расхождения — ровно те, что описаны', () {
      final before = _fixture();

      // 1. Битый путь снят с тела; узел ЖИВ и назван тем же тегом.
      final pathCase =
          (before['vless_ws_path_junk'] as Map).cast<String, dynamic>();
      final pathNodes = _parseText(pathCase['input_json'] as String, []);
      expect(pathNodes, hasLength(1), reason: 'узел обязан выжить');
      final body = pathNodes.first.emit(TemplateVars.empty).map;
      expect((body['transport'] as Map).containsKey('path'), isFalse,
          reason: 'битый путь обязан быть снят с тела: ядро роняет на нём '
              'ВЕСЬ config.json');
      expect(_codeOf(pathNodes.first, 'type_invalid')?.path, 'transport.path',
          reason: 'код приходит из реестра, с адресом поля');
      expect(pathNodes.first.tag,
          ((pathCase['nodes'] as List).first as Map)['tag'],
          reason: 'тег не сдвинулся — сменилось только тело');

      // 2. §477 — негодный `encryption` снимает УЗЕЛ при разборе, и причина
      //    уезжает в `dropped[]` кодом реестра.
      final encCase =
          (before['vless_encryption_junk'] as Map).cast<String, dynamic>();
      final encDropped = <NodeWarning>[];
      final encNodes = _parseText(encCase['input_json'] as String, encDropped);
      expect(encNodes, isEmpty, reason: 'узел обязан исчезнуть при разборе');
      expect(encDropped, hasLength(1));
      final reason = encDropped.first as RegistryWarning;
      expect(reason.code, 'vless_encryption_invalid');
      expect(reason.path, 'encryption');
      expect(reason.value, 'totally-bogus');
      expect(reason.ownerTag, 'proxy',
          reason: 'dropped[].ref контракта называет ТЕГ записи (D-088)');
    });
  });

  group('§477 — отбраковка по форме encryption на Xray-входе', () {
    test('годный ML-KEM доезжает в тело как есть', () {
      const key = 'mlkem768x25519plus.native.0rtt.AAAABBBBCCCCDDDD';
      final nodes = _parse([
        {
          'remarks': 'enc ok',
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
                      {'id': '11111111-2222-3333-4444-555555555555',
                        'encryption': key},
                    ],
                  },
                ],
              },
              'streamSettings': {'network': 'tcp', 'security': 'none'},
            },
          ],
        },
      ], []);
      expect(nodes, hasLength(1));
      expect(nodes.first.emit(TemplateVars.empty).map['encryption'], key);
      expect(_codeOf(nodes.first, 'vless_encryption_invalid'), isNull);
    });

    test('"none" — выключатель слоя: ключа в теле нет, узел жив и без кода',
        () {
      final nodes = _parse([
        {
          'remarks': 'enc none',
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
                      {'id': '11111111-2222-3333-4444-555555555555',
                        'encryption': 'none'},
                    ],
                  },
                ],
              },
              'streamSettings': {'network': 'tcp', 'security': 'none'},
            },
          ],
        },
      ], []);
      expect(nodes, hasLength(1));
      expect(nodes.first.emit(TemplateVars.empty).map.containsKey('encryption'),
          isFalse);
      expect(_registry(nodes.first), isEmpty);
    });

    test('сосед по элементу переживает отбраковку негодного', () {
      // Узел с негодным `encryption` снимается, годный сосед остаётся: одна
      // строка подписки не должна уносить остальные.
      final dropped = <NodeWarning>[];
      final nodes = _parse([
        {
          'remarks': 'mix',
          'outbounds': [
            {
              'tag': 'bad',
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': 'a.example',
                    'port': 443,
                    'users': [
                      {'id': '11111111-2222-3333-4444-555555555555',
                        'encryption': 'nonsense'},
                    ],
                  },
                ],
              },
              'streamSettings': {'network': 'tcp', 'security': 'none'},
            },
            {
              'tag': 'good',
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': 'b.example',
                    'port': 443,
                    'users': [
                      {'id': '22222222-2222-3333-4444-555555555555'},
                    ],
                  },
                ],
              },
              'streamSettings': {'network': 'tcp', 'security': 'none'},
            },
          ],
        },
      ], dropped);
      expect(nodes, hasLength(1));
      expect(nodes.first.emit(TemplateVars.empty).map['server'], 'b.example');
      // §561 — причина только в `dropped[]` подписки, сосед чист.
      expect(_codeOf(nodes.single, 'vless_encryption_invalid'), isNull,
          reason: 'чужая отбраковка на рабочем соседе не висит');
      final w = dropped.whereType<RegistryWarning>().single;
      expect(w.code, 'vless_encryption_invalid',
          reason: 'пропажа узла не должна быть молчаливой');
      expect(w.ownerTag, 'bad',
          reason: 'причина названа тегом ОТВЕРГНУТОЙ записи');
    });
  });

  group('§472 шаг 8 — коды реестра приходят на Xray-узел', () {
    test('мусорный fingerprint даёт utls_fp_unknown с адресом и значением',
        () {
      final nodes = _parse([
        {
          'remarks': 'fp',
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
                      {'id': '11111111-2222-3333-4444-555555555555'},
                    ],
                  },
                ],
              },
              'streamSettings': {
                'network': 'tcp',
                'security': 'tls',
                'tlsSettings': {'serverName': 's.example',
                  'fingerprint': 'bogus-fp'},
              },
            },
          ],
        },
      ], []);
      final w = _codeOf(nodes.single, 'utls_fp_unknown');
      expect(w, isNotNull,
          reason: 'раньше это был рукописный UnknownFingerprintWarning без '
              'адреса и значения');
      expect(w!.path, 'tls.utls.fingerprint');
      expect(w.value, 'bogus-fp');
    });

    test('псевдоним uTLS переводится МОЛЧА — это написание, не мусор', () {
      final nodes = _parse([
        {
          'remarks': 'alias',
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
                      {'id': '11111111-2222-3333-4444-555555555555'},
                    ],
                  },
                ],
              },
              'streamSettings': {
                'network': 'tcp',
                'security': 'tls',
                'tlsSettings': {'serverName': 's.example',
                  'fingerprint': 'hellochrome_120'},
              },
            },
          ],
        },
      ], []);
      final tls = nodes.single.emit(TemplateVars.empty).map['tls'] as Map;
      expect((tls['utls'] as Map)['fingerprint'], 'chrome');
      expect(_codeOf(nodes.single, 'utls_fp_unknown'), isNull);
    });

    test('flow вне пары даёт flow_deprecated с адресом', () {
      final nodes = _parse([
        {
          'remarks': 'flow',
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
                      {'id': '11111111-2222-3333-4444-555555555555',
                        'flow': 'xtls-rprx-direct'},
                    ],
                  },
                ],
              },
              'streamSettings': {'network': 'tcp', 'security': 'none'},
            },
          ],
        },
      ], []);
      final w = _codeOf(nodes.single, 'flow_deprecated');
      expect(w?.path, 'flow');
      expect(w?.value, 'xtls-rprx-direct');
      expect(nodes.single.emit(TemplateVars.empty).map.containsKey('flow'),
          isFalse, reason: 'негодное значение снимается санитайзером');
    });

    test('vision при живом транспорте — код реестра, не рукописный класс', () {
      final nodes = _parse([
        {
          'remarks': 'vision',
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
                      {'id': '11111111-2222-3333-4444-555555555555',
                        'flow': 'xtls-rprx-vision'},
                    ],
                  },
                ],
              },
              'streamSettings': {
                'network': 'ws',
                'security': 'tls',
                'tlsSettings': {'serverName': 's.example'},
                'wsSettings': {'path': '/ws'},
              },
            },
          ],
        },
      ], []);
      expect(_codeOf(nodes.single, 'vision_with_transport'), isNotNull);
      // §472 шаг 9 — `VisionWithTransportWarning` снят совсем (последний
      // производитель ушёл с переездом Xray-входа), и проверять его
      // отсутствие больше нечем: он не компилируется.
    });

    test('битый pbk объясняется кодом, а не молчаливой деградацией', () {
      final nodes = _parse([
        {
          'remarks': 'pbk',
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
                      {'id': '11111111-2222-3333-4444-555555555555'},
                    ],
                  },
                ],
              },
              'streamSettings': {
                'network': 'tcp',
                'security': 'reality',
                'realitySettings': {
                  'serverName': 's.example',
                  'fingerprint': 'chrome',
                  'publicKey': '!!!not-base64!!!',
                  'shortId': 'abcd',
                },
              },
            },
          ],
        },
      ], []);
      final w = _codeOf(nodes.single, 'reality_pbk_invalid');
      expect(w, isNotNull,
          reason: 'раньше REALITY деградировал до plain TLS МОЛЧА (§169)');
      expect(w!.path, 'tls.reality.public_key');
      final tls = nodes.single.emit(TemplateVars.empty).map['tls'] as Map;
      expect(tls.containsKey('reality'), isFalse,
          reason: 'тело не изменилось: блок по-прежнему снимается');
    });

    test('vmess security вне enum даёт vmess_security_unknown', () {
      final nodes = _parse([
        {
          'remarks': 'sec',
          'outbounds': [
            {
              'tag': 'proxy',
              'protocol': 'vmess',
              'settings': {
                'vnext': [
                  {
                    'address': 'v.example',
                    'port': 443,
                    'users': [
                      {'id': '11111111-2222-3333-4444-555555555555',
                        'alterId': 0, 'security': 'rubbish'},
                    ],
                  },
                ],
              },
              'streamSettings': {'network': 'tcp', 'security': 'none'},
            },
          ],
        },
      ], []);
      final w = _codeOf(nodes.single, 'vmess_security_unknown');
      expect(w?.value, 'rubbish',
          reason: 'раньше подмену делал рукописный normalizeVmessSecurity, '
              'и она уходила молча, в лог');
      expect(nodes.single.emit(TemplateVars.empty).map['security'], 'auto');
    });

    test('vmess без security получает обязательный ключ, а не отбраковку', () {
      // `security` у схемы `required` с дефолтом `auto`, а `default` реестра
      // тело не наполняет: опущенный ключ снял бы узел кодом `field_missing`.
      final nodes = _parse([
        {
          'remarks': 'sec empty',
          'outbounds': [
            {
              'tag': 'proxy',
              'protocol': 'vmess',
              'settings': {
                'vnext': [
                  {
                    'address': 'v.example',
                    'port': 443,
                    'users': [
                      {'id': '11111111-2222-3333-4444-555555555555',
                        'alterId': 1},
                    ],
                  },
                ],
              },
              'streamSettings': {'network': 'tcp', 'security': 'none'},
            },
          ],
        },
      ], []);
      expect(nodes, hasLength(1));
      expect(nodes.single.emit(TemplateVars.empty).map['security'], 'auto');
      expect(_registry(nodes.single), isEmpty);
    });
  });

  group('§472 шаг 8 — границы переезда', () {
    test('hysteria2 не получает utls: у QUIC нет TLS-рукопожатия', () {
      // Блок utls снимается, узел живёт — это нормативно и не менялось.
      //
      // Контракт 1.1.28: снимает его САНИТАЙЗЕР по правилу реестра
      // (`tls.json`: `body.fields.utls.forbidden_for` с четырьмя
      // QUIC-схемами), а не маппер, и делает это ОДИНАКОВО на трёх входах —
      // ссылке, JSON-теле и Xray-объекте. Отсюда и код: `tls_not_applicable_quic`
      // уровня info, то есть «поле было, мы его сняли и говорим об этом».
      // Прежняя рукописная ветка молчала, потому что отпечаток читала, но
      // эмитить его было некому; молчание было свойством реализации, а не
      // правилом. Судится ТЕЛО (блока нет) и наличие кода — оба нормативны.
      final nodes = _parse([
        {
          'remarks': 'hy2',
          'outbounds': [
            {
              'tag': 'proxy',
              'protocol': 'hysteria',
              'settings': {'address': 'hy.example', 'port': 8443},
              'streamSettings': {
                'security': 'tls',
                'tlsSettings': {'serverName': 'hy.example',
                  'fingerprint': 'bogus'},
                'hysteriaSettings': {'version': 2, 'auth': 'pw'},
              },
            },
          ],
        },
      ], []);
      final tls = nodes.single.emit(TemplateVars.empty).map['tls'] as Map;
      expect(tls.containsKey('utls'), isFalse);
      expect(_codeOf(nodes.single, 'tls_not_applicable_quic'), isNotNull);
    });

    test('битый ТИП streamSettings пропускает узел, а не оживляет его', () {
      // `streamSettings: "none"` обязан бросить внутри маппера: вызывающий
      // пропускает такой outbound и называет протокол в P5-warning. Мягкое
      // чтение сделало бы из битой записи РАБОЧИЙ узел без транспорта.
      final dropped = <NodeWarning>[];
      final nodes = _parse([
        {
          'remarks': 'malformed',
          'outbounds': [
            {
              'tag': 'bad',
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': 'a.example',
                    'port': 443,
                    'users': [
                      {'id': '11111111-2222-3333-4444-555555555555'},
                    ],
                  },
                ],
              },
              'streamSettings': 'none',
            },
            {
              'tag': 'ok',
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': 'b.example',
                    'port': 443,
                    'users': [
                      {'id': '22222222-2222-3333-4444-555555555555'},
                    ],
                  },
                ],
              },
              'streamSettings': {'network': 'tcp', 'security': 'none'},
            },
          ],
        },
      ], dropped);
      expect(nodes, hasLength(1));
      expect(nodes.single.emit(TemplateVars.empty).map['server'], 'b.example');
      // §561 — пропажа не молчаливая: запись в `dropped[]`, сосед чист.
      expect(nodes.single.warnings, isEmpty);
      expect(
          dropped.whereType<RegistryWarning>().map((w) => w.ownerTag), ['bad']);
    });

    test('§459 — суффикс -udp443 не переписывает порт узла', () {
      final nodes = _parse([
        {
          'remarks': 'udp443',
          'outbounds': [
            {
              'tag': 'proxy',
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': 'h.example',
                    'port': 8443,
                    'users': [
                      {'id': '11111111-2222-3333-4444-555555555555',
                        'flow': 'xtls-rprx-vision-udp443'},
                    ],
                  },
                ],
              },
              'streamSettings': {'network': 'tcp', 'security': 'none'},
            },
          ],
        },
      ], []);
      final body = nodes.single.emit(TemplateVars.empty).map;
      expect(body['server_port'], 8443, reason: 'порт — свойство узла');
      expect(body['flow'], 'xtls-rprx-vision');
      expect(body['packet_encoding'], 'xudp');
    });

    test('§310 — многоузловой элемент даёт все узлы, имена по тегам', () {
      final nodes = _parse([
        {
          'remarks': 'multi',
          'outbounds': [
            for (final t in const ['a', 'b'])
              {
                'tag': t,
                'protocol': 'vless',
                'settings': {
                  'vnext': [
                    {
                      'address': '$t.example',
                      'port': 443,
                      'users': [
                        {'id': '${t == 'a' ? '1' : '2'}1111111-2222-3333-'
                            '4444-555555555555'},
                      ],
                    },
                  ],
                },
                'streamSettings': {'network': 'tcp', 'security': 'none'},
              },
          ],
        },
      ], []);
      expect(nodes.map((n) => n.tag), ['multi a', 'multi b']);
    });

    test('§404 — цепочка dialerProxy жива, релей не стал узлом подписки', () {
      final nodes = _parse([
        {
          'remarks': 'chain',
          'outbounds': [
            {
              'tag': 'proxy',
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': 'a.example',
                    'port': 443,
                    'users': [
                      {'id': '11111111-2222-3333-4444-555555555555'},
                    ],
                  },
                ],
              },
              'streamSettings': {
                'network': 'tcp',
                'security': 'none',
                'sockopt': {'dialerProxy': 'relay'},
              },
            },
            {
              'tag': 'relay',
              'protocol': 'socks',
              'settings': {
                'servers': [
                  {'address': 'r.example', 'port': 1080,
                    'users': [{'user': 'u', 'pass': 'p'}]},
                ],
              },
            },
          ],
        },
      ], []);
      expect(nodes, hasLength(1), reason: 'релей узлом подписки не бывает');
      expect(nodes.single.chained?.tag, 'relay');
      expect(nodes.single.chained?.protocol, 'socks');
    });

    test('§454 — rawSource остаётся объектом Xray байт в байт', () {
      const outbound = {
        'tag': 'proxy',
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {
              'address': 'h.example',
              'port': 443,
              'users': [
                {'id': '11111111-2222-3333-4444-555555555555'},
              ],
            },
          ],
        },
        'streamSettings': {'network': 'tcp', 'security': 'none'},
      };
      final nodes = _parse([
        {'remarks': 'raw', 'outbounds': [outbound]},
      ], []);
      expect(nodes.single.rawSource,
          const JsonEncoder.withIndent('  ').convert(outbound),
          reason: 'карта sing-box — рабочая форма конвейера, а не источник');
      // Ключ `type` в нём отсутствует — по нему проход шага 1 и опознаёт
      // СВОЮ карту, и Xray-узел он по-прежнему не трогает.
      expect(jsonDecode(nodes.single.rawSource) is Map, isTrue);
      expect((jsonDecode(nodes.single.rawSource) as Map).containsKey('type'),
          isFalse);
    });
  });

  group('§472 — второй проход по emit() узла конвейера не дублирует коды', () {
    test('annotateAllWithRegistry на разобранном Xray ничего не добавляет',
        () {
      final nodes = _parse([
        {
          'remarks': 'fp',
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
                      {'id': '11111111-2222-3333-4444-555555555555'},
                    ],
                  },
                ],
              },
              'streamSettings': {
                'network': 'tcp',
                'security': 'tls',
                'tlsSettings': {'serverName': 's.example',
                  'fingerprint': 'bogus-fp'},
              },
            },
          ],
        },
      ], []);
      final before = nodes.single.warnings.length;
      annotateAllWithRegistry(nodes);
      expect(nodes.single.warnings, hasLength(before),
          reason: 'узел помечен isPipelineParsed — источник кодов один');
      // `value` называет написанное автором, а не канонизированное.
      expect(_codeOf(nodes.single, 'utls_fp_unknown')?.value, 'bogus-fp');
    });
  });
}
