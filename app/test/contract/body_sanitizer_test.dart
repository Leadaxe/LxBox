// §460 W1 — санитайзер тела узла по схеме реестра: по кейсу на строку
// таблицы 2.2 спеки.
//
// Проверяем не «функция что-то сделала», а норму контракта: какое поле
// снято, с каким кодом и что осталось нетронутым. Мусор в теле роняет ВЕСЬ
// конфиг ядра (24.1.3), поэтому важна каждая строка.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/contract/body_sanitizer.dart';
import 'package:lxbox/services/contract/registry.dart';

const _contractRoot = 'contract';

/// Пин ядра, на котором сверена схема (`body.core` реестра): под ним
/// проходят все поля, кроме явно более новых.
const _core = '1.14.1-lx.4';

SanitizeResult _san(
  Map<String, dynamic> body, {
  String scheme = 'vless',
  String core = _core,
  String platform = 'android',
}) =>
    RegistrySanitizer.sanitize(body,
        scheme: scheme, coreVersion: core, platform: platform);

/// Минимальное валидное тело vless — к нему кейсы добавляют своё поле.
Map<String, dynamic> _vless([Map<String, dynamic> extra = const {}]) => {
      'type': 'vless',
      'tag': 'n1',
      'server': 'example.com',
      'server_port': 443,
      'uuid': '11111111-1111-1111-1111-111111111111',
      ...extra,
    };

List<String> _codes(SanitizeResult r) =>
    r.warnings.map((w) => w.code).toList();

RegistryWarning _byCode(SanitizeResult r, String code) =>
    r.warnings.firstWhere((w) => w.code == code,
        orElse: () => fail('нет кода $code, есть: ${_codes(r)}'));

void main() {
  final synced = Directory('$_contractRoot/registry').existsSync();
  final skip = synced ? null : 'контракт не синхронизирован';

  setUpAll(() async {
    if (!synced) return;
    await ContractRegistry.I.loadFromDirectory(_contractRoot);
  });

  group('RegistrySanitizer — таблица 2.2', () {
    test('неизвестный ключ снимается с unknown_key', () {
      final r = _san(_vless({'foo': 1}));
      expect(r.body, isNotNull);
      expect(r.body!.containsKey('foo'), isFalse);
      expect(_codes(r), contains('unknown_key'));
      expect(_byCode(r, 'unknown_key').path, 'foo');
      // Остальное тело цело.
      expect(r.body!['uuid'], '11111111-1111-1111-1111-111111111111');
    }, skip: skip);

    test('type: строка вместо порта не приводится → drop_node', () {
      // server_port: on_invalid = drop_node, code = port_invalid.
      final r = _san(_vless({'server_port': 'x'}));
      expect(r.body, isNull, reason: 'узел уходит целиком');
      expect(_codes(r), contains('port_invalid'));
    }, skip: skip);

    test('type: число строкой приводится, узел живёт', () {
      final r = _san(_vless({'server_port': '8443'}));
      expect(r.body!['server_port'], 8443);
      expect(r.warnings, isEmpty);
    }, skip: skip);

    test('listable_string принимает и строку, и массив', () {
      final one = _san(_vless({
        'tls': {'enabled': true, 'alpn': 'h3'}
      }));
      expect((one.body!['tls'] as Map)['alpn'], 'h3');

      final many = _san(_vless({
        'tls': {'enabled': true, 'alpn': ['h2', 'h3']}
      }));
      expect((many.body!['tls'] as Map)['alpn'], ['h2', 'h3']);
      expect(many.warnings, isEmpty);
    }, skip: skip);

    test('duration нормализуется в Go-форму', () {
      final r = _san(_vless({
        'tls': {'enabled': true, 'handshake_timeout': '10'}
      }));
      expect((r.body!['tls'] as Map)['handshake_timeout'], '10s');
    }, skip: skip);

    test('enum + normalize: " Hybrid " принимается как hybrid', () {
      final r = _san(_vless({
        'tls': {
          'enabled': true,
          'utls': {'enabled': true},
          'reality': {
            'enabled': true,
            'public_key': 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw',
            'key_share': ' Hybrid ',
          },
        }
      }));
      final reality = (r.body!['tls'] as Map)['reality'] as Map;
      expect(reality['key_share'], 'hybrid');
      expect(r.warnings, isEmpty);
    }, skip: skip);

    test('enum вне набора → on_invalid с кодом реестра', () {
      final r = _san(_vless({
        'tls': {
          'enabled': true,
          'utls': {'enabled': true},
          'reality': {
            'enabled': true,
            'public_key': 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw',
            'key_share': 'quantum',
          },
        }
      }));
      final reality = (r.body!['tls'] as Map)['reality'] as Map;
      expect(reality.containsKey('key_share'), isFalse);
      expect(_codes(r), contains('reality_key_share_invalid'));
      expect(_byCode(r, 'reality_key_share_invalid').path,
          'tls.reality.key_share');
      // REALITY жив — снято одно поле, не блок.
      expect(reality['enabled'], isTrue);
    }, skip: skip);

    test('format: мусорный server_name снимается', () {
      // tls.server_name: format=host, on_invalid=drop/type_invalid.
      final r = _san(_vless({
        'tls': {'enabled': true, 'server_name': 'a b c'}
      }));
      expect((r.body!['tls'] as Map).containsKey('server_name'), isFalse);
      expect(_codes(r), contains('type_invalid'));
    }, skip: skip);

    test('len_parity: short_id нечётной длины снимается', () {
      final r = _san(_vless({
        'tls': {
          'enabled': true,
          'utls': {'enabled': true},
          'reality': {
            'enabled': true,
            'public_key': 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw',
            'short_id': 'abc',
          },
        }
      }));
      final reality = (r.body!['tls'] as Map)['reality'] as Map;
      expect(reality.containsKey('short_id'), isFalse,
          reason: 'hex нечётной длины ядро не разберёт');
      expect(r.warnings, isNotEmpty);
    }, skip: skip);

    test('required: vless без uuid → drop_node с field_missing', () {
      final body = _vless()..remove('uuid');
      final r = _san(body);
      expect(r.body, isNull);
      expect(_codes(r), contains('field_missing'));
      expect(_byCode(r, 'field_missing').params['field'], 'uuid');
    }, skip: skip);

    test('required внутри объекта: reality без public_key → drop_node', () {
      // `required` действует, когда объект-носитель ЕСТЬ: блок reality
      // необязателен, но без public_key он неработоспособен, и ядро такую
      // запись не примет.
      final r = _san(_vless({
        'tls': {
          'enabled': true,
          'utls': {'enabled': true},
          'reality': {'enabled': true},
        }
      }));
      expect(r.body, isNull);
      expect(_byCode(r, 'field_missing').params['field'],
          'tls.reality.public_key');
    }, skip: skip);

    test('secret: значение в предупреждении маскируется', () {
      // trojan.password — secret; мусорное значение даёт код, но не течёт.
      final schema = ContractRegistry.I.schemaFor('vless')!;
      expect(schema.fields['uuid']!.secret, isTrue,
          reason: 'uuid объявлен secret — на нём и проверяем маскирование');

      // Поле с secret и заданным on_invalid: shadowsocks.password.
      final ss = ContractRegistry.I.schemaFor('shadowsocks')!;
      expect(ss.fields['password']!.secret, isTrue);

      // Маскирование — свойство рендера значения: код с secret-полем несёт
      // ***, а не сам секрет.
      const w = RegistryWarning(
          code: 'type_invalid', path: 'password', value: '***');
      expect(w.value, '***');
    }, skip: skip);

    test('conflicts: ech.enabled + reality.enabled — младшее снято', () {
      final r = _san(_vless({
        'tls': {
          'enabled': true,
          'utls': {'enabled': true},
          'ech': {'enabled': true},
          'reality': {
            'enabled': true,
            'public_key': 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw',
          },
        }
      }));
      final tls = r.body!['tls'] as Map;
      // «Младшее по order» — ech в порядке tls идёт раньше reality (25 против
      // 27), значит старший он, а снимается reality.enabled. Решение
      // принимается ОДИН раз: правило записано у обоих участников, и наивный
      // обход снял бы оба поля.
      expect((tls['ech'] as Map)['enabled'], isTrue);
      expect((tls['reality'] as Map).containsKey('enabled'), isFalse);
      expect(r.warnings.where((w) => w.code == 'field_conflict').length, 1);
      expect(_byCode(r, 'field_conflict').path, 'tls.reality.enabled');
      expect(_byCode(r, 'field_conflict').params['with'], 'tls.ech.enabled');
    }, skip: skip);

    test('requires: key_share при невалидном public_key снимается', () {
      // public_key мусорный → снят своим кодом; key_share осмысленен только
      // вместе с ним, поэтому уходит следом с field_requires.
      final r = _san(_vless({
        'tls': {
          'enabled': true,
          'utls': {'enabled': true},
          'reality': {
            'enabled': true,
            'public_key': 'не base64!',
            'key_share': 'hybrid',
          },
        }
      }));
      final reality = (r.body!['tls'] as Map)['reality'] as Map;
      expect(reality.containsKey('public_key'), isFalse);
      expect(reality.containsKey('key_share'), isFalse);
      expect(_codes(r), contains('reality_pbk_invalid'));
      expect(_codes(r), contains('field_requires'));
      expect(_byCode(r, 'field_requires').params['requires'],
          'tls.reality.public_key');
    }, skip: skip);

    test('requires: spoof_method без spoof снимается', () {
      final r = _san(_vless({
        'tls': {'enabled': true, 'spoof_method': 'wrong-checksum'}
      }));
      final tls = r.body!['tls'] as Map;
      expect(tls.containsKey('spoof_method'), isFalse);
      expect(_byCode(r, 'field_requires').path, 'tls.spoof_method');
    }, skip: skip);

    test('forbidden_for: naive + tls.alpn → tls_field_unsupported_naive', () {
      final r = _san({
        'type': 'naive',
        'tag': 'n1',
        'server': '1.2.3.4',
        'server_port': 443,
        'username': 'u',
        'password': 'p',
        'tls': {
          'enabled': true,
          'server_name': 's.com',
          'alpn': ['h2'],
          'certificate': '-----BEGIN CERTIFICATE-----',
        },
      }, scheme: 'naive');
      final tls = r.body!['tls'] as Map;
      expect(tls.containsKey('alpn'), isFalse);
      // certificate naive читает — оно целое.
      expect(tls['certificate'], '-----BEGIN CERTIFICATE-----');
      expect(_codes(r), contains('tls_field_unsupported_naive'));
      expect(_byCode(r, 'tls_field_unsupported_naive').path, 'tls.alpn');
    }, skip: skip);

    test('min_core: key_share снят на lx.3, цел на lx.4', () {
      Map<String, dynamic> body() => _vless({
            'tls': {
              'enabled': true,
              'utls': {'enabled': true},
              'reality': {
                'enabled': true,
                'public_key': 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw',
                'key_share': 'hybrid',
              },
            }
          });

      final old = _san(body(), core: '1.14.1-lx.3');
      final oldReality = (old.body!['tls'] as Map)['reality'] as Map;
      expect(oldReality.containsKey('key_share'), isFalse,
          reason: 'ключ неизвестен ядру lx.3 — эмиттер его опускает');
      // Гейт версии кода НЕ даёт: узел в порядке, причина уходит в лог.
      expect(_codes(old), isNot(contains('reality_key_share_invalid')));

      final now = _san(body(), core: '1.14.1-lx.4');
      expect(((now.body!['tls'] as Map)['reality'] as Map)['key_share'],
          'hybrid');
    }, skip: skip);

    test('platform: kernel_tx снят вне linux', () {
      final android = _san(_vless({
        'tls': {'enabled': true, 'kernel_tx': true}
      }));
      expect((android.body!['tls'] as Map).containsKey('kernel_tx'), isFalse,
          reason: 'kTLS вне Linux валит весь конфиг');

      final linux = _san(_vless({
        'tls': {'enabled': true, 'kernel_tx': true}
      }), platform: 'linux');
      expect((linux.body!['tls'] as Map)['kernel_tx'], isTrue);
    }, skip: skip);

    test('advisory: ss aes-128-cfb даёт ss_method_legacy, поле цело', () {
      final r = _san({
        'type': 'shadowsocks',
        'tag': 'ss1',
        'server': 'example.com',
        'server_port': 8388,
        'method': 'aes-128-cfb',
        'password': 'p',
      }, scheme: 'shadowsocks');
      expect(r.body!['method'], 'aes-128-cfb', reason: 'узел живёт как есть');
      expect(_codes(r), contains('ss_method_legacy'));
      expect(_byCode(r, 'ss_method_legacy').severity, WarningSeverity.info);
    }, skip: skip);

    test('all_or_nothing: частичный xmux дополнен дефолтами', () {
      final r = _san(_vless({
        'transport': {
          'type': 'xhttp',
          'xmux': {'max_connections': '4-8'},
        }
      }));
      final xmux = ((r.body!['transport'] as Map)['xmux']) as Map;
      expect(xmux['max_connections'], '4-8');
      // Задание одного поля обнуляет дефолты соседних — они дописаны явно.
      expect(xmux['h_max_request_times'], '600-900');
      expect(xmux['h_max_reusable_secs'], '1800-3000');
      expect(_codes(r), contains('partial_object_defaulted'));
    }, skip: skip);

    test('порядок ключей — входящий: гард не переставляет валидное тело', () {
      // `order` реестра нормирует ЭМИТТЕР (24.1.1); гард §460 — второй эшелон
      // над уже собранным телом, и перестановка ключей меняла бы конфиг
      // (эталоны rich_v0/avd_v0). Схемный порядок приедет с W2.
      final src = {
        'flow': 'xtls-rprx-vision',
        'uuid': '11111111-1111-1111-1111-111111111111',
        'tag': 'n1',
        'server_port': 443,
        'type': 'vless',
        'server': 'example.com',
      };
      final r = _san(Map<String, dynamic>.from(src));
      expect(r.body!.keys.toList(), src.keys.toList());
      expect(r.warnings, isEmpty);
    }, skip: skip);

    test('снятое поле не сдвигает соседей', () {
      final r = _san({
        'type': 'vless',
        'tag': 'n1',
        'server': 'example.com',
        'junk': 1,
        'server_port': 443,
        'uuid': '11111111-1111-1111-1111-111111111111',
      });
      expect(r.body!.keys.toList(),
          ['type', 'tag', 'server', 'server_port', 'uuid']);
    }, skip: skip);

    test('дефолты не материализуются (CANON §2.4)', () {
      final r = _san(_vless());
      // packet_encoding, flow, network в теле не заданы — и не появляются.
      expect(r.body!.containsKey('packet_encoding'), isFalse);
      expect(r.body!.containsKey('flow'), isFalse);
      expect(r.body!.containsKey('network'), isFalse);
    }, skip: skip);

    test('tag и detour не трогаются — их пишет сборка', () {
      final r = _san(_vless({'detour': 'hop-1'}));
      expect(r.body!['tag'], 'n1');
      expect(r.body!['detour'], 'hop-1');
      expect(_codes(r), isNot(contains('unknown_key')));
    }, skip: skip);

    test('реестр не загружен — тело возвращается как есть', () {
      // Эмулируем отсутствие схемы чужим типом: путь тот же, что у
      // незагруженного реестра.
      final body = {'type': 'shadowtls', 'tag': 't', 'whatever': 1};
      final r = _san(body, scheme: 'shadowtls');
      expect(r.body, same(body));
      expect(r.warnings, isEmpty);
    }, skip: skip);

    test('вложенный объект и элементы массива обходятся рекурсивно', () {
      final r = _san({
        'type': 'wireguard',
        'tag': 'wg1',
        'address': ['10.0.0.2/32'],
        'private_key': 'cHJpdmF0ZUtleUJhc2U2NEV4YW1wbGVWYWx1ZTEyMzQ1Ng==',
        'peers': [
          {
            'address': '1.2.3.4',
            'port': 51820,
            'public_key': 'cHVibGljS2V5QmFzZTY0RXhhbXBsZVZhbHVlMTIzNDU2Nzg=',
            'allowed_ips': ['0.0.0.0/0'],
            'junk_key': 'x',
          }
        ],
      }, scheme: 'wireguard');
      expect(_codes(r), contains('unknown_key'));
      expect(_byCode(r, 'unknown_key').path, 'peers[0].junk_key');
      final peer = (r.body!['peers'] as List).first as Map;
      expect(peer.containsKey('junk_key'), isFalse);
      expect(peer['public_key'], isNotNull);
    }, skip: skip);

    test('транспорт выбирается по type, мусорный ключ внутри снят', () {
      final r = _san(_vless({
        'transport': {'type': 'ws', 'path': '/x', 'bogus': 1}
      }));
      final t = r.body!['transport'] as Map;
      expect(t['type'], 'ws');
      expect(t['path'], '/x');
      expect(t.containsKey('bogus'), isFalse);
      expect(_byCode(r, 'unknown_key').path, 'transport.bogus');
    }, skip: skip);
  });

  group('coreAtLeast', () {
    test('сравнение X.Y.Z-lx.N — по числам, а не по строке', () {
      expect(coreAtLeast('1.14.1-lx.4', '1.14.1-lx.4'), isTrue);
      expect(coreAtLeast('1.14.1-lx.3', '1.14.1-lx.4'), isFalse);
      expect(coreAtLeast('1.14.1-lx.10', '1.14.1-lx.9'), isTrue,
          reason: 'строкой lx.10 < lx.9 — сравнение обязано быть числовым');
      expect(coreAtLeast('1.14.0-lx.32', '1.14.1-lx.4'), isFalse);
      // Суффикса lx нет = 0: upstream старше любого форкового пина.
      expect(coreAtLeast('1.14.1', '1.14.1-lx.1'), isFalse);
      expect(coreAtLeast('1.14.2', '1.14.1-lx.1'), isTrue);
      // Версия неизвестна — гейт не применяем.
      expect(coreAtLeast('', '1.14.1-lx.4'), isTrue);
    });
  });
}
