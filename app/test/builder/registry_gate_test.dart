// §460 W1 — гард реестра на сборке конфига.
//
// Два вопроса, на которые отвечает файл:
//   1. Мусор в теле JSON-источника (§455 переносит его дословно) гард
//      действительно снимает, и предупреждение несёт текст реестра.
//   2. Валидный конфиг гард не трогает: эталоны rich_v0/avd_v0 обязаны
//      остаться байт в байт ТЕМИ ЖЕ при ЗАГРУЖЕННОМ реестре. Обычные
//      golden-тесты реестр не грузят, поэтому проверка живёт здесь.

import 'package:flutter_test/flutter_test.dart';
import '../contract_paths.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/services/builder/registry_gate.dart';

import '../storage_migration/golden_harness.dart';


/// Версия ядра эталонов — та же, что в golden_harness.
const _core = kGoldenCoreVersion;

void main() {

  setUpAll(loadTestRegistry);


  group('гард реестра на сборке', () {
    test('naive из JSON-источника: foo и tls.insecure сняты, certificate цел',
        () {
      // Тело в точности как его переносит §455 — дословно, вместе с мусором.
      final entry = Outbound(<String, dynamic>{
        'type': 'naive',
        'tag': 'naive-json',
        'server': '1.2.3.4',
        'server_port': 443,
        'username': 'u',
        'password': 'p',
        'foo': 1,
        'tls': {
          'enabled': true,
          'server_name': 's.example.com',
          'insecure': true,
          'certificate': '-----BEGIN CERTIFICATE-----',
        },
      });

      final report = applyRegistryGate([entry], coreVersion: _core);

      expect(report.dropped, isEmpty, reason: 'узел остаётся в конфиге');
      expect(entry.map.containsKey('foo'), isFalse);
      final tls = entry.map['tls'] as Map;
      expect(tls.containsKey('insecure'), isFalse,
          reason: 'naive не читает insecure — у ядра это фатал старта');
      expect(tls['certificate'], '-----BEGIN CERTIFICATE-----',
          reason: 'certificate naive читает — поле обязано уцелеть');
      expect(tls['server_name'], 's.example.com');

      // Ровно два предупреждения, и оба с текстом реестра, а не с кодом.
      expect(report.warnings.length, 2, reason: report.warnings.join('\n'));
      final joined = report.warnings.join('\n');
      expect(joined, contains('naive-json: '));
      // Путь есть у обоих. §469 — у запрета (`forbidden_for`) появилось и
      // ЗНАЧЕНИЕ: ожидания корпуса его называют
      // (`singbox/outbound_array_tls_fields` → `tls.insecure` = `true`), а
      // гейт до этого ставил код без него.
      // §470 — значение появилось и у `unknown_key`: результат разбора корпуса называет
      // его (`body/singbox/manual_object_junk`), и лаунчер печатает снятое
      // `src[name]`. «Ключ снят» без значения не говорило человеку, ЧТО он
      // потерял, а раннер тел расходился с контрактом на одном этом поле.
      expect(joined, contains('[foo=1]'));
      expect(joined, contains('[tls.insecure=true]'));
      // Текст из warnings.json, а не голый код.
      expect(joined, isNot(contains('unknown_key')));
      expect(joined, isNot(contains('tls_field_unsupported_naive')));
      expect(joined, contains('unknown key'));
      expect(joined, contains('naive: TLS field tls.insecure removed'));
    });

    test('запись без обязательного поля снимается целиком', () {
      final entry = Outbound(<String, dynamic>{
        'type': 'vless',
        'tag': 'no-uuid',
        'server': 'example.com',
        'server_port': 443,
      });
      final report = applyRegistryGate([entry], coreVersion: _core);
      expect(report.dropped, [entry]);
      expect(report.warnings.single, contains('no-uuid: '));
    });

    // §477 — второй эшелон для узла `origin.kind: json` (§455).
    //
    // Такой узел идёт в ядро ДОСЛОВНО, минуя модель, поэтому правило формы
    // `encryption` обязано сработать и здесь: иначе одна негодная строка в
    // одном узле подписки уронила бы старт ВСЕГО конфига (#147). Разбор
    // отбраковывает такой узел раньше (`parseAll`), но гард — последний, кто
    // видит тело перед ядром, и полагаться на один эшелон нельзя.
    test('§477 — дословный JSON-узел с негодным encryption не едет в ядро',
        () {
      final entry = Outbound(<String, dynamic>{
        'type': 'vless',
        'tag': 'verbatim-enc-broken',
        'server': 'example.com',
        'server_port': 443,
        'uuid': '11111111-1111-1111-1111-111111111111',
        // Три части вместо четырёх — ровно случай #147.
        'encryption': 'mlkem768x25519plus.native.0rtt',
      });
      final report = applyRegistryGate([entry],
          coreVersion: _core, verbatim: {entry});
      expect(report.dropped, [entry],
          reason: 'запись обязана быть снята целиком, а не лишена поля');
      // Текст реестра, с путём и СЫРЫМ значением.
      final line = report.warnings.single;
      expect(line, contains('verbatim-enc-broken: '));
      expect(line, contains('[encryption=mlkem768x25519plus.native.0rtt]'));
      expect(line, isNot(contains('vless_encryption_invalid')),
          reason: 'человеку — текст реестра, а не голый код');
    });

    test('§477 — дословный JSON-узел с годным encryption проходит нетронутым',
        () {
      const enc = 'mlkem768x25519plus.native.0rtt.'
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
      final body = <String, dynamic>{
        'type': 'vless',
        'tag': 'verbatim-enc-ok',
        'server': 'example.com',
        'server_port': 443,
        'uuid': '11111111-1111-1111-1111-111111111111',
        'encryption': enc,
      };
      final entry = Outbound(Map<String, dynamic>.from(body));
      final report = applyRegistryGate([entry],
          coreVersion: _core, verbatim: {entry});
      expect(report.dropped, isEmpty);
      expect(report.warnings, isEmpty);
      expect(entry.map, body, reason: '§455 — тело едет дословно');
    });

    test('валидное тело гард не трогает и молчит', () {
      final body = <String, dynamic>{
        'type': 'vless',
        'tag': 'ok',
        'server': 'example.com',
        'server_port': 443,
        'uuid': '11111111-1111-1111-1111-111111111111',
        'tls': {'enabled': true, 'server_name': 'example.com'},
      };
      final entry = Outbound(Map<String, dynamic>.from(body));
      final report = applyRegistryGate([entry], coreVersion: _core);
      expect(report.warnings, isEmpty);
      expect(report.dropped, isEmpty);
      expect(entry.map, body);
    });

    // §473 — условный потолок MTU у AmneziaWG (`max_when`, контракт 1.1.5) и
    // его исключение по входу. Гард — единственный, кто тело переписывает, и
    // именно здесь исключение обязано соблюдаться: §455 обещает, что узел
    // `origin.kind: json` идёт в ядро ДОСЛОВНО.
    Endpoint awgEndpoint(int? mtu, {String tag = 'awg-ep'}) =>
        Endpoint(<String, dynamic>{
          'type': 'wireguard',
          'tag': tag,
          'mtu': ?mtu,
          'address': ['10.0.0.2/32'],
          'private_key': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=',
          'jc': 10,
          'peers': [
            {
              'address': 'example-3.com',
              'port': 51820,
              'public_key': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=',
              'allowed_ips': ['0.0.0.0/0'],
            },
          ],
        });

    test('§455 — дословному JSON-телу гард MTU НЕ подменяет, только info', () {
      final entry = awgEndpoint(1420);
      final report = applyRegistryGate([entry],
          coreVersion: _core, verbatim: {entry});

      // Главное: тело в ядро уходит как написано. Подмени гард значение —
      // настройка человека исчезла бы на сборке, а §455 обещает обратное.
      expect(entry.map['mtu'], 1420);
      expect(report.dropped, isEmpty);
      // Info-код при этом есть: молчать о завышенном MTU тоже нельзя —
      // туннель поднимется, а данные не пойдут.
      expect(report.warnings.single, contains('awg-ep: '));
      expect(report.warnings.single, contains('[mtu=1420]'));
      expect(report.warnings.single, contains('MTU above 1280'));
    });

    test('то же тело БЕЗ метки дословности: MTU заменён потолком', () {
      // Узел из ссылки/INI: тело собрал наш разбор, и потолок работает
      // заменой. Пара к тесту выше — различие входов НАМЕРЕННОЕ, и держать
      // его надо на виду.
      final entry = awgEndpoint(1420);
      final report = applyRegistryGate([entry], coreVersion: _core);

      expect(entry.map['mtu'], 1280);
      expect(report.warnings.single, contains('[mtu=1420]'),
          reason: 'в коде — ИСХОДНОЕ значение, а не то, чем его заменили');
      expect(report.warnings.single, contains('MTU lowered to 1280'));
    });

    test('обычный WireGuard: потолка нет ни на каком входе', () {
      // `max_when.when.any_set` судит РОД узла. Сработай он по полю, а не по
      // набору awg-ключей, каждый plain-WG-узел потерял бы свой MTU.
      final entry = Endpoint(<String, dynamic>{
        'type': 'wireguard',
        'tag': 'plain-wg',
        'mtu': 1420,
        'address': ['10.0.0.2/32'],
        'private_key': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=',
        'peers': [
          {
            'address': 'example-3.com',
            'port': 51820,
            'public_key': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=',
            'allowed_ips': ['0.0.0.0/0'],
          },
        ],
      });
      final report = applyRegistryGate([entry], coreVersion: _core);
      expect(entry.map['mtu'], 1420);
      expect(report.warnings, isEmpty);
    });

    test('jc: 0 — законный AWG-узел, потолок с него не снимается', () {
      // Предикат условия судит НАЛИЧИЕ ключа, а не непустоту значения
      // (в отличие от `conflicts`/`requires`, §467). `jc: 0` значит «мусорные
      // пакеты выключены» у настоящего AmneziaWG — прочитай условие это как
      // «поля нет», туннель молча перестал бы нести данные.
      final entry = awgEndpoint(1420, tag: 'awg-jc0');
      entry.map['jc'] = 0;
      final report = applyRegistryGate([entry], coreVersion: _core);
      expect(entry.map['mtu'], 1280);
      expect(report.warnings.single, contains('awg-jc0: '));
    });

    test('MTU не задан — дефолт 1280 дописывается и на дословном теле', () {
      // Исключение по входу — про ЗАМЕНУ написанного, а не про подстановку
      // недостающего: кода тут нет, а поле появляется (кейс корпуса
      // `body/singbox/endpoints_awg_mtu_default`).
      final entry = awgEndpoint(null);
      final report = applyRegistryGate([entry],
          coreVersion: _core, verbatim: {entry});
      expect(entry.map['mtu'], 1280);
      expect(report.warnings, isEmpty);
    });

    test('реестр не загружен — гард no-op', () {
      // Отдельного способа «выгрузить» реестр нет и заводить его незачем:
      // ветку проверяем на типе, схемы которого в реестре нет, — путь тот же
      // (schemaFor == null → тело как есть).
      final entry = Outbound(<String, dynamic>{
        'type': 'shadowtls',
        'tag': 'foreign',
        'server': 'example.com',
        'whatever': 1,
      });
      final report = applyRegistryGate([entry], coreVersion: _core);
      expect(report.warnings, isEmpty);
      expect(entry.map['whatever'], 1);
    });
  });

  // Д-1 (эмулятор 19.09.2026) — страховка типа. БЕЗ `skip`: она обязана
  // работать и тогда, когда реестр не синхронизирован, — на том и стоит.
  group('страховка: запись без type в конфиг не уходит', () {
    test('тело чужого диалекта снимается с предупреждением на узле', () {
      // Ровно то, что уезжало в `outbounds[]` до починки: Xray-тело.
      final bad = Outbound(<String, dynamic>{
        'tag': 'xray-body',
        'protocol': 'vless',
        'settings': {'vnext': []},
        'streamSettings': {'network': 'tcp'},
      });
      final good = Outbound(<String, dynamic>{
        'type': 'trojan',
        'tag': 'ok',
        'server': 'example.com',
        'server_port': 443,
        'password': 'p',
      });

      final report = applyRegistryGate([bad, good], coreVersion: _core);

      expect(report.dropped, contains(bad));
      expect(report.dropped, isNot(contains(good)));
      expect(report.warnings.where((w) => w.startsWith('xray-body: ')),
          hasLength(1));
    });

    test('пустой и нестроковый type — тоже снимается', () {
      final empty = Outbound(<String, dynamic>{'type': '', 'tag': 'e'});
      final num0 = Outbound(<String, dynamic>{'type': 7, 'tag': 'n'});
      final report =
          applyRegistryGate([empty, num0], coreVersion: _core);
      expect(report.dropped, hasLength(2));
    });
  });

  group('эталоны при загруженном реестре', () {
    for (final name in kStorageFixtures) {
      test('$name: config.json не изменился', () async {
        final box = await StorageSandbox.create();
        addTearDown(box.dispose);
        await box.seed(name);

        final built = await buildGoldenConfig(box);
        // Тот же эталон, что сверяет storage_migration/golden_config_test —
        // гард обязан быть прозрачен для валидного конфига.
        expectGolden('$name.config.json', built.configJson);
        expectGolden('$name.config_warnings.json', prettyJson(built.warnings));
      });
    }
  });
}
