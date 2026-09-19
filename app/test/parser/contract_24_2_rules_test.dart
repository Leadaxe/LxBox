import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/transport_spec.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

// §463 — целевые правила контракта §24.2/§24.6, принятые владельцем
// 18.09.2026. Корпус (test/contract/) нормирует их там, где у лаунчера есть
// фикстура; здесь — правила, фикстуры под которые в корпусе нет, и границы,
// которые корпус не трогает (эмит share-URI, sing-box-JSON вход).
//
// 7.3 (naive одиночный userinfo = password) сюда НЕ входит: дата
// одновременной правки обеих сторон — 24.09.2026.

/// Коды предупреждений узла (реестровые несут код полем).
List<String> _codes(NodeSpec spec) => [
      for (final w in spec.warnings)
        if (w is RegistryWarning) w.code else w.runtimeType.toString(),
    ];

void main() {
  // §472 шаг 2 — правила §24.6 для trojan исполняет РЕЕСТР (`format:
  // url_path`), а не рукописный guard в парсере: без загруженного реестра
  // судить значение стало нечем. В приложении он загружается на старте
  // (`main.dart`), здесь — так же явно.
  //
  // §472 шаг 3 — загрузка под гейтом `existsSync`, как во всех остальных
  // тестах контракта. `app/contract/` вендорится локально и в репозиторий не
  // коммитится (§460), поэтому на CI его нет вовсе: безусловный
  // `loadFromDirectory` падал там в `setUpAll` — весь файл красный.
  final synced = Directory('contract/registry').existsSync();
  final skip = synced ? null : 'контракт не синхронизирован';

  setUpAll(() async {
    if (!synced) return;
    await ContractRegistry.I.loadFromDirectory('contract');
  });

  group('§24.2 п. 7.1 — hellorandom*/hellorandomized* разводятся данными', () {
    // Контракт 1.1.35 переписал прозу правила: таблица целиком лежит в
    // `tls.fp_dialect.prefix`, и рукописного списка префиксов нет ни у одной
    // стороны. Длинный префикс матчится РАНЬШЕ короткого, поэтому
    // `hellorandomized` не проигрывает `hellorandom`.
    //
    // Прежнее ожидание теста («весь префикс даёт random») повторяло прозу
    // лаунчера, описывавшую мир до 1.1.28, и было неверным: `randomized` —
    // отдельный uTLS-идентификатор ядра, а не написание `random`.
    test('каждый префикс даёт СВОЙ канон', () {
      const cases = {
        'hellorandom': 'random',
        'hellorandom_120': 'random',
        'hellorandomized': 'randomized',
        'hellorandomizedalpn': 'randomized',
        'hellorandomizednoalpn': 'randomized',
      };
      for (final e in cases.entries) {
        final spec = parseVless(
            'vless://11111111-1111-1111-1111-111111111111@e.example.com:443?security=tls&fp=${e.key}#n');
        expect(spec!.tls.fingerprint, e.value, reason: e.key);
        // Значение опознано — подменой оно не считается, кода нет.
        expect(_codes(spec), isNot(contains('UnknownFingerprintWarning')),
            reason: e.key);
      }
    }, skip: skip);
  });

  group('§24.2 п. 7.5 — anytls мусорный SNI', () {
    test('имя без точки и двоеточия заменяется адресом сервера', () {
      final spec =
          parseAnyTls('anytls://pass123@a.example.com:443?sni=%F0%9F%94%92#n');
      expect(spec!.tls.serverName, 'a.example.com');
    }, skip: skip);

    test('нормальный SNI не трогается', () {
      final spec =
          parseAnyTls('anytls://pass123@a.example.com:443?sni=cover.example#n');
      expect(spec!.tls.serverName, 'cover.example');
    }, skip: skip);
  });

  group('§24.2 п. 7.7 — дефолты TUIC не пишутся', () {
    test('без congestion_control/alpn в ссылке поля не эмитятся', () {
      final spec = parseTuic(
          'tuic://11111111-2222-3333-4444-555555555555:pass123@t.example.com:443#n');
      final entry = spec!.emit(TemplateVars.empty).map;
      expect(entry.containsKey('congestion_control'), isFalse);
      expect((entry['tls'] as Map).containsKey('alpn'), isFalse);
    }, skip: skip);
  });

  group('§24.2 п. 7.8 — TUIC udp_relay_mode', () {
    test('мусор снимается с кодом, а не подменяется на native', () {
      final spec = parseTuic(
          'tuic://11111111-2222-3333-4444-555555555555:pass123@t.example.com:443?udp_relay_mode=quiс#n');
      expect(spec!.udpRelayMode, isNull);
      expect(_codes(spec), contains('tuic_udp_relay_mode_invalid'));
      expect(spec.emit(TemplateVars.empty).map.containsKey('udp_relay_mode'),
          isFalse);
    }, skip: skip);

    test('валидные значения проходят без кода', () {
      for (final v in const ['native', 'quic']) {
        final spec = parseTuic(
            'tuic://11111111-2222-3333-4444-555555555555:pass123@t.example.com:443?udp_relay_mode=$v#n');
        expect(spec!.udpRelayMode, v);
        expect(_codes(spec), isNot(contains('tuic_udp_relay_mode_invalid')));
      }
    }, skip: skip);
  });

  group('§24.2 п. 7.9 — пустой пароль', () {
    test('anytls без пароля отбраковывается', () {
      expect(parseAnyTls('anytls://@a.example.com:443#n'), isNull);
    }, skip: skip);

    // ОТКРЫТЫЙ ВОПРОС ВЛАДЕЛЬЦАМ (Q133-67, контракт 1.1.35). У tuic пустой
    // пароль данными не выражается и, по словам лаунчера, выражаться не
    // должен: это не диалект, а выбор СТРОГОСТИ, и он меняет судьбу живых
    // узлов. Кейса корпуса лаунчер намеренно не завёл — корпус нормирует
    // согласованное, а не спорное. Кейс оставлен как есть до решения; свою
    // сторону под чужую прозу не подгоняем.
    test('tuic без пароля отбраковывается', () {
      expect(
          parseTuic(
              'tuic://11111111-2222-3333-4444-555555555555:@t.example.com:443#n'),
          isNull);
    }, skip: skip ?? 'Q133-67 — строгость tuic решают владельцы');
  });

  group('§24.2 п. 7.10 — ss legacy stream-шифры', () {
    // SIP002: userinfo — base64(method:password).
    String ssUri(String method) =>
        'ss://${base64.encode(utf8.encode('$method:pass123'))}'
        '@s.example.com:8388#n';

    test('узел живёт и получает info-код ss_method_legacy', () {
      for (final m in const [
        'aes-128-ctr',
        'aes-192-ctr',
        'aes-256-ctr',
        'aes-128-cfb',
        'aes-192-cfb',
        'aes-256-cfb',
        'rc4-md5',
        'chacha20-ietf',
        'xchacha20',
      ]) {
        final spec = parseShadowsocks(ssUri(m));
        expect(spec, isNotNull, reason: m);
        expect(spec!.method, m, reason: m);
        expect(_codes(spec), contains('ss_method_legacy'), reason: m);
      }
    }, skip: skip);

    test('AEAD-методы кода не получают', () {
      final spec = parseShadowsocks(ssUri('aes-256-gcm'));
      expect(_codes(spec!), isNot(contains('ss_method_legacy')));
    }, skip: skip);

    test('метод вне 18 значений ядра по-прежнему роняет узел', () {
      expect(parseShadowsocks(ssUri('made-up-cipher')), isNull);
    }, skip: skip);
  });

  group('§24.2 п. 7.13 — splithttp = алиас xhttp', () {
    // РАСХОЖДЕНИЕ СТОРОН, передано лаунчеру (синк 1.1.35). Контракт 1.1.35
    // называет алиас выраженным данными, но выражен он только в диалекте
    // XRAY: `blocks.xray.$selector.network.value_map` несёт
    // `splithttp → xhttp`, а `blocks.uri.$selector.type` держит закрытый
    // набор написаний, в котором `splithttp` не значится, и `when.in`
    // подавляет запись целиком. Корпус ссылок такого кейса не несёт —
    // нормирован только вход Xray (`body/xray/vless_splithttp`).
    //
    // У нас же ссылка с `type=splithttp` транспорт получала: рукописный
    // маппер знал алиас (`transport.dart`), и после перевода vless на движок
    // узел стал уезжать в конфиг БЕЗ транспорта — голый TCP на порт, который
    // ждёт HTTP, молча. Чинится не оверлеем: набор `type` нормативен, и
    // угадывать за лаунчера его состав нельзя.
    test('URI type=splithttp даёт транспорт xhttp', () {
      final spec = parseVless(
          'vless://11111111-1111-1111-1111-111111111111@x.example.com:443?security=tls&type=splithttp&path=%2Fv1#n');
      expect(spec!.transport, isA<XhttpTransport>());
    }, skip: skip ?? 'расхождение сторон: алиас объявлен только у входа Xray');

    test('sing-box JSON transport.type=splithttp', () {
      final spec = parseSingboxEntry({
        'type': 'vless',
        'tag': 'n',
        'server': 'x.example.com',
        'server_port': 443,
        'uuid': '11111111-1111-1111-1111-111111111111',
        'transport': {'type': 'splithttp', 'path': '/v1'},
      });
      expect((spec as VlessSpec).transport, isA<XhttpTransport>());
    }, skip: skip);
  });

  group('§24.2 п. 7.15 — socks password-only', () {
    test('пароль без имени эмитится как :pass@', () {
      final spec = SocksSpec(
        id: 'i',
        tag: 't',
        label: 'l',
        server: 's.example.com',
        port: 1080,
        rawSource: '',
        username: '',
        password: 'pass123',
      );
      expect(spec.toUri(), contains(':pass123@'));
      // Круг замкнут: пароль переживает пересохранение узла.
      final back = parseUri(spec.toUri()) as SocksSpec;
      expect(back.password, 'pass123');
    }, skip: skip);
  });

  group('§24.6 — url_path', () {
    test('битый percent в пути снимается с type_invalid, узел живёт', () {
      final spec = parseTrojan(
          'trojan://pass123@t.example.com:443?type=ws&path=%2Fx%25zz&security=tls#n');
      expect(spec, isNotNull);
      expect((spec!.transport as WsTransport).path, '');
      expect(_codes(spec), contains('type_invalid'));
    }, skip: skip);

    test('корректный percent-путь не трогается', () {
      final spec = parseTrojan(
          'trojan://pass123@t.example.com:443?type=ws&path=%2Fx%2Fy&security=tls#n');
      expect((spec!.transport as WsTransport).path, '/x/y');
      expect(_codes(spec), isNot(contains('type_invalid')));
    }, skip: skip);
  });

  group('§24.6 — пустой reality.short_id не эмитится', () {
    test('ключа в теле нет', () {
      final spec = parseVless(
          'vless://11111111-1111-1111-1111-111111111111@r.example.com:443?security=reality'
          '&pbk=AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw&sni=cover.example#n');
      final tls = spec!.emit(TemplateVars.empty).map['tls'] as Map;
      expect((tls['reality'] as Map).containsKey('short_id'), isFalse);
    }, skip: skip);
  });
}
