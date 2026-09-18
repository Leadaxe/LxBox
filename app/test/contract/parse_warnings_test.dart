import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/app_log.dart';
import 'package:lxbox/services/contract/parse_warnings.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/contract/warning_codes.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/parse_all.dart';

/// §460 W2a — предупреждения реестра на узле при РАЗБОРЕ.
///
/// Воронка одна на все входы — `parseAll` (`services/parser/parse_all.dart`),
/// поэтому тесты идут через неё, а не через внутренний хелпер: проверяется
/// ровно то, что увидит список подписки.
const _contractRoot = 'contract';

/// Узлы из тела любого формата — тот же путь, которым идёт приложение.
List<NodeSpec> _parse(String raw) => parseAll(decode(raw));

NodeSpec _one(String raw) {
  final nodes = _parse(raw);
  expect(nodes, hasLength(1), reason: 'ожидался ровно один узел из $raw');
  return nodes.first;
}

List<RegistryWarning> _registry(NodeSpec n) =>
    n.warnings.whereType<RegistryWarning>().toList();

RegistryWarning _byCode(NodeSpec n, String code) => _registry(n).firstWhere(
      (w) => w.code == code,
      orElse: () => fail(
          'нет кода $code; есть: ${_registry(n).map((w) => '${w.code}@${w.path}').toList()}'),
    );

void main() {
  final synced = Directory('$_contractRoot/registry').existsSync();
  final skip = synced ? null : 'контракт не синхронизирован';

  setUpAll(() async {
    if (!synced) return;
    await ContractRegistry.I.loadFromDirectory(_contractRoot);
  });

  group('§460 W2a — воронка parseAll', () {
    test('URI: мусорный key_share даёт код с путём tls.reality.key_share', () {
      // REALITY-узел с валидным pbk: key_share читается только при нём.
      final n = _one(
        'vless://11111111-1111-1111-1111-111111111111@example.com:443'
        '?security=reality&encryption=none&sni=a.example'
        '&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0'
        '&sid=ab&key_share=garbage&type=tcp#node',
      );
      final w = _byCode(n, 'reality_key_share_invalid');
      expect(w.path, 'tls.reality.key_share');
      expect(w.value, 'garbage');
    }, skip: skip);

    test('JSON: битое значение модельного поля даёт код с путём', () {
      // `uuid` у tuic — поле модели и строка: до эмиссии оно доживает, и
      // санитайзер судит его сам.
      final n = _one('''
{"type":"tuic","tag":"n","server":"example.com","server_port":443,
 "uuid":"not-a-uuid","password":"p","congestion_control":"bbr"}
''');
      final w = _byCode(n, 'type_invalid');
      expect(w.path, 'uuid');
    }, skip: skip);

    // ГРАНИЦА ВОЛНЫ W2a — СНЯТА для JSON шагом 1 фичи 472.
    //
    // Раньше разбор смотрел только на `emit()` уже построенного `NodeSpec`, а
    // модель — сама по себе фильтр: JSON-парсер кладёт в спеку то, что у неё
    // есть полем, приводя типы. Мусор вне модели (`totally_bogus`,
    // `tls.min_version: 5` числом) до санитайзера не доезжал, и коды этих
    // полей знал только гард СБОРКИ — человек читал их в отчёте сборки, а не
    // в строке узла.
    //
    // Теперь у JSON-входа санитайзер идёт по ДОСЛОВНОЙ карте (`rawSource`,
    // §455), и такой мусор получает код на узле. Тело при этом по-прежнему не
    // меняется: `emit()` мусора не несёт — его снял парсер, а очищенную карту
    // санитайзера разбор выбрасывает.
    test('JSON: мусор вне модели даёт код на узле, тело не меняя', () {
      final n = _one('''
{"type":"vless","tag":"n","server":"example.com","server_port":443,
 "uuid":"11111111-1111-1111-1111-111111111111","totally_bogus":1,
 "tls":{"enabled":true,"server_name":"a.example","min_version":5}}
''');
      final emitted = n.emit(TemplateVars.empty).map;
      expect(emitted.containsKey('totally_bogus'), isFalse,
          reason: 'ключ вне модели снял JSON-парсер; тело узла не меняется');
      expect((emitted['tls'] as Map).containsKey('min_version'), isFalse,
          reason: 'значение не прошло приведение типа в парсере');

      // Ключ вне схемы: код приходит из дословной карты, с путём и значением.
      final unknown = _byCode(n, 'unknown_key');
      expect(unknown.path, 'totally_bogus');
      expect(unknown.value, '1');

      // Значение не того типа — тоже видно на дословной карте, где оно ещё
      // лежит числом.
      final bad = _byCode(n, 'type_invalid');
      expect(bad.path, 'tls.min_version');
    }, skip: skip);

    test('разбор тело узла не меняет', () {
      // Узел без мусора: аннотация обязана пройти по нему и не тронуть
      // ничего — чистит по-прежнему гард сборки.
      const raw = 'vless://11111111-1111-1111-1111-111111111111@example.com:443'
          '?security=tls&encryption=none&sni=a.example&type=ws&path=/p#node';
      final before = _one(raw).emit(TemplateVars.empty).map;
      final after = _one(raw).emit(TemplateVars.empty).map;
      expect(jsonEncode(after), jsonEncode(before));
    }, skip: skip);

    test('гейты ядра при разборе выключены: min_core кода не даёт', () {
      // `tls.reality.key_share` несёт min_core 1.14.1-lx.4. Валидное значение
      // при разборе обязано пройти молча — версии ядра здесь ещё нет
      // (24.1.6), и снимать поле разбору нечем.
      final n = _one(
        'vless://11111111-1111-1111-1111-111111111111@example.com:443'
        '?security=reality&encryption=none&sni=a.example'
        '&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0'
        '&sid=ab&key_share=hybrid&type=tcp#node',
      );
      expect(_registry(n).map((w) => w.code), isNot(contains('type_invalid')));
      expect(_registry(n).map((w) => w.code),
          isNot(contains('reality_key_share_invalid')));
    }, skip: skip);

    test('одна пара {code, path} не повторяется', () {
      final n = _one(
        'vless://11111111-1111-1111-1111-111111111111@example.com:443'
        '?security=reality&encryption=none&sni=a.example'
        '&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0'
        '&sid=ab&key_share=garbage&type=tcp#node',
      );
      final pairs = _registry(n).map((w) => '${w.code} ${w.path}').toList();
      expect(pairs, isNotEmpty);
      expect(pairs.toSet().length, pairs.length);
    }, skip: skip);
  });

  group('§460 W2a — дедуп с рукописными кодами', () {
    // §472 шаг 7 — пример стоит на ИСКУССТВЕННОМ производителе, и это не
    // упрощение, а единственный оставшийся способ.
    //
    // История переездов: vless (был здесь до шага 3) → tuic (шаги 3–4) →
    // anytls (шаг 5) → masque (шаг 6). Каждый раз пример искали на схеме,
    // которая ЕЩЁ НЕ переехала: дедуп нужен ровно там, где рукописное правило
    // и правило реестра говорят об одном поле, а у переехавшей схемы источник
    // кода по определению один. Шаг 7 увёл masque, и кандидатов не осталось —
    // у wireguard/AWG рукописные коды (`awg_*`) реестр дублем не объявляет.
    //
    // Поэтому производителя ставим руками: узел из sing-box-ТЕЛА конвейером не
    // разбирается (`isPipelineParsed` на нём ложь), значит `annotateWithRegistry`
    // по нему идёт и даёт код реестра. Дописываем на тот же узел рукописный
    // класс с той же парой `(code, path)` — и проверяем, что запись остаётся
    // ОДНА. Смысл прежний: два производителя, одна пара, один результат, и
    // путь у него есть.
    test('рукописный + реестровый с одной парой (code, path) → одна запись',
        () {
      // Производитель искусственный: узел строится из ТЕЛА (конвейер его не
      // касается, `isPipelineParsed` на нём ложь), поэтому `annotateWithRegistry`
      // по нему идёт и даёт `anytls_min_idle_invalid` на `min_idle_session`.
      // Рукописный класс с той же парой существует и сегодня —
      // `AnyTlsMinIdleInvalidWarning` объявляет тот же путь таблицей
      // `handwrittenWarningPath`; с пути ССЫЛКИ его снял шаг 6, а на узел мы
      // ставим его руками.
      //
      // `annotateWithRegistry` зовём сами, поэтому берём узел напрямую, а не
      // через `parseAll`: воронка позвала бы аннотацию до нашей подсадки.
      NodeSpec build() => parseSingboxEntry({
            'type': 'anytls',
            'tag': 'a',
            'server': 'e.example',
            'server_port': 443,
            'password': 'p',
            'min_idle_session': -5,
            'tls': {'enabled': true, 'server_name': 'a.example'},
          }, rawSource: 'не-JSON: дословной карты у узла нет')!;

      const code = 'anytls_min_idle_invalid';
      const path = 'min_idle_session';
      // Путь рукописного класса нормативен: дедуп считается по ПАРЕ.
      expect(handwrittenWarningPath(const AnyTlsMinIdleInvalidWarning('-5')), path);

      // Контроль: без рукописного класса код реестра приходит, с путём.
      final plain = build();
      annotateWithRegistry(plain);
      final fromRegistry = _registry(plain).where((w) => w.code == code).toList();
      expect(fromRegistry, hasLength(1),
          reason: 'реестр судит min_idle_session по `min: 0` + `on_invalid: drop`');
      expect(fromRegistry.single.path, path);

      // А теперь тот же узел с рукописным классом на том же поле: остаётся
      // ОДНА запись, и это рукописная — у неё человеческий текст.
      final seeded = build()
        ..warnings.add(const AnyTlsMinIdleInvalidWarning('-5'));
      annotateWithRegistry(seeded);
      expect(seeded.warnings.whereType<AnyTlsMinIdleInvalidWarning>(),
          hasLength(1),
          reason: 'рукописное предупреждение на месте');
      expect(_registry(seeded).map((w) => w.code), isNot(contains(code)),
          reason: 'реестр тот же код вторым сообщением не дублирует');
    }, skip: skip);

    // §472 шаг 3 — а у переехавшей схемы источник кода РОВНО один: реестр.
    test('у узла конвейера flow_deprecated приходит из реестра, с путём', () {
      final n = _one(
        'vless://11111111-1111-1111-1111-111111111111@example.com:443'
        '?security=tls&encryption=none&sni=a.example'
        '&flow=xtls-rprx-origin&type=tcp#node',
      );
      expect(n.warnings.whereType<DeprecatedFlowWarning>(), isEmpty);
      final w = _registry(n).firstWhere((w) => w.code == 'flow_deprecated',
          orElse: () => fail('нет кода flow_deprecated: ${n.warnings}'));
      expect(w.path, 'flow');
      expect(w.value, 'xtls-rprx-origin');
    }, skip: skip);

    test('обфускация: рукописный obfs_unknown не дублируется реестром', () {
      final n = _one(
        'hysteria2://pass@example.com:443?obfs=nonsense&obfs-password=p#node',
      );
      final codes = _registry(n).map((w) => w.code).toList();
      if (n.warnings.whereType<UnknownObfsWarning>().isNotEmpty) {
        expect(codes, isNot(contains('obfs_unknown')));
      }
    }, skip: skip);
  });

  group('§472 шаг 1 — санитайзер по дословной карте JSON-узла', () {
    test('коды дословного тела встают на узел с путём и значением', () {
      // Тот же узел, что в корпусе (`vless_junk_pair.body`): три класса мусора,
      // и ни один из них не доживает до `emit()` — их снял типизированный
      // парсер. До шага 1 узел оставался без кодов вовсе.
      final n = _one(
        '{"type":"vless","tag":"junk","server":"a.example","server_port":443,'
        '"uuid":"11111111-1111-1111-1111-111111111111",'
        '"flow":"xtls-rprx-direct","packet_encoding":"teleport",'
        '"tls":{"enabled":true,"server_name":"a.example",'
        '"reality":{"enabled":true,'
        '"public_key":"AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw",'
        '"short_id":"abc"}}}',
      );
      expect(_byCode(n, 'flow_deprecated').value, 'xtls-rprx-direct');
      expect(_byCode(n, 'packet_encoding_unknown').value, 'teleport');
      expect(_byCode(n, 'reality_short_id_invalid').path,
          'tls.reality.short_id');
    }, skip: skip);

    test('дословная карта: тело узла не меняется', () {
      // Санитайзер работает наблюдателем — очищенную карту разбор
      // выбрасывает. `rawSource` обязан остаться тем, что прислал провайдер
      // (§455: JSON-источник уходит в ядро дословно).
      const raw = '{"type":"naive","tag":"m","server":"m.example",'
          '"server_port":443,"username":"u","password":"p",'
          '"totally_unknown_key":"whatever",'
          '"tls":{"enabled":true,"server_name":"m.example","insecure":true}}';
      final n = _one(raw);
      expect(jsonDecode(n.rawSource), jsonDecode(raw),
          reason: 'дословный источник узла не тронут');
      final emitted = n.emit(TemplateVars.empty).map;
      expect(emitted.containsKey('totally_unknown_key'), isFalse);
      expect((emitted['tls'] as Map).containsKey('insecure'), isFalse);
      expect(_byCode(n, 'unknown_key').value, 'whatever');
    }, skip: skip);

    test('гейты ядра выключены и на дословной карте', () {
      // `tls.reality.key_share` несёт min_core 1.14.1-lx.4. Валидное значение
      // в ДОСЛОВНОМ теле обязано пройти молча: версии ядра при разборе нет.
      final n = _one(
        '{"type":"vless","tag":"ks","server":"a.example","server_port":443,'
        '"uuid":"11111111-1111-1111-1111-111111111111",'
        '"tls":{"enabled":true,"server_name":"a.example",'
        '"utls":{"enabled":true,"fingerprint":"chrome"},'
        '"reality":{"enabled":true,'
        '"public_key":"AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw",'
        '"short_id":"abcd","key_share":"classical"}}}',
      );
      final codes = _registry(n).map((w) => w.code);
      expect(codes, isNot(contains('reality_key_share_invalid')));
      expect(codes, isNot(contains('min_core_unsupported')));
    }, skip: skip);

    test('дедуп: рукописный класс с путём закрывает только свой путь', () {
      // У naive реестр шлёт `tls_field_unsupported_naive` на КАЖДОЕ
      // запрещённое поле. Рукописный `InsecureTlsWarning` пути не несёт, и до
      // шага 1 дедуп по одному коду съел бы весь набор. Здесь проверяется, что
      // на каждое поле остаётся ровно одна запись и адреса не потеряны.
      final n = _one(
        '{"type":"naive","tag":"j","server":"s.example","server_port":443,'
        '"username":"u","password":"p",'
        '"tls":{"enabled":true,"server_name":"s.example","insecure":true,'
        '"alpn":["h2"],"min_version":"1.2","fragment":true}}',
      );
      final paths = _registry(n)
          .where((w) => w.code == 'tls_field_unsupported_naive')
          .map((w) => w.path)
          .toList();
      expect(
        paths,
        containsAll(<String>[
          'tls.insecure',
          'tls.alpn',
          'tls.min_version',
          'tls.fragment',
        ]),
      );
      // Ни одна пара (code, path) не повторяется — ни внутри набора, ни с
      // рукописными классами.
      final pairs = <String>[
        for (final w in n.warnings)
          '${warningCodeOf(w) ?? ''} ${w is RegistryWarning ? w.path ?? '' : handwrittenWarningPath(w) ?? ''}',
      ];
      expect(pairs.toSet().length, pairs.length,
          reason: 'пара (code, path) обязана быть одна: $pairs');
    }, skip: skip);

    test('URI-узел дословной карты не имеет — прежнее поведение', () {
      // `rawSource` ссылки — это ссылка, а не JSON: второй проход её
      // пропускает, и коды приходят только от `emit()`-прохода, как в W2a.
      final n = _one(
        'vless://11111111-1111-1111-1111-111111111111@example.com:443'
        '?security=reality&encryption=none&sni=a.example'
        '&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0'
        '&sid=ab&key_share=garbage&type=tcp#node',
      );
      expect(n.rawSource.startsWith('{'), isFalse);
      final w = _byCode(n, 'reality_key_share_invalid');
      expect(w.path, 'tls.reality.key_share');
    }, skip: skip);

    test('Xray-JSON остаётся на шаг 8: дословной sing-box-карты у него нет',
        () {
      // У Xray-узла `rawSource` — объект XRAY (`streamSettings`,
      // `settings.vnext[]`), а санитайзер судит карту sing-box. Общего у них
      // нет даже имени поля типа: `protocol` против `type`. Мусор здесь на
      // узел не встаёт — и это НЕ дефект шага 1, а его граница: маппер
      // «Xray-карта → sing-box-карта» заводится шагом 8 спеки 472.
      final n = _one(
        '[{"remarks":"xr","outbounds":[{"tag":"x","protocol":"vless",'
        '"settings":{"vnext":[{"address":"x.example","port":443,'
        '"users":[{"id":"11111111-1111-1111-1111-111111111111",'
        '"flow":"xtls-rprx-direct","encryption":"none"}]}]},'
        '"streamSettings":{"network":"tcp","security":"none",'
        '"totally_unknown_key":"whatever"}}]}]',
      );
      expect(n.rawSource.contains('streamSettings'), isTrue,
          reason: 'источник Xray-узла — его собственный объект');
      expect(_registry(n).map((w) => w.code), isNot(contains('unknown_key')),
          reason: 'sing-box-санитайзер по Xray-карте не ходит (шаг 8)');
    }, skip: skip);

    test('предупреждения переживают хранение: узел разбирается заново', () {
      // Узел хранится ТЕКСТОМ (`raw_body` записи 1.0), и при чтении записи
      // разбирается тем же `parseAll`. Значит коды не сериализуются, а
      // считаются заново на каждой загрузке — проверяется полным
      // круговоротом через кодек записи.
      const raw = '{"type":"naive","tag":"stored","server":"m.example",'
          '"server_port":443,"username":"u","password":"p",'
          '"totally_unknown_key":"whatever",'
          '"tls":{"enabled":true,"server_name":"m.example","insecure":true}}';
      final before = UserServer(
        id: 'src-1',
        name: 'stored',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: raw,
        nodes: _parse(raw),
      );
      expect(_byCode(before.nodes.single, 'unknown_key').path,
          'totally_unknown_key');

      final read = sourceFromRecord(
        jsonDecode(jsonEncode(sourceToRecord(before)))
            as Map<String, dynamic>,
      ).value;
      expect(read, isNotNull, reason: 'запись прочиталась');
      final node = (read as ServerList).nodes.single;
      final codes = node.warnings
          .map(warningCodeOf)
          .whereType<String>()
          .toSet();
      expect(codes, contains('unknown_key'));
      expect(codes, contains('tls_field_unsupported_naive'));
    }, skip: skip);
  });

  // §473 (контракт 1.1.5) — условный потолок MTU у AmneziaWG и исключение по
  // входу. Правило одно, а исход у него два, и решает вход узла.
  group('§473 — потолок MTU AmneziaWG', () {
    // AWG-endpoint ТЕЛОМ sing-box: вход `singbox`.
    String awgBody(int? mtu) => '{"type":"wireguard","tag":"awg-ep",'
        '${mtu == null ? '' : '"mtu":$mtu,'}'
        '"address":["10.0.0.2/32"],'
        '"private_key":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=","jc":10,'
        '"peers":[{"address":"example-3.com","port":51820,'
        '"public_key":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=",'
        '"allowed_ips":["0.0.0.0/0"]}]}';

    test('тело sing-box с mtu=1420: значение цело, код info', () {
      final n = _one(awgBody(1420));
      expect(n.emit(TemplateVars.empty).map['mtu'], 1420,
          reason: 'написанное человеком в форме ядра не переписывается');
      final w = _byCode(n, 'awg_mtu_high');
      expect(w.path, 'mtu');
      expect(w.value, '1420');
      // Ровно ОДИН код про MTU: проходов санитайзера у JSON-входа два, и
      // разойдись они входом, узел получил бы и info, и warning об одном поле.
      expect(
          _registry(n).where((w) => w.code.startsWith('awg_mtu_')), hasLength(1));
    }, skip: skip);

    test('та же нода ССЫЛКОЙ: значение заменено, код warning', () {
      // Парность входов нарушена НАМЕРЕННО (решение владельца 18.09.2026):
      // значение из ссылки сочинял генератор провайдера, а не автор узла.
      final n = _one(
          'wireguard://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=@example-3.com:51820'
          '?publickey=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA%3D'
          '&address=10.0.0.2/32&mtu=1420&jc=10#awg-link');
      expect(n.emit(TemplateVars.empty).map['mtu'], 1280);
      final w = _byCode(n, 'awg_mtu_clamped');
      expect(w.path, 'mtu');
      expect(w.value, '1420',
          reason: 'в коде исходное значение, а не то, чем его заменили');
    }, skip: skip);

    test('ссылка без mtu: дефолт 1280, кода нет', () {
      final n = _one(
          'wireguard://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=@example-3.com:51820'
          '?publickey=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA%3D'
          '&address=10.0.0.2/32&jc=10#awg-nomtu');
      expect(n.emit(TemplateVars.empty).map['mtu'], 1280);
      expect(_registry(n).map((w) => w.code),
          isNot(contains('awg_mtu_clamped')));
      expect(_registry(n).map((w) => w.code), isNot(contains('awg_mtu_high')));
    }, skip: skip);

    test('обычный WireGuard ссылкой с mtu=1420: без замены и без кодов', () {
      final n = _one(
          'wireguard://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=@example-3.com:51820'
          '?publickey=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA%3D'
          '&address=10.0.0.2/32&mtu=1420#plain-wg');
      expect(n.emit(TemplateVars.empty).map['mtu'], 1420);
      expect(_registry(n).where((w) => w.code.startsWith('awg_mtu_')), isEmpty);
    }, skip: skip);

    test('jc: 0 в теле — законный AWG-узел, потолок действует', () {
      // Условие `any_set` судит НАЛИЧИЕ ключа. Прочитай оно `jc: 0` как «поля
      // нет» (предикат `conflicts`/`requires`, §467), с такого узла потолок
      // снялся бы, и туннель молча перестал бы нести данные.
      final n = _one(awgBody(1420).replaceFirst('"jc":10', '"jc":0'));
      expect(_byCode(n, 'awg_mtu_high').value, '1420');
    }, skip: skip);

    test('исключение по входу ПЕРЕЖИВАЕТ перезапуск', () {
      // Вход определяется по `rawSource` — тому самому тексту, что лежит в
      // хранении, и разбор идёт заново при каждой загрузке. Считай мы вход из
      // чего-то сессионного, узел получил бы кламп задним числом при
      // следующем старте: настройка человека исчезла бы молча.
      final raw = awgBody(1420);
      final before = UserServer(
        id: 'src-awg',
        name: 'awg',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        rawBody: raw,
        nodes: _parse(raw),
      );
      expect(before.nodes.single.emit(TemplateVars.empty).map['mtu'], 1420);

      final read = sourceFromRecord(
        jsonDecode(jsonEncode(sourceToRecord(before)))
            as Map<String, dynamic>,
      ).value;
      final node = (read as ServerList).nodes.single;
      expect(node.emit(TemplateVars.empty).map['mtu'], 1420,
          reason: 'тот же mtu после разбор → запись → чтение');
      final codes = node.warnings.map(warningCodeOf).whereType<String>();
      expect(codes, contains('awg_mtu_high'));
      expect(codes, isNot(contains('awg_mtu_clamped')),
          reason: 'тот же код, а не подменённый на замену');
    }, skip: skip);
  });

  group('§460 W2a — цена разбора', () {
    // Аннотация считается на КАЖДОМ узле подписки, поэтому её цена измерена,
    // а не предположена. Замер на рабочей машине (2000 узлов vless+ws+tls,
    // release-прогон `flutter test`):
    //
    //   разбор без реестра        ~42 мс
    //   аннотация сверху          ~95 мс  (≈47 мкс на узел)
    //   схема из кэша, x2000      ~0.7 мс (≈0.3 мкс на вызов)
    //
    // 95 мс однократно на подписку в 2000 узлов — цена обхода 384 полей
    // схемы, и она приемлема: разбор идёт один раз на обновление подписки,
    // не на каждый кадр.
    //
    // Порог ниже сознательно НЕ про проценты: абсолютные миллисекунды
    // на CI-раннере и на ноутбуке несопоставимы, и тест на ±20 % был бы
    // флаки-генератором. Он ловит потерю КЭША схем — единственную регрессию,
    // которая здесь реальна: без `_schemaCache` каждый узел заново
    // раскрывает `ref`-ы (tls + dialer + multiplex), и цена растёт на
    // порядок, а не на проценты.
    test('2000 узлов: схема берётся из кэша, а не раскрывается заново', () {
      const n = 2000;

      // Прогрев кэша и JIT.
      for (var i = 0; i < 50; i++) {
        ContractRegistry.I.schemaFor('vless');
      }

      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        ContractRegistry.I.schemaFor('vless');
      }
      sw.stop();

      // Раскрытие схемы vless — это разбор JSON-секций tls/transports/
      // dialer/multiplex, десятки микросекунд на вызов. Из кэша — доли
      // микросекунды. Порог 20 мс на 2000 вызовов (10 мкс на вызов) лежит
      // между этими режимами с запасом в обе стороны.
      expect(
        sw.elapsedMicroseconds,
        lessThan(20000),
        reason: 'schemaFor перестал кэшировать: ${sw.elapsedMicroseconds}µs '
            'на $n вызовов',
      );
    }, skip: skip);

    test('2000 узлов с предупреждениями разбираются за разумное время', () {
      const n = 2000;
      final body = StringBuffer();
      for (var i = 0; i < n; i++) {
        // Узел с полным телом (tls + ws + fp) — худший случай обхода схемы.
        body.writeln(
          'vless://11111111-1111-1111-1111-111111111111@example.com:443'
          '?security=tls&encryption=none&sni=a.example&type=ws&path=/p'
          '&fp=chrome#node$i',
        );
      }
      final decoded = decode(body.toString());

      expect(parseAll(decoded), hasLength(n)); // прогрев

      final sw = Stopwatch()..start();
      final nodes = parseAll(decoded);
      sw.stop();
      expect(nodes, hasLength(n));

      // Измерено ~130 мс (разбор + аннотация). Потолок 3 с — про «ушло в
      // квадратичность», а не про проценты: на самом медленном CI-раннере
      // запас десятикратный.
      expect(
        sw.elapsedMilliseconds,
        lessThan(3000),
        reason: 'разбор $n узлов с реестром: ${sw.elapsedMilliseconds} мс',
      );
    }, skip: skip);

    // §472 шаг 1 — у JSON-входа проходов санитайзера ДВА: по дословной карте и
    // по `emit()`. Цена второго прохода измеряется здесь, тем же порогом и по
    // тому же образцу: он про «ушло в квадратичность», а не про проценты.
    // Дословный проход вдобавок разбирает `rawSource` из текста, поэтому кейс
    // взят худший — тело с мусором, на котором санитайзер не выходит рано.
    //
    // Замер на рабочей машине (та же машина, тот же прогон, что у URI-кейса
    // выше): URI 2000 узлов ~138 мс, JSON 2000 узлов с мусором ~595 мс.
    // Разница — не второй санитайзер сам по себе, а `jsonDecode` дословного
    // тела на каждом узле плюс полный обход схемы там, где у чистого узла
    // санитайзер выходит рано. Инвариант 5 спеки 472 (не хуже ×1,5 к W2a)
    // считается по СВОЕМУ входу: JSON-разбора под W2a не существовало, узел
    // оставался без кодов вовсе.
    test('2000 JSON-узлов с мусором разбираются за разумное время', () {
      const n = 2000;
      final entries = <String>[
        for (var i = 0; i < n; i++)
          '{"type":"vless","tag":"node$i","server":"e$i.example",'
              '"server_port":443,'
              '"uuid":"11111111-1111-1111-1111-111111111111",'
              '"flow":"xtls-rprx-direct","packet_encoding":"teleport",'
              '"totally_unknown_key":"whatever",'
              '"tls":{"enabled":true,"server_name":"a.example",'
              '"utls":{"enabled":true,"fingerprint":"chrome"},'
              '"reality":{"enabled":true,'
              '"public_key":"AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw",'
              '"short_id":"abc"}}}',
      ];
      final decoded = decode('[${entries.join(',')}]');

      expect(parseAll(decoded), hasLength(n)); // прогрев

      final sw = Stopwatch()..start();
      final nodes = parseAll(decoded);
      sw.stop();
      expect(nodes, hasLength(n));

      // Коды на месте: замер обязан мерить работу, а не пустой проход.
      expect(_registry(nodes.first).map((w) => w.code),
          contains('flow_deprecated'));

      expect(
        sw.elapsedMilliseconds,
        lessThan(3000),
        reason: 'разбор $n JSON-узлов с реестром: ${sw.elapsedMilliseconds} мс',
      );
    }, skip: skip);
  });

  group('§460 W2a — secret-поля', () {
    test('битый secret uuid не утекает ни в текст, ни в AppLog', () {
      const secretValue = 'SUPERSECRET-uuid-not-a-uuid-at-all';
      final n = _one('''
{"type":"tuic","tag":"n","server":"example.com","server_port":443,
 "uuid":"$secretValue","password":"p","congestion_control":"bbr"}
''');
      final w = _byCode(n, 'type_invalid');
      expect(w.path, 'uuid');
      expect(w.value, '***', reason: 'значение secret-поля маскируется');

      // Ни одно предупреждение узла не несёт исходного значения.
      for (final warning in n.warnings) {
        expect(warning.renderEn(), isNot(contains(secretValue)));
        expect(warning.message(), isNot(contains(secretValue)));
        expect(warning.toString(), isNot(contains(secretValue)));
      }

      // И лог — тоже: `entries` отдаёт весь буфер сессии (newest first),
      // так что проверка накрывает и всё, что написал разбор.
      for (final e in AppLog.I.entries) {
        expect(e.message, isNot(contains(secretValue)));
      }
    }, skip: skip);
  });

  // §469 (контракт 1.1.4) — uTLS/REALITY на QUIC снимаются правилом реестра,
  // и узел обязан получить код на ОБОИХ входах. Особенность против остальных
  // правил: до санитайзера блок не доезжает (`toSingboxForQuic` срезает его
  // на эмите, а санитайзер разбора смотрит именно на `emit()`), поэтому код
  // ставит парсер — но по реестру, а не по своему списку схем.
  group('§469 — uTLS/REALITY на QUIC', () {
    test('hysteria2 из ссылки: fp снят с кодом, тело без utls', () {
      final n = _one(
        'hysteria2://pass123@example-1.com:443'
        '?sni=x.example.com&fp=chrome#hy2',
      );
      final w = _byCode(n, 'tls_not_applicable_quic');
      expect(w.path, 'tls.utls');
      expect(w.value, 'map[enabled:true fingerprint:chrome]');
      expect(w.severity, WarningSeverity.info,
          reason: 'снята настройка, которой на QUIC и не было бы — узел '
              'ничего не теряет');
      final tls = n.emit(TemplateVars.empty).map['tls'] as Map;
      expect(tls.containsKey('utls'), isFalse);
      expect(tls['server_name'], 'x.example.com',
          reason: 'остальной TLS цел');
    }, skip: skip);

    test('hysteria2 из ссылки: REALITY — один код на блок', () {
      final n = _one(
        'hysteria2://pass123@example-1.com:443?sni=x.example.com&fp=chrome'
        '&pbk=AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw&sid=ab#hy2',
      );
      expect(
        _registry(n)
            .where((w) => w.code == 'tls_not_applicable_quic')
            .map((w) => w.path)
            .toList(),
        ['tls.utls', 'tls.reality'],
        reason: 'по коду на блок, в порядке схемы TLS; short_id своего '
            'кода не даёт',
      );
      expect((n.emit(TemplateVars.empty).map['tls'] as Map)
          .containsKey('reality'), isFalse);
    }, skip: skip);

    test('tuic из ссылки: fp читается ради кода и в тело не едет', () {
      final n = _one(
        'tuic://11111111-1111-1111-1111-111111111111:pass123@'
        'tuic.example-1.com:443/?congestion_control=bbr&fp=firefox'
        '&sni=tuic.example-1.com#tuic',
      );
      final w = _byCode(n, 'tls_not_applicable_quic');
      expect(w.path, 'tls.utls');
      expect(w.value, 'map[enabled:true fingerprint:firefox]');
      expect((n.emit(TemplateVars.empty).map['tls'] as Map)
          .containsKey('utls'), isFalse);
    }, skip: skip);

    test('hysteria2 из тела: те же коды, что у ссылки', () {
      final n = _one('''
{"type":"hysteria2","tag":"hy2","server":"example-1.com","server_port":443,
 "password":"pass123","tls":{"enabled":true,"server_name":"x.example.com",
 "utls":{"enabled":true,"fingerprint":"chrome"},
 "reality":{"enabled":true,
  "public_key":"AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw","short_id":"ab"}}}
''');
      expect(
        _registry(n)
            .where((w) => w.code == 'tls_not_applicable_quic')
            .map((w) => '${w.path}|${w.value}')
            .toList(),
        [
          'tls.utls|map[enabled:true fingerprint:chrome]',
          'tls.reality|map[enabled:true public_key:'
              'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5…',
        ],
      );
    }, skip: skip);

    test('vless+reality — без изменений: своих кодов QUIC-правило не даёт', () {
      final n = _one(
        'vless://11111111-1111-1111-1111-111111111111@example.com:443'
        '?security=reality&encryption=none&sni=a.example'
        '&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0'
        '&sid=ab&fp=chrome&type=tcp#node',
      );
      expect(_registry(n).map((w) => w.code),
          isNot(contains('tls_not_applicable_quic')));
      final tls = n.emit(TemplateVars.empty).map['tls'] as Map;
      expect((tls['reality'] as Map)['public_key'],
          'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0');
      expect(tls.containsKey('utls'), isTrue);
    }, skip: skip);

    test('masque из тела: правило то же (ссылка fp/pbk не несёт)', () {
      final n = _one('''
{"type":"masque","tag":"m","server":"192.0.2.44","server_port":443,
 "profile":"cloudflare","vhttp":"h3","private_key":"k","public_key":"k",
 "ip":"172.16.0.2/32","tls":{"server_name":"w.example.com",
 "utls":{"enabled":true,"fingerprint":"safari"}}}
''');
      final w = _byCode(n, 'tls_not_applicable_quic');
      expect(w.path, 'tls.utls');
      expect(w.value, 'map[enabled:true fingerprint:safari]');
      // `MasqueSpec` таких полей не знает — тело и без правила было бы чистым;
      // правило добавляет ровно слово о потере.
      expect((n.emit(TemplateVars.empty).map['tls'] as Map?)
          ?.containsKey('utls'), isNot(isTrue));
    }, skip: skip);

    test('§469 п. 6 — obfs-коды hysteria2 доходят до узла и из тела', () {
      final unknown = _one('''
{"type":"hysteria2","tag":"n","server":"example-1.com","server_port":443,
 "password":"p","obfs":{"type":"wat","password":"x"}}
''');
      expect(unknown.warnings.whereType<UnknownObfsWarning>(), hasLength(1));

      final noPass = _one('''
{"type":"hysteria2","tag":"n","server":"example-1.com","server_port":443,
 "password":"p","obfs":{"type":"salamander"}}
''');
      expect(noPass.warnings.whereType<MissingObfsPasswordWarning>(),
          hasLength(1));
    }, skip: skip);
  });
}
