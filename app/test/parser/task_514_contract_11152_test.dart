import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/warning_codes.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

import 'engine_test_setup.dart';

/// §514 — ИСПОЛНЕНИЕ КОНТРАКТА 1.1.50–1.1.52.
///
/// Класс дефектов у всех трёх волн один и он не про написание поля: **узел либо
/// терялся целиком, либо уезжал «рабочим» и не соединялся.** Тесты ниже
/// стерегут каждую норму на входе, который эту норму и вскрыл.
///
/// Ключи и адреса — ТЕСТОВЫЕ; формы повторяют живые входы панелей, потому что
/// именно форма и была предметом дефекта.
const _uuid = '11111111-1111-1111-1111-111111111111';

String? _codeOf(NodeWarning w) => warningCodeOf(w);

Set<String> _codes(Iterable<NodeWarning> ws) =>
    {for (final w in ws) _codeOf(w) ?? w.runtimeType.toString()};

/// Один Xray-outbound телом подписки (форма «массив элементов»).
String _xrayBody(Map<String, dynamic> outbound) {
  final o = <String, dynamic>{'tag': 'proxy', ...outbound};
  return '[{"remarks":"t","outbounds":[${_json(o)}]}]';
}

String _json(Object? v) => switch (v) {
      final Map<String, dynamic> m =>
        '{${m.entries.map((e) => '"${e.key}":${_json(e.value)}').join(',')}}',
      final List<dynamic> l => '[${l.map(_json).join(',')}]',
      final String s => '"$s"',
      null => 'null',
      _ => '$v',
    };

/// Тело vless-элемента Xray без транспорта — основа для проб транспорта.
Map<String, dynamic> _vlessSettings() => {
      'protocol': 'vless',
      'settings': {
        'vnext': [
          {
            'address': 'a.example',
            'port': 443,
            'users': [
              {'id': _uuid, 'encryption': 'none'},
            ],
          },
        ],
      },
    };

void main() {
  setUpAll(loadEngineSections);

  // ───────────────────────────────────────────────────────────────────────
  group('3a — `on_invalid: drop transport_unsupported` ИСПОЛНЯЕТСЯ', () {
    // Главный пункт волны 1.1.50 (Q133-17/M-01, D133-49 п.5), и он про
    // ДВИЖОК, а не про таблицу: объявление стояло у `$selector.network` с
    // самого перевода на движок и МОЛЧАЛО. Промах `value_map` означал «вези
    // как пришло», и узел выходил РАБОЧИМ plain-TCP.
    for (final network in const ['kcp', 'quic']) {
      test('Xray-JSON `network: $network` → узла нет, код назван', () {
        final dropped = <NodeWarning>[];
        final nodes = parseAll(
          decode(_xrayBody({
            ..._vlessSettings(),
            'streamSettings': {'network': network, 'security': 'none'},
          })),
          dropped: dropped,
        );

        expect(nodes, isEmpty,
            reason: 'сервер, который ждёт $network, plain-TCP не примет — '
                'узел обязан быть снят, а не уехать голым');
        expect(_codes(dropped), contains('transport_unsupported'),
            reason: 'отбраковка обязана быть НАЗВАННОЙ: молчаливое снятие — '
                'тот же дефект, что и молчаливая подмена');
      });
    }

    test('`allow` — законное имя таблицу ПРОХОДИТ и узел цел', () {
      // Пара к прошлому тесту: без атрибута `allow` «промахом» оказалось бы и
      // законное значение, и `drop` снял бы годный узел.
      for (final network in const ['ws', 'grpc', 'httpupgrade', 'xhttp']) {
        final dropped = <NodeWarning>[];
        final nodes = parseAll(
          decode(_xrayBody({
            ..._vlessSettings(),
            'streamSettings': {'network': network, 'security': 'none'},
          })),
          dropped: dropped,
        );
        expect(nodes, hasLength(1), reason: '$network — канон ядра, не мусор');
        expect(nodes.single.emit(const TemplateVars()).map['transport'],
            isA<Map<String, dynamic>>().having(
                (m) => m['type'], 'type', network));
      }
    });

    test('`tcp`/`raw`/пусто — отсутствие транспорта, а не мусор', () {
      for (final network in const ['tcp', 'raw', '']) {
        final nodes = parseAll(decode(_xrayBody({
          ..._vlessSettings(),
          'streamSettings': {'network': network, 'security': 'none'},
        })));
        expect(nodes, hasLength(1), reason: '«$network» = транспорта нет');
        expect(nodes.single.emit(const TemplateVars()).map['transport'], isNull);
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('3b — обфускация заголовком → отбраковка узла', () {
    // D133-58, решение владельца 24.09.2026. Оба пути: ссылочный и Xray-JSON.
    // Перенести значение в `transport.type: "http"` НЕЛЬЗЯ — у ядра это
    // транспорт HTTP/2, на проводе другой протокол.
    test('URI `headerType=http` → узла нет, код `transport_header_unsupported`',
        () {
      final dropped = XrayDropVerdict();
      final node = parseUri(
        'vless://$_uuid@192.0.2.14:58387'
        '?encryption=none&type=raw&headerType=http&security=none#t',
        dropped: dropped,
      );
      expect(node, isNull,
          reason: 'узел выглядел рабочим и не работал: сервер, ждущий '
              'камуфляж, получал h2-рукопожатие и обрывал соединение');
      expect(_codeOf(dropped.reason!), 'transport_header_unsupported');
    });

    test('URI `type=http` прямым текстом — НАСТОЯЩИЙ H2, узел цел', () {
      // Граница нормы: отбраковывается подделка заголовка, а не транспорт
      // `http`, который у ядра как раз есть.
      final node = parseUri(
        'vless://$_uuid@192.0.2.14:443?encryption=none&type=http&security=tls'
        '&host=cdn.example#t',
      );
      expect(node, isNotNull);
      final tr = node!.emit(const TemplateVars()).map['transport']
          as Map<String, dynamic>?;
      expect(tr?['type'], 'http');
    });

    for (final spelling in const ['tcpSettings', 'rawSettings']) {
      test('Xray-JSON `$spelling.header.type = http` → узла нет', () {
        // Два написания источника: имя Xray до переименования и после
        // (апстрим #3994) — панели пишут оба.
        final dropped = <NodeWarning>[];
        final nodes = parseAll(
          decode(_xrayBody({
            ..._vlessSettings(),
            'streamSettings': {
              'network': 'tcp',
              'security': 'none',
              spelling: {
                'header': {'type': 'http'},
              },
            },
          })),
          dropped: dropped,
        );
        expect(nodes, isEmpty,
            reason: 'прежде форма терялась АБСОЛЮТНО МОЛЧА: узел собирался '
                'чистым TCP');
        expect(_codes(dropped), contains('transport_header_unsupported'));
      });
    }

    test('`header.type = none` — отсутствие обфускации, кода нет', () {
      final dropped = <NodeWarning>[];
      final nodes = parseAll(
        decode(_xrayBody({
          ..._vlessSettings(),
          'streamSettings': {
            'network': 'tcp',
            'security': 'none',
            'tcpSettings': {
              'header': {'type': 'none'},
            },
          },
        })),
        dropped: dropped,
      );
      expect(nodes, hasLength(1));
      expect(_codes(nodes.single.warnings),
          isNot(contains('transport_header_unsupported')));
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('3c — неизвестный ключ ВНУТРИ объявленных контейнеров', () {
    // D133-59. Контейнеры стоят в `unknown_key.ignore`, потому что их листья
    // читают записи таблицы, и следствие оказалось хуже болезни: всё, что
    // лежало внутри и не названо ни одним `source`, терялось МОЛЧА.
    test('лист внутри контейнера → info-код с ПОЛНЫМ путём', () {
      final nodes = parseAll(decode(_xrayBody({
        ..._vlessSettings(),
        'streamSettings': {
          'network': 'ws',
          'security': 'none',
          'wsSettings': {'path': '/x', 'zzzUnknown': 'v'},
        },
      })));
      expect(nodes, hasLength(1),
          reason: 'непрочитанный лист узел НЕ ломает — он лишь не доезжает');
      final w = nodes.single.warnings
          .where((w) => _codeOf(w) == 'json_field_unknown')
          .toList();
      expect(w.map((e) => (e as RegistryWarning).path),
          contains('streamSettings.wsSettings.zzzUnknown'));
    });

    test('контейнер-РОДИТЕЛЬ неизвестным не зовётся', () {
      // Путь внутреннего объекта — лишь дорога к листьям, и звать неизвестным
      // `streamSettings.wsSettings` значило бы ругаться на контейнер, чьи
      // листья секция как раз читает.
      final nodes = parseAll(decode(_xrayBody({
        ..._vlessSettings(),
        'streamSettings': {
          'network': 'ws',
          'security': 'none',
          'wsSettings': {'path': '/x'},
        },
      })));
      final paths = nodes.single.warnings
          .whereType<RegistryWarning>()
          .where((w) => w.code == 'json_field_unknown')
          .map((w) => w.path)
          .toSet();
      expect(paths, isNot(contains('streamSettings.wsSettings')));
      expect(paths, isNot(contains('streamSettings')));
    });

    test('`nested_quiet` — поддерево `sockopt` молчит целиком', () {
      // При ЧАСТИЧНОМ объявлении листьев код на остальных был бы шумом.
      final nodes = parseAll(decode(_xrayBody({
        ..._vlessSettings(),
        'streamSettings': {
          'network': 'tcp',
          'security': 'none',
          'sockopt': {'tcpNoDelay': true, 'zzzWhatever': 7},
        },
      })));
      final paths = nodes.single.warnings
          .whereType<RegistryWarning>()
          .where((w) => w.code == 'json_field_unknown')
          .map((w) => w.path)
          .toList();
      expect(paths.where((p) => p?.startsWith('streamSettings.sockopt') ?? false),
          isEmpty,
          reason: 'sockopt объявлен nested_quiet у всех девяти xray-секций');
    });

    test('путь-родитель: запись, читающая объект ЦЕЛИКОМ, читает и листья', () {
      // `wsSettings.headers` объявлена с `type: object`, и перечислить листья
      // она не может — их имена принадлежат подписке.
      final nodes = parseAll(decode(_xrayBody({
        ..._vlessSettings(),
        'streamSettings': {
          'network': 'ws',
          'security': 'none',
          'wsSettings': {
            'path': '/x',
            'headers': {'Host': 'cdn.example', 'X-Anything': 'v'},
          },
        },
      })));
      final paths = nodes.single.warnings
          .whereType<RegistryWarning>()
          .where((w) => w.code == 'json_field_unknown')
          .map((w) => w.path)
          .toList();
      expect(paths.where((p) => p?.contains('headers') ?? false), isEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('3d — баннер-обманка панели опознаётся по ЦЕЛИ', () {
    // D133-55. Прежде признаком баннера было ОТСУТСТВИЕ `://`, и обе крупные
    // панели проходили насквозь, становясь полноценным узлом-пустышкой.
    test('`vless://…@0.0.0.0:1#expired` среди строк → узла нет, info-код', () {
      final body = [
        'vless://$_uuid@example-1.com:443?encryption=none&security=none#node-a',
        'vless://00000000-0000-0000-0000-000000000000@0.0.0.0:1'
            '?encryption=none&security=none#%E2%9A%A0%20Subscription%20expired',
      ].join('\n');
      final dropped = <NodeWarning>[];
      final nodes = parseAll(decode(body), dropped: dropped);

      expect(nodes, hasLength(1), reason: 'сосед обязан остаться на месте');
      expect(nodes.single.server, 'example-1.com');
      expect(_codes(dropped), contains('provider_banner_link'));
    });

    test('баннер ЕДИНСТВЕННОЙ записью тела: узлов нет, причина названа', () {
      // При expired/depleted 3x-ui возвращает его вместо всего состава, и
      // подписка выглядела РАБОЧЕЙ и ОДНОУЗЛОВОЙ.
      final dropped = <NodeWarning>[];
      final nodes = parseAll(
        decode('socks://127.0.0.1:1080#Subscription%20expired'),
        dropped: dropped,
      );
      expect(nodes, isEmpty);
      expect(_codes(dropped), contains('provider_banner_link'));
    });

    test('ремарка после `#` доживает до человека сообщением провайдера', () {
      // `message_from: fragment` — она и есть единственное содержимое баннера.
      final dropped = XrayDropVerdict();
      final node = parseUri('socks://127.0.0.1:1080#Traffic%20limit%20reached',
          dropped: dropped);
      expect(node, isNull);
      final w = dropped.reason!;
      expect(w.code, 'provider_banner_link');
      expect(w.params['message'], 'Traffic limit reached');
    });

    test('ПОРТ признаком НЕ является — судится только адрес', () {
      // У 3x-ui порт законный 1080, доказывает адрес.
      for (final target in const ['0.0.0.0', '127.0.0.1', '[::1]', 'localhost']) {
        expect(parseUri('socks://$target:1080#x'), isNull,
            reason: '$target сервером не бывает ни при какой схеме');
      }
      // Обратная граница: законный адрес с тем же портом — узел.
      expect(parseUri('socks://example-1.com:1#x'), isNotNull,
          reason: 'порт 1 сам по себе баннера не доказывает');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('3e — socks `decode_requires_separator`', () {
    // D133-56. Признак работает В ОБЕ СТОРОНЫ, и обе половины обязательны.
    test('base64(«user:pass») — пароль больше НЕ теряется', () {
      // v2rayN пишет socks-ссылку так ВСЕГДА, а реестр резал строку по `:`,
      // которого в ней нет: username становился всей base64-строкой.
      final node = parseUri(
          'socks5://dGVzdHVzZXI6dGVzdHBhc3MxMjM@example-1.com:1080#s5');
      final body = node!.emit(const TemplateVars()).map;
      expect(body['username'], 'testuser');
      expect(body['password'], 'testpass123');
    });

    test('пароль с двоеточием ВНУТРИ — `limit: 2` его ловит', () {
      final node = parseUri(
          'socks5://dGVzdHVzZXI6cGE6c3MxMjM@example-2.com:1080#s5c');
      final body = node!.emit(const TemplateVars()).map;
      expect(body['username'], 'testuser');
      expect(body['password'], 'pa:ss123');
    });

    test('ВТОРАЯ ПОЛОВИНА признака: открытое одиночное имя не ломается', () {
      // `useridonly` есть законный userid версии 4 (пароля у неё нет по
      // протоколу), но он проходит RawStdEncoding и уехал бы мусором.
      final node = parseUri('socks4://useridonly@example-1.com:1080#s4');
      final body = node!.emit(const TemplateVars()).map;
      expect(body['username'], 'useridonly');
      expect(body['password'], isNull);
    });

    test('разделитель ВО ВХОДЕ снимает конвейер: форма открытая', () {
      final node = parseUri('socks5://user1:pass1@example-1.com:1080#open');
      final body = node!.emit(const TemplateVars()).map;
      expect(body['username'], 'user1');
      expect(body['password'], 'pass1');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('3f — слой `extra` у vmess приезжает УЖЕ ОБЪЕКТОМ', () {
    // D133-57. Marzban кладёт `extra` вложенным объектом, и значение до слоя
    // не доезжало вовсе: `xmux` вместе со sc*-полями терялся МОЛЧА.
    test('объект внутри контейнера: xmux и x_padding_bytes доезжают', () {
      // Тот же вход, что у корпусного кейса `xhttp_extra_object_xmux`.
      const uri = 'vmess://eyJhZGQiOiAiZXhhbXBsZS0xLmNvbSIsICJhaWQiOiAiMCIsICJl'
          'eHRyYSI6IHsibm9HUlBDSGVhZGVyIjogdHJ1ZSwgInNjTWF4RWFjaFBvc3RCeXRlcyI6'
          'ICI4MDAwMDAiLCAieFBhZGRpbmdCeXRlcyI6ICIxMDAtMTAwMCIsICJ4bXV4IjogeyJo'
          'S2VlcEFsaXZlUGVyaW9kIjogNDUsICJtYXhDb25jdXJyZW5jeSI6ICI4LTE2In19LCAi'
          'aG9zdCI6ICJleGFtcGxlLTEuY29tIiwgImlkIjogIjExMTExMTExLTExMTEtMTExMS0x'
          'MTExLTExMTExMTExMTExMSIsICJuZXQiOiAieGh0dHAiLCAicGF0aCI6ICIveGh0dHAi'
          'LCAicG9ydCI6ICI0NDMiLCAicHMiOiAidm1lc3MtZXh0cmEteG11eCIsICJzY3kiOiAi'
          'YXV0byIsICJzbmkiOiAiZXhhbXBsZS0xLmNvbSIsICJ0bHMiOiAidGxzIiwgInR5cGUi'
          'OiAic3RyZWFtLW9uZSIsICJ2IjogIjIifQ==';
      final node = parseUri(uri);
      expect(node, isNotNull);
      final tr = node!.emit(const TemplateVars()).map['transport']
          as Map<String, dynamic>;
      expect(tr['x_padding_bytes'], '100-1000');
      expect(tr['sc_max_each_post_bytes'], '800000');
      expect(tr['xmux'], isA<Map<String, dynamic>>());
      expect((tr['xmux'] as Map)['max_concurrency'], '8-16');
    });

    test('ключ-НОСИТЕЛЬ слоя неизвестным не зовётся', () {
      // Именно из него узел и наполнился: без отметки о чтении ключ попадал
      // и в `uri_param_unknown`, и в `unknown_key`.
      const uri = 'vmess://eyJhZGQiOiAiZXhhbXBsZS0xLmNvbSIsICJhaWQiOiAiMCIsICJl'
          'eHRyYSI6IHsibm9HUlBDSGVhZGVyIjogdHJ1ZX0sICJpZCI6ICIxMTExMTExMS0xMTEx'
          'LTExMTEtMTExMS0xMTExMTExMTExMTEiLCAibmV0IjogInhodHRwIiwgInBvcnQiOiAi'
          'NDQzIiwgInBzIjogInQiLCAic2N5IjogImF1dG8iLCAidGxzIjogIiIsICJ2IjogIjIi'
          'fQ==';
      final node = parseUri(uri);
      final codes = _codes(node!.warnings);
      expect(codes, isNot(contains('uri_param_unknown')));
      expect(codes, isNot(contains('unknown_key')));
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('3g — hysteria2 `up`/`down` через `bandwidth_mbps`', () {
    test('написание официального клиента + суффикс единицы', () {
      // `up=100&down=500` давало ДВА `uri_param_unknown`, и полоса терялась
      // молча (D-8 аудита панелей).
      final node =
          parseUri('hysteria2://pw@example-1.com:443?up=100mbps&down=500#h2');
      final body = node!.emit(const TemplateVars()).map;
      expect(body['up_mbps'], 100);
      expect(body['down_mbps'], 500);
      expect(_codes(node.warnings), isNot(contains('uri_param_unknown')));
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('3h — нестроковый элемент списка снимается ЭЛЕМЕНТОМ', () {
    // D133-51, решение владельца 24.09.2026, согласовано с §510 M1. У нас это
    // уже так (7f915b73); волна 1.1.50 отменила прежнюю норму, снимавшую поле
    // ЦЕЛИКОМ, и назвала отдельно две границы.
    //
    // Форма входа — та же, что у кейса корпуса `tls_alpn_item_nonstring`:
    // ГОЛЫЙ массив outbound'ов sing-box.
    String singboxOutbounds(List<Map<String, dynamic>> list) => _json(list);

    test('код ставится НА ЭЛЕМЕНТ, а поле остаётся', () {
      // `443` не идентификатор ALPN. Причину называет код элемента
      // (`tls.alpn[0]`), и второго кода о ПОЛЕ (`type_invalid`) быть не должно:
      // он сообщал бы то же самое во второй раз и звучал бы как «поле снято».
      final nodes = parseAll(decode(singboxOutbounds([
        {
          'type': 'vless',
          'tag': 'alpn-mixed',
          'server': 'example-1.com',
          'server_port': 443,
          'uuid': _uuid,
          'tls': {
            'enabled': true,
            'server_name': 'example-1.com',
            'alpn': [443, 'h2'],
          },
        },
      ])));
      expect(nodes, hasLength(1), reason: 'узел остаётся — снят ЭЛЕМЕНТ');
      final codes = nodes.single.warnings.whereType<RegistryWarning>().toList();
      expect(codes.map((w) => w.code), contains('tls_alpn_item_invalid'));
      expect(codes.firstWhere((w) => w.code == 'tls_alpn_item_invalid').path,
          'tls.alpn[0]',
          reason: 'адрес кода — ЭЛЕМЕНТ по индексу, а не поле');
      expect(codes.map((w) => w.code), isNot(contains('type_invalid')),
          reason: 'норма 1.1.49, снимавшая поле целиком, ОТМЕНЕНА');
    });

    test('все элементы негодны — пустой остаток, и это НЕ `type_invalid`', () {
      // Граница названа отдельно: пустой остаток = отсутствие значения, а
      // причину уже назвал код на элементе.
      final nodes = parseAll(decode(singboxOutbounds([
        {
          'type': 'vless',
          'tag': 'alpn-all-bad',
          'server': 'example-2.com',
          'server_port': 443,
          'uuid': _uuid,
          'tls': {
            'enabled': true,
            'server_name': 'example-2.com',
            'alpn': [443],
          },
        },
      ])));
      expect(nodes, hasLength(1));
      final codes = nodes.single.warnings
          .whereType<RegistryWarning>()
          .map((w) => w.code)
          .toList();
      expect(codes, contains('tls_alpn_item_invalid'));
      expect(codes, isNot(contains('type_invalid')));
    });
  });

  group('3i — `emit.userinfo.keep_empty_tail` ИСПОЛНЯЕТСЯ', () {
    // D133-54, Q133-74, решение владельца: обе стороны с контракта 1.1.50.
    test('socks4: разделитель пишется и при пустом пароле', () {
      final node = parseUri('socks4://userid1@example-1.com:1080#s4');
      expect(node!.toUri(), 'socks4://userid1:@example-1.com:1080#s4',
          reason: 'отсутствие `:` часть клиентов читает как «имени нет»');
    });

    test('круг: ссылка с `:@` возвращает тело БЕЗ пароля', () {
      final node = parseUri('socks4://userid1:@example-1.com:1080#s4');
      final body = node!.emit(const TemplateVars()).map;
      expect(body['username'], 'userid1');
      expect(body['password'], isNull);
      expect(node.toUri(), 'socks4://userid1:@example-1.com:1080#s4');
    });

    test('socks5 с паролем флагом не затронут', () {
      final node = parseUri('socks5://u:p@example-1.com:1080#s5');
      expect(node!.toUri(), 'socks5://u:p@example-1.com:1080#s5');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('3k — `default` группы selector (§565: род исполняется)', () {
    // D133-53 → §565. Род selector больше не сводится к urltest: `default`
    // активное поле рода.
    test('импорт selector: род selector, кода нет, `default` СОХРАНЁН', () {
      final nodes = parseAll(decode(_json({
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'n1',
            'server': 'a.example',
            'server_port': 443,
            'uuid': _uuid,
          },
          {
            'type': 'vless',
            'tag': 'n2',
            'server': 'b.example',
            'server_port': 443,
            'uuid': _uuid,
          },
          {
            'type': 'selector',
            'tag': 'my-group',
            'outbounds': ['n1', 'n2'],
            'default': 'n2',
          },
        ],
      })));

      final group = nodes.whereType<AutoSelectSpec>().single;
      expect(_codes(group.warnings), isNot(contains('selector_as_auto')),
          reason: 'род selector исполняется — сводить нечего');
      expect(group.genus, 'selector');
      expect(group.manualDefault, 'n2',
          reason: 'ИМЯ ЧЛЕНА, выбранного вручную, обязано дожить в модели');
    });

    test('тело selector несёт `default` и состав', () {
      // Ядро декодирует с DisallowUnknownFields: `default` допустим только
      // при `type: selector`.
      final nodes = parseAll(decode(_json({
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'n1',
            'server': 'a.example',
            'server_port': 443,
            'uuid': _uuid,
          },
          {
            'type': 'selector',
            'tag': 'g',
            'outbounds': ['n1'],
            'default': 'n1',
          },
        ],
      })));
      final group = nodes.whereType<AutoSelectSpec>().single;
      final body = group.emitRaw(const TemplateVars()).map;
      expect(body['type'], 'selector');
      expect(body['default'], 'n1');
      expect(body['outbounds'], ['n1']);
      expect(body.containsKey('url'), isFalse,
          reason: 'параметров замера у ручного рода нет');
    });

    test('группа БЕЗ `default` несёт пустую строку, а не мусор', () {
      final nodes = parseAll(decode(_json({
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'n1',
            'server': 'a.example',
            'server_port': 443,
            'uuid': _uuid,
          },
          {
            'type': 'urltest',
            'tag': 'g',
            'outbounds': ['n1'],
          },
        ],
      })));
      expect(nodes.whereType<AutoSelectSpec>().single.manualDefault, '');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('3l — `tlsSettings.alpn` → `tls.alpn` (D133-C9 отменена)', () {
    // ALPN есть часть РУКОПОЖАТИЯ: сервер, которому нечего выбрать из
    // предложенного, соединение обрывает — узел с h2-only сервером НЕ РАБОТАЛ.
    test('массивом — доезжает с ОБЩЕГО блока', () {
      final nodes = parseAll(decode(_xrayBody({
        ..._vlessSettings(),
        'streamSettings': {
          'network': 'tcp',
          'security': 'tls',
          'tlsSettings': {
            'serverName': 'a.example',
            'alpn': ['h2'],
          },
        },
      })));
      final tls =
          nodes.single.emit(const TemplateVars()).map['tls'] as Map<String, dynamic>;
      expect(tls['alpn'], ['h2']);
    });

    test('строкой через запятую — в массив', () {
      final nodes = parseAll(decode(_xrayBody({
        ..._vlessSettings(),
        'streamSettings': {
          'network': 'tcp',
          'security': 'tls',
          'tlsSettings': {'serverName': 'a.example', 'alpn': 'h2,http/1.1'},
        },
      })));
      final tls =
          nodes.single.emit(const TemplateVars()).map['tls'] as Map<String, dynamic>;
      expect(tls['alpn'], ['h2', 'http/1.1']);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('3m — новые `mappers.xray`: поля доезжают', () {
    // Волна 1.1.50 привезла три секции; у нас `protocol: "wireguard"` не
    // опознавался НИ ОДНОЙ секцией и узел пропадал целиком.
    test('`protocol: wireguard` — узел, а не «протокол не поддержан»', () {
      final dropped = <NodeWarning>[];
      final nodes = parseAll(
        decode(_xrayBody({
          'protocol': 'wireguard',
          'settings': {
            'secretKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
            'address': ['10.0.0.2/32'],
            'peers': [
              {
                'endpoint': 'wg.example:51820',
                'publicKey': 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=',
                'allowedIPs': ['0.0.0.0/0'],
              },
            ],
          },
        })),
        dropped: dropped,
      );
      expect(nodes, hasLength(1),
          reason: 'все целевые поля у ядра есть — узел терялся зря');
      final body = nodes.single.emit(const TemplateVars()).map;
      expect(body['type'], 'wireguard');
    });

    test('`protocol: http` — пара user/pass и карта заголовков', () {
      final nodes = parseAll(decode(_xrayBody({
        'protocol': 'http',
        'settings': {
          'servers': [
            {
              'address': '192.0.2.20',
              'port': 8080,
              'users': [
                {'user': 'testuser', 'pass': 'testpass123'},
              ],
            },
          ],
        },
      })));
      final body = nodes.single.emit(const TemplateVars()).map;
      expect(body['username'], 'testuser');
      expect(body['password'], 'testpass123');
    });

    test('`mux` элемента читается СЕКЦИЕЙ: узел цел, ключ не «неизвестный»', () {
      // Блок `multiplex#xray` приехал волной 1.1.50 и подключён `include` у
      // четырёх схем. МОДЕЛИ узла поля `multiplex` у нас нет вовсе (в
      // `contract/schema/node.schema.json` его тоже нет), поэтому значение до
      // тела не доезжает — но ключ ОБЪЯВЛЕН, и «неизвестным» он не считается.
      // Перенос самого поля в модель — отдельная задача, к синку 1.1.52
      // отношения не имеющая: она меняет тела живых узлов четырёх схем.
      final nodes = parseAll(decode(_xrayBody({
        ..._vlessSettings(),
        'streamSettings': {'network': 'tcp', 'security': 'none'},
        'mux': {
          'enabled': true,
          'concurrency': 8,
          'xudpConcurrency': 16,
          'xudpProxyUDP443': 'reject',
        },
      })));
      expect(nodes, hasLength(1));
      final paths = nodes.single.warnings
          .whereType<RegistryWarning>()
          .where((w) => w.code == 'json_field_unknown')
          .map((w) => w.path)
          .toList();
      expect(paths.where((p) => p?.startsWith('mux') ?? false), isEmpty,
          reason: 'все четыре листа `mux` объявлены блоком multiplex#xray — '
              'до 1.1.50 секции у них не было и они молчали потерей');
    });

    test('`concurrency: -1` НЕ даёт `type_invalid`', () {
      // У Xray отрицательное значение и ноль значат «mux выключен» (а не «без
      // предела», как читает ноль ядро), и реестр снимает блок целиком через
      // `sets: null`. Прежде ветка стирала блок, а запись тут же писала своё
      // число обратно — и санитайзер ругался на отрицательное значение.
      final nodes = parseAll(decode(_xrayBody({
        ..._vlessSettings(),
        'streamSettings': {'network': 'tcp', 'security': 'none'},
        'mux': {'enabled': true, 'concurrency': -1},
      })));
      expect(nodes, hasLength(1));
      expect(_codes(nodes.single.warnings), isNot(contains('type_invalid')),
          reason: 'это не «число вне границ», а «блока нет вовсе»');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('3n — предел длины ссылки', () {
    test('канон 65536: длинная валидная ссылка принимается', () {
      // Расхождение сторон закрыто волной 1.1.50 (у лаунчера было 8192).
      final pad = 'a' * 9000;
      final node = parseUri(
          'vless://$_uuid@example-1.com:443?encryption=none&security=none#$pad');
      expect(node, isNotNull);
    });

    test('за пределом — `uri_too_long`, а не молчание', () {
      final dropped = XrayDropVerdict();
      final node = parseUri(
        'vless://$_uuid@example-1.com:443?encryption=none#${'a' * 70000}',
        dropped: dropped,
      );
      expect(node, isNull);
      expect(_codeOf(dropped.reason!), 'uri_too_long');
    });
  });
}
