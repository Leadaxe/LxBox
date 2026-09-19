import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/parse_warnings.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

/// §472 шаг 8, раздел 3 спеки — инварианты переезда Xray-JSON на конвейер.
///
/// Снимок `pipeline_identity_before.json` снят СТАРЫМ путём ДО правки
/// (19.09.2026): на каждый вход — тело `emit()`, тег, имя, `rawSource`,
/// identity-хеш, звено цепочки и число отбраковок. Расхождений быть не должно
/// нигде, кроме двух объявленных ниже (см. [_expectedChanges]) — и оба
/// требует КОРПУС либо реестр.
const _contractRoot = 'contract';
const _identityFixture = 'test/fixtures/xray/pipeline_identity_before.json';

/// Единственные два расхождения со снимком, оба — исправление дефекта.
///
/// Всё остальное обязано совпасть побуквенно: тег И ЕСТЬ identity
/// (`node_hash.dart`), и сдвиг у живого узла означает слетевшие выбор узла,
/// отключения и цепочки.
const Map<String, String> _expectedChanges = {
  // Битый percent-путь транспорта (`/bad%zz`) ТЕПЕРЬ СНИМАЕТСЯ С ТЕЛА, как
  // требует корпус (`uri/trojan/ws_path_broken_percent_kept`: поле снято,
  // код `type_invalid`, узел жив). Ядро на таком пути роняет ВЕСЬ
  // config.json («ws: parse path: invalid URL escape»), то есть прежнее тело
  // Xray-узла уносило с собой весь VPN. На входе ссылки правило работало с
  // шага 2, на Xray-входе — не работало вовсе: судьи там не было.
  'vless_ws_path_junk': 'битый путь снят с тела (format url_path), узел жив',
  // §477 — негодная форма `vless.encryption` ТЕПЕРЬ ОТБРАКОВЫВАЕТ УЗЕЛ при
  // разборе, а не только на сборке. Ровно то, что заметка шага 8 и обещала:
  // правило `on_invalid: drop_node` уже было в реестре, но исполнял его
  // проход по дословной карте, которой у Xray-узла не существовало.
  'vless_encryption_junk': 'узел отбракован при разборе (drop_node §477)',
  // §480 — дефолт порта 443 на Xray-входе СНЯТ по арбитру, исходникам
  // XTLS/Xray-core (решение владельца 19.09.2026). Дефолта порта у Xray нет
  // ни у одного outbound-протокола: trojan и shadowsocks отбраковывают
  // элемент явно («Invalid Trojan port.», infra/conf/trojan.go:67-69), а
  // vless/vmess/socks/http порт не проверяют вовсе (infra/conf/vless.go:
  // 274-283) и собирают узел с нулём, падающий при первом дозвоне. Рабочего
  // узла из элемента без порта Xray не делает ни в одной ветке — наш дефолт
  // был единственным поведением, придумывавшим узел, которого провайдер не
  // присылал. Теперь работает `required: true` записи `port` реестра, и
  // элемент отбраковывается той же записью и с тем же текстом, что у
  // лаунчера.
  'vless_default_port': 'delta480: дефолт 443 снят по арбитру Xray — было: '
      'узел на 443; стало: ноль узлов и одна отбраковка '
      '(server port is missing or out of range)',
};

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
  final synced = Directory('$_contractRoot/registry').existsSync();
  final skip = synced ? null : 'контракт не синхронизирован';

  setUpAll(() async {
    if (!synced) return;
    await ContractRegistry.I.loadFromDirectory(_contractRoot);
  });

  group('§472 инвариант 4 — identity Xray не меняется', () {
    test('каждый вход снимка даёт прежние хеш, тег, имя, rawSource и тело',
        () {
      final before = _fixture();
      expect(before, hasLength(greaterThan(40)),
          reason: 'снимок похудел — проверьте, не срезан ли набор входов');

      for (final e in before.entries) {
        final name = e.key;
        final want = (e.value as Map).cast<String, dynamic>();
        final wantNodes = (want['nodes'] as List).cast<Map>();
        final dropped = <NodeWarning>[];
        final got = _parseText(want['input_json'] as String, dropped);

        if (_expectedChanges.containsKey(name)) continue;

        expect(got, hasLength(wantNodes.length),
            reason: 'число узлов входа $name изменилось');
        for (var i = 0; i < wantNodes.length; i++) {
          final w = wantNodes[i].cast<String, dynamic>();
          final n = got[i];
          expect(legacyNodeIdentityHash(n), w['identity'],
              reason: 'identity $name[$i] изменилась: у пользователей слетят '
                  'выбор узла, отключения и цепочки');
          expect(n.tag, w['tag'], reason: 'тег $name[$i]');
          expect(n.label, w['label'], reason: 'имя $name[$i]');
          // §454 — `rawSource` Xray-узла остаётся pretty-print ИСХОДНОГО
          // объекта Xray байт в байт; карта sing-box это рабочая форма
          // конвейера, а не то, что прислал провайдер.
          expect(n.rawSource, w['rawSource'], reason: 'rawSource $name[$i]');
          // Тело сверяется ТЕКСТОМ: порядок ключей нормативен, golden
          // сравнивается байт в байт (13.7), и пересборка через `Map`
          // спрятала бы сдвиг.
          expect(jsonEncode(n.emit(TemplateVars.empty).map), w['body_json'],
              reason: 'тело $name[$i] (порядок ключей нормативен — golden '
                  'сравнивается байт в байт)');
          final wantChain = w['chained'];
          if (wantChain == null) {
            expect(n.chained, isNull, reason: 'звено $name[$i] появилось');
          } else {
            expect(n.chained, isNotNull, reason: 'звено $name[$i] пропало');
            expect(legacyNodeIdentityHash(n.chained!),
                (wantChain as Map)['identity'],
                reason: 'identity звена $name[$i]');
            expect(n.chained!.tag, wantChain['tag'],
                reason: 'тег звена $name[$i]');
          }
        }
        expect(dropped, hasLength(want['dropped']),
            reason: 'число отбраковок входа $name изменилось');
      }
    }, skip: skip);

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
    }, skip: skip);
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
    }, skip: skip);

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
    }, skip: skip);

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
      // §404 P3 — причина висит на СОСЕДЕ по элементу и из подписочного
      // списка убирается: иначе человек прочёл бы одно сообщение дважды.
      // В `dropped[]` она остаётся только когда носителя не нашлось.
      expect(dropped, isEmpty);
      final carried = _codeOf(nodes.single, 'vless_encryption_invalid');
      expect(carried, isNotNull,
          reason: 'пропажа узла не должна быть молчаливой');
      expect(carried!.ownerTag, 'bad',
          reason: 'причина названа тегом ОТВЕРГНУТОЙ записи, не носителя');
    }, skip: skip);
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
    }, skip: skip);

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
    }, skip: skip);

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
    }, skip: skip);

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
    }, skip: skip);

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
    }, skip: skip);

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
    }, skip: skip);

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
    }, skip: skip);
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
    }, skip: skip);

    test('битый ТИП streamSettings пропускает узел, а не оживляет его', () {
      // `streamSettings: "none"` обязан бросить внутри маппера: вызывающий
      // пропускает такой outbound и называет протокол в P5-warning. Мягкое
      // чтение сделало бы из битой записи РАБОЧИЙ узел без транспорта.
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
      ], []);
      expect(nodes, hasLength(1));
      expect(nodes.single.emit(TemplateVars.empty).map['server'], 'b.example');
      expect(nodes.single.warnings.whereType<UnsupportedProtocolWarning>(),
          hasLength(1));
    }, skip: skip);

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
    }, skip: skip);

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
    }, skip: skip);

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
    }, skip: skip);

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
    }, skip: skip);
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
    }, skip: skip);
  });

  group('§472 инвариант 5 — цена разбора 2000 Xray-узлов', () {
    test('конвейер не дороже ×1,5 к старой полной воронке', () {
      // Замер «лучший из трёх»: `flutter test -j 2` гоняет перф-тесты
      // параллельно, и первый замер под соседом растягивается (шаг 3).
      final element = {
        'remarks': 'perf',
        'outbounds': [
          for (var i = 0; i < 2000; i++)
            {
              'tag': 'n$i',
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': 'h$i.example',
                    'port': 443,
                    'users': [
                      {'id': '11111111-2222-3333-4444-555555555555',
                        'flow': 'xtls-rprx-vision'},
                    ],
                  },
                ],
              },
              'streamSettings': {
                'network': 'tcp',
                'security': 'reality',
                'realitySettings': {
                  'serverName': 's$i.example',
                  'fingerprint': 'chrome',
                  'publicKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
                  'shortId': 'abcd',
                },
              },
            },
        ],
      };
      final body = jsonEncode([element]);

      var best = Duration(days: 1);
      for (var run = 0; run < 3; run++) {
        final sw = Stopwatch()..start();
        final nodes = parseAll(decode(body));
        sw.stop();
        expect(nodes, hasLength(2000));
        if (sw.elapsed < best) best = sw.elapsed;
      }
      // Потолок щедрый и намеренно не привязан к железу: тест ловит
      // ПОРЯДОК величины, а не микросекунды. Шаг 3 мерил ту же форму на
      // ссылке: старая полная воронка vless ~222 мс, конвейер ~216 мс.
      expect(best.inMilliseconds, lessThan(3000),
          reason: 'разбор 2000 Xray-узлов занял ${best.inMilliseconds} мс');
      // ignore: avoid_print
      print('§472 шаг 8: 2000 Xray-узлов — ${best.inMilliseconds} мс '
          '(лучший из трёх)');
    }, skip: skip);
  });
}
