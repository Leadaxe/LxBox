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

    // §470 — `unknown_key` несёт и СНЯТОЕ ЗНАЧЕНИЕ: конверт корпуса называет
    // его (`body/singbox/manual_object_junk`), и лаунчер печатает `src[name]`
    // (`nodeflow/sanitize.go`). Без `value` человек узнавал, что ключ снят,
    // но не ЧТО снято, а body-раннер расходился с контрактом молча — ровно
    // тот дефект, ради которого §470 включил сверку `warnings[]`.
    test('unknown_key несёт снятое значение', () {
      final r = _san(_vless({'totally_unknown_key': 'whatever'}));
      expect(_byCode(r, 'unknown_key').value, 'whatever');
    }, skip: skip);

    // Форма `value` нормативна (CANON §6): объект — `map[k:v k:v]` с ключами
    // по алфавиту, и у снятого ключа она та же, что у прочих кодов.
    test('unknown_key печатает объект по канону корпуса', () {
      final r = _san(_vless({
        'totally_unknown_key': {'b': 2, 'a': true}
      }));
      expect(_byCode(r, 'unknown_key').value, 'map[a:true b:2]');
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

    test('required внутри объекта: reality без public_key → снят БЛОК, узел жив',
        () {
      // §472 шаг 5 — единица отказа у вложенного `required` это САМ ОБЪЕКТ, а
      // не узел. Реестр пишет это прямо (`tls.json` → `reality.public_key`,
      // impl): «public_key здесь required, поэтому мусорный pbk снимает блок
      // целиком и узел деградирует до plain TLS».
      //
      // Прежнее ожидание («drop_node») читало правило корневым и роняло весь
      // узел. Тем же чтением ронялся hysteria2 без `obfs-password`, хотя и
      // реестр, и текст кода `obfs_password_missing`, и ожидание корпуса
      // (`uri/hysteria2/obfs_no_password_dropped`) говорят «узел живёт без
      // обфускации». На корне правило не изменилось — тест выше
      // («vless без uuid → drop_node») зелёный.
      final r = _san(_vless({
        'tls': {
          'enabled': true,
          'utls': {'enabled': true},
          'reality': {'enabled': true},
        }
      }));
      expect(r.body, isNotNull, reason: 'узел деградирует до plain TLS');
      expect((r.body!['tls'] as Map).containsKey('reality'), isFalse,
          reason: 'снят весь блок REALITY');
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

    test('conflicts: ech.enabled + reality.enabled — снят декларант', () {
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
      // §474 (контракт 1.1.6) — снимается ДЕКЛАРАНТ, то есть поле, у которого
      // правило записано. Пара симметричная: `conflicts` есть у обоих, обход
      // идёт по `order`, и первым разбирается `ech` (25) — он и уступает.
      // `reality` (27) к своей очереди соседа уже не видит и остаётся.
      //
      // До §474 тут снималось «младшее по order» — то есть `reality`, — и это
      // было ошибкой прочтения контракта: лаунчер (`nodeflow/sanitize.go` →
      // `relationsOK`) всегда снимал сторону-декларанта. Тело узла от смены
      // не пострадало ни в корпусе, ни в golden: пар, где заданы обе стороны,
      // там нет вовсе — единственный `field_conflict` корпуса
      // (`certificate_public_key_sha256`) обе семантики решают одинаково.
      expect((tls['ech'] as Map).containsKey('enabled'), isFalse);
      expect((tls['reality'] as Map)['enabled'], isTrue);
      // Код ровно ОДИН: снятый декларант перестаёт быть соседом, и второй
      // участник пары своего правила не исполняет.
      expect(r.warnings.where((w) => w.code == 'field_conflict').length, 1);
      expect(_byCode(r, 'field_conflict').path, 'tls.ech.enabled');
      expect(_byCode(r, 'field_conflict').params['with'], 'tls.reality.enabled');
    }, skip: skip);

    test('requires: key_share при невалидном public_key снимается МОЛЧА', () {
      // public_key мусорный → снят своим кодом; key_share осмысленен только
      // вместе с ним, поэтому уходит следом.
      //
      // §472 шаг 3 — СЛЕДОМ И МОЛЧА. Второго кода потеря зависимого поля не
      // заслуживает: человек уже прочёл, почему ушёл `public_key`, а
      // «`key_share` требует `public_key`» добавляет к этому только шум.
      // Корпус нормирует ровно так — у `vless/reality_pbk_junk_degrade`,
      // `tls_pbk_junk_enabled` и `reality_key_share_without_pbk_ignored` в
      // ожидании ОДИН код, `reality_pbk_invalid`, а комментарий последнего
      // говорит прямо: «снят не он, а весь блок, поэтому кода
      // reality_key_share_invalid НЕТ». До шага 3 расхождение было латентным:
      // на URI-вход санитайзер не смотрел, а в JSON-корпусе такого тела нет.
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
      // §472 шаг 5 — блок уходит ЦЕЛИКОМ (`public_key` у него `required`), и
      // это ровно то, что говорит комментарий корпуса выше: «снят не он, а
      // весь блок». Код по-прежнему один.
      expect((r.body!['tls'] as Map).containsKey('reality'), isFalse);
      expect(_codes(r), ['reality_pbk_invalid']);
    }, skip: skip);

    test('requires: поля, которого НЕ БЫЛО, объясняет только field_requires',
        () {
      // Обратная граница к тесту выше: `spoof` в теле не писали вовсе, и
      // другого объяснения потере `spoof_method` нет — код обязан быть.
      final r = _san(_vless({
        'tls': {'enabled': true, 'spoof_method': 'wrong-checksum'}
      }));
      expect(_codes(r), contains('field_requires'));
      expect(_byCode(r, 'field_requires').params['requires'], 'tls.spoof');
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

    // §467 — `all_or_nothing` действия санитайзера НЕ влечёт.
    //
    // Атрибут читался наоборот. Ядро при частично заданной секции оставляет
    // незаданные поля нулями (= без лимита), поэтому дописывание дефолтов
    // навязывало узлу лимиты, которых у него не было (контракт §24.9).
    test('all_or_nothing: частичный xmux проходит как есть, без дефолтов', () {
      final r = _san(_vless({
        'transport': {
          'type': 'xhttp',
          'xmux': {'max_connections': '4-8'},
        }
      }));
      final xmux = ((r.body!['transport'] as Map)['xmux']) as Map;
      expect(xmux['max_connections'], '4-8');
      expect(xmux.containsKey('h_max_request_times'), isFalse,
          reason: 'дефолт соседа не дописывается');
      expect(xmux.containsKey('h_max_reusable_secs'), isFalse);
      expect(xmux.keys.toList(), ['max_connections'],
          reason: 'секция байт в байт та, что пришла');
      expect(_codes(r), isEmpty);
    }, skip: skip);

    // §467 — `conflicts` судит ЗНАЧЕНИЕ, а не наличие ключа (контракт §24.9).
    group('§467 conflicts по значению', () {
      test('xmux в полной форме с нулями: конфликта нет, тело не изменено', () {
        // Ровно та секция, на которой у лаунчера испортились 13 живых узлов:
        // провайдер выписывает незаданные поля нулями.
        final xmuxIn = {
          'max_concurrency': '16-32',
          'max_connections': '0',
          'c_max_reuse_times': '0',
          'h_max_request_times': '600-900',
          'h_max_reusable_secs': '1800-3000',
          'h_keep_alive_period': 0,
        };
        final r = _san(_vless({
          'transport': {
            'type': 'xhttp',
            'xmux': Map<String, dynamic>.from(xmuxIn),
          }
        }));
        final xmux = ((r.body!['transport'] as Map)['xmux']) as Map;
        expect(xmux['max_concurrency'], '16-32',
            reason: 'рабочее значение остаётся: "0" у соседа = не задано');
        expect(Map<String, dynamic>.from(xmux.cast<String, dynamic>()), xmuxIn,
            reason: 'тело байт в байт');
        expect(_codes(r), isEmpty);
      }, skip: skip);

      test('оба > 0 — конфликт как раньше', () {
        final r = _san(_vless({
          'transport': {
            'type': 'xhttp',
            'xmux': {'max_concurrency': '16-32', 'max_connections': '4-8'},
          }
        }));
        expect(_codes(r), contains('field_conflict'));
        final xmux = ((r.body!['transport'] as Map)['xmux']) as Map;
        // Снимается младшее по порядку схемы, старшее остаётся.
        expect(
            xmux.containsKey('max_concurrency') &&
                xmux.containsKey('max_connections'),
            isFalse);
      }, skip: skip);

      test('«0-0» у соседа — тоже не задано', () {
        final r = _san(_vless({
          'transport': {
            'type': 'xhttp',
            'xmux': {'max_concurrency': '16-32', 'max_connections': '0-0'},
          }
        }));
        expect(_codes(r), isEmpty);
        final xmux = ((r.body!['transport'] as Map)['xmux']) as Map;
        expect(xmux['max_concurrency'], '16-32');
      }, skip: skip);
    });

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
        // §464 — ключи ровно 32 байта после декода (format base64_32):
        // прежние 34/35-байтовые ядро отвергало фаталом на весь конфиг, и
        // санитайзер теперь снимает узел целиком, не дойдя до junk_key.
        'private_key': 'cHJpdmF0ZUtleUJhc2U2NEV4YW1wbGVWYWx1ZTEyMzQ=',
        'peers': [
          {
            'address': '1.2.3.4',
            'port': 51820,
            'public_key': 'cHVibGljS2V5QmFzZTY0RXhhbXBsZVZhbHVlMTIzNDU=',
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

  // §464 — выражения реестра, приехавшие с W2d лаунчера. По кейсу на
  // выражение: реестр нормативен для обеих сторон, и «санитайзер молча не
  // знает правила» неотличимо от «правила нет».
  // §470 — форма `value` нормативна для ВСЕХ реализаций (CANON §6, лаунчер
  // `8068f7a0`): корпус сверяет её побайтно, и своего смысла у неё нет —
  // это Go-печать `%v`, которую не-Go сторона воспроизводит сама. Кейс на
  // каждое правило текста канона: скаляр, объект, массив, вложенность,
  // обрезка по рунам, `secret`.
  group('renderWarningValue — CANON §6', () {
    test('скаляр — как есть, без кавычек', () {
      expect(RegistrySanitizer.renderWarningValue(true), 'true');
      expect(RegistrySanitizer.renderWarningValue(443), '443');
      expect(RegistrySanitizer.renderWarningValue('h3'), 'h3');
    });

    test('объект — map[k:v k:v] с ключами по алфавиту', () {
      expect(
        RegistrySanitizer.renderWarningValue(
            {'fingerprint': 'chrome', 'enabled': true}),
        'map[enabled:true fingerprint:chrome]',
      );
    });

    test('вложенный объект печатается тем же правилом', () {
      expect(
        RegistrySanitizer.renderWarningValue({
          'b': {'y': 2, 'x': 1},
          'a': 0,
        }),
        'map[a:0 b:map[x:1 y:2]]',
      );
    });

    test('массив — [a b c], порядок сохраняется', () {
      expect(RegistrySanitizer.renderWarningValue(['h2', 'http/1.1']),
          '[h2 http/1.1]');
      expect(RegistrySanitizer.renderWarningValue([]), '[]');
    });

    test('обрезка — 64 РУНЫ и многоточие U+2026', () {
      // Ровно 64 руны не трогаются; 65-я даёт хвост `…`.
      final exact = 'a' * 64;
      expect(RegistrySanitizer.renderWarningValue(exact), exact);
      final long = 'a' * 65;
      expect(RegistrySanitizer.renderWarningValue(long), '${'a' * 64}…');
    });

    test('обрезка считает РУНЫ, а не кодовые единицы UTF-16', () {
      // Эмодзи вне BMP = две кодовые единицы на руну: по байтам строка из 64
      // эмодзи давно перевалила бы лимит, по рунам — ровно на границе.
      final runes64 = '🙂' * 64;
      expect(RegistrySanitizer.renderWarningValue(runes64), runes64);
      expect(RegistrySanitizer.renderWarningValue('🙂' * 65), '$runes64…');
    });

    test('secret-поле — *** вместо значения', () {
      expect(
        RegistrySanitizer.renderWarningValue('hunter2', secret: true),
        '***',
      );
    });
  });

  group('RegistrySanitizer — выражения W2d (§464)', () {
    test('format base64_32: ключ не 32 байта после декода — REALITY снят', () {
      // `enabled` — валидный base64 на 5 байт: прежний format base64 его
      // пропускал, и ядро отвечало «invalid public_key» на ВЕСЬ конфиг.
      final r = _san(_vless({
        'tls': {
          'enabled': true,
          'reality': {'enabled': true, 'public_key': 'enabled'},
        }
      }));
      expect(_byCode(r, 'reality_pbk_invalid').path, 'tls.reality.public_key');
      expect(_byCode(r, 'reality_pbk_invalid').value, 'enabled');
      // §472 шаг 5 — снимается ВЕСЬ блок, а не одно поле: `public_key` у
      // REALITY `required`, и реестр пишет исход прямо (`tls.json` →
      // `reality.public_key`, impl): «мусорный pbk снимает блок целиком и
      // узел деградирует до plain TLS». Прежде оставался блок без ключа —
      // форма, которую ядро не принимает.
      expect(r.body, isNotNull, reason: 'узел жив, деградировал до plain TLS');
      expect((r.body!['tls'] as Map).containsKey('reality'), isFalse);
    }, skip: skip);

    test('format base64_32: ровно 32 байта проходят в любом написании', () {
      // Одни и те же 32 байта: base64url без паддинга и base64 std с ним.
      for (final key in const [
        'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw',
        'cHVibGljS2V5QmFzZTY0RXhhbXBsZVZhbHVlMTIzNDU=',
      ]) {
        final r = _san(_vless({
          'tls': {
            'enabled': true,
            'reality': {'enabled': true, 'public_key': key},
          }
        }));
        expect(_codes(r), isNot(contains('reality_pbk_invalid')),
            reason: '$key — 32 байта после декода');
      }
    }, skip: skip);

    test('format base64_32: НЕКАНОНИЧЕСКАЯ последняя группа — годный ключ',
        () {
      // D-030 — `…ccC=` и `…ccA=` декодируют в ОДНИ И ТЕ ЖЕ 32 байта: в
      // последней группе значащих бит 6, остальные не используются, и ядро
      // (Go `encoding/base64`) такую форму принимает. Строгий `dart:convert`
      // бросает на ней `FormatException`, и санитайзер, судивший им, ронял
      // ЗАКОННЫЙ ключ — корпус `uri_psk_keepalive` (ключи в query) переставал
      // разбираться целиком.
      final r = _san(_vless({
        'tls': {
          'enabled': true,
          'reality': {
            'enabled': true,
            'public_key': 'ccccccccccccccccccccccccccccccccccccccccccC=',
          },
        }
      }));
      expect(_codes(r), isNot(contains('reality_pbk_invalid')));
      // Контракт 1.1.40 — у `public_key` REALITY объявлен ещё и
      // `normalize: base64_rawurl`, поэтому годный ключ приводится к форме
      // ЯДРА: url-safe алфавит без паддинга. Ядро декодирует этот ключ только
      // `RawURLEncoding`, и std-написание роняет ВЕСЬ конфиг.
      //
      // Проверяется ровно то, ради чего кейс заведён: ленивый декодер СУДИТ
      // неканоническую последнюю группу так же, как ядро, — а нормализация,
      // признав ключ годным, записывает его канон.
      expect(
        ((r.body?['tls'] as Map?)?['reality'] as Map?)?['public_key'],
        'ccccccccccccccccccccccccccccccccccccccccccA',
      );
    }, skip: skip);

    test('int_array: границы min/max относятся к ЭЛЕМЕНТУ', () {
      // `peers[].reserved` — три БАЙТА (`min: 0, max: 255, len: 3`). Прежде
      // ветка списка проверяла только длину и возвращалась, границы не
      // смотрел никто: `reserved=1,2,999` уезжал в ядро целым числом,
      // которое в байт не влезает.
      Map<String, dynamic> wg(List<Object> reserved) => {
            'type': 'wireguard',
            'tag': 'wg',
            'private_key': 'ccccccccccccccccccccccccccccccccccccccccccA=',
            'address': ['10.0.0.3/32'],
            'peers': [
              {
                'public_key': 'ddddddddddddddddddddddddddddddddddddddddddA=',
                'address': 'h.example',
                'port': 51820,
                'allowed_ips': ['0.0.0.0/0'],
                'reserved': reserved,
              }
            ],
          };

      final bad = _san(wg([1, 2, 999]), scheme: 'wireguard');
      expect(_codes(bad), contains('type_invalid'));
      expect(
        ((bad.body?['peers'] as List?)?.first as Map?)?.containsKey('reserved'),
        isFalse,
        reason: 'элемент вне 0..255 — поле снято целиком',
      );

      // Контраст: те же три элемента внутри границ проходят нетронутыми.
      final ok = _san(wg([1, 2, 3]), scheme: 'wireguard');
      expect(_codes(ok), isNot(contains('type_invalid')));
      expect(((ok.body?['peers'] as List).first as Map)['reserved'],
          [1, 2, 3]);
    }, skip: skip);

    test('normalize base64_std: неканоническая форма приводится к канону', () {
      // Та же пара байт, но у поля объявлен `normalize: base64_std` — здесь
      // канон ОБЯЗАН встать, иначе одна нода даёт два identity-хеша (D-030).
      // Канон и суд читают значение одним ленивым декодером.
      final r = _san({
        'type': 'wireguard',
        'tag': 'wg',
        'private_key': 'ccccccccccccccccccccccccccccccccccccccccccC=',
        'address': ['10.0.0.3/32'],
        'peers': [
          {
            'public_key': 'ddddddddddddddddddddddddddddddddddddddddddD=',
            'address': 'h.example',
            'port': 51820,
            'allowed_ips': ['0.0.0.0/0'],
          }
        ],
      }, scheme: 'wireguard');
      expect(_codes(r), isNot(contains('wg_key_invalid')),
          reason: 'коды: ${_codes(r)}');
      expect(r.body, isNotNull, reason: 'коды: ${_codes(r)}');
      expect(r.body?['private_key'],
          'ccccccccccccccccccccccccccccccccccccccccccA=');
    }, skip: skip);

    test('normalize hex_only + normalize_code: 0x1a2 чистится с кодом', () {
      final r = _san(_vless({
        'tls': {
          'enabled': true,
          'reality': {
            'enabled': true,
            'public_key': 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw',
            'short_id': '0x1a2',
          },
        }
      }));
      final reality = (r.body!['tls'] as Map)['reality'] as Map;
      // Не-hex руны сняты, регистр опущен: `0x1a2` → `01a2`.
      expect(reality['short_id'], '01a2');
      // Код — на ИСХОДНОМ значении: человеку нужно видеть, что он написал.
      final w = _byCode(r, 'reality_short_id_invalid');
      expect(w.path, 'tls.reality.short_id');
      expect(w.value, '0x1a2');
    }, skip: skip);

    test('normalize hex_only: значение без потерь кода не даёт', () {
      final r = _san(_vless({
        'tls': {
          'enabled': true,
          'reality': {
            'enabled': true,
            'public_key': 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw',
            'short_id': '48ab12',
          },
        }
      }));
      expect(_codes(r), isNot(contains('reality_short_id_invalid')));
    }, skip: skip);

    test('advisory except+when: fp вне гибридных — код только при REALITY',
        () {
      Map<String, dynamic> tls({required bool reality}) => {
            'enabled': true,
            'utls': {'enabled': true, 'fingerprint': 'qq'},
            if (reality)
              'reality': {
                'enabled': true,
                'public_key': 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw',
              },
          };
      final withReality = _san(_vless({'tls': tls(reality: true)}));
      final w = _byCode(withReality, 'reality_fp_not_chrome');
      expect(w.path, 'tls.utls.fingerprint');
      expect(w.value, 'qq');
      // Поле НЕ меняется: выбор автора ссылки уезжает в конфиг как есть.
      expect(
          ((withReality.body!['tls'] as Map)['utls'] as Map)['fingerprint'],
          'qq');

      // `when` не выполнен — REALITY на узле нет, и код про него бессмыслен.
      final plain = _san(_vless({'tls': tls(reality: false)}));
      expect(_codes(plain), isNot(contains('reality_fp_not_chrome')));
    }, skip: skip);

    test('advisory except: гибридный отпечаток кода не получает', () {
      for (final fp in const ['chrome', 'firefox', 'safari', 'random']) {
        final r = _san(_vless({
          'tls': {
            'enabled': true,
            'utls': {'enabled': true, 'fingerprint': fp},
            'reality': {
              'enabled': true,
              'public_key': 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw',
            },
          }
        }));
        expect(_codes(r), isNot(contains('reality_fp_not_chrome')),
            reason: '$fp несёт гибридный key share');
      }
    }, skip: skip);

    test('requires equals: gecko-размеры на salamander снимаются', () {
      final r = _san({
        'type': 'hysteria2',
        'tag': 'h1',
        'server': 'example.com',
        'server_port': 443,
        'password': 'p',
        'tls': {'enabled': true},
        'obfs': {
          'type': 'salamander',
          'password': 'x',
          'min_packet_size': 100,
        },
      }, scheme: 'hysteria2');
      expect(_byCode(r, 'field_requires').path, 'obfs.min_packet_size');
      final obfs = r.body!['obfs'] as Map;
      expect(obfs.containsKey('min_packet_size'), isFalse);
      // Сама обфускация цела — снято только поле не своего типа.
      expect(obfs['type'], 'salamander');
    }, skip: skip);

    test('requires equals: на gecko те же размеры остаются', () {
      final r = _san({
        'type': 'hysteria2',
        'tag': 'h1',
        'server': 'example.com',
        'server_port': 443,
        'password': 'p',
        'tls': {'enabled': true},
        'obfs': {'type': 'gecko', 'password': 'x', 'min_packet_size': 100},
      }, scheme: 'hysteria2');
      expect(_codes(r), isNot(contains('field_requires')));
      expect((r.body!['obfs'] as Map)['min_packet_size'], 100);
    }, skip: skip);

    test('default_when: полоса hysteria v1 материализуется без кода', () {
      // Без up_mbps ядро отвечает «missing upload speed» и не поднимает
      // outbound — фатал на ВЕСЬ конфиг, а ссылки v1 полосу не несут.
      final r = _san({
        'type': 'hysteria',
        'tag': 'h1',
        'server': 'example.com',
        'server_port': 443,
        'tls': {'enabled': true},
      }, scheme: 'hysteria');
      expect(r.body!['up_mbps'], 100);
      expect(r.body!['down_mbps'], 100);
      expect(_codes(r), isEmpty, reason: 'узел жив и в порядке — кода нет');
    }, skip: skip);

    test('default_when не перебивает заданное значение', () {
      final r = _san({
        'type': 'hysteria',
        'tag': 'h1',
        'server': 'example.com',
        'server_port': 443,
        'up_mbps': 50,
        'tls': {'enabled': true},
      }, scheme: 'hysteria');
      expect(r.body!['up_mbps'], 50);
      expect(r.body!['down_mbps'], 100);
    }, skip: skip);

    test('§473 default_when с when: дефолт только у AmneziaWG-узла', () {
      Map<String, dynamic> wg({bool awg = false}) => {
            'type': 'wireguard',
            'tag': 'wg',
            if (awg) 'jc': 10,
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
          };

      final awg = _san(wg(awg: true), scheme: 'wireguard');
      expect(awg.body!['mtu'], 1280);
      expect(_codes(awg), isEmpty, reason: 'дефолт — не замена, кода нет');

      // Обычному WireGuard поля не достаётся: ядро берёт свой 1408, и наш
      // дефолт спорил бы с ним и ломал identity-хеш (CANON §2.4).
      final plain = _san(wg(), scheme: 'wireguard');
      expect(plain.body!.containsKey('mtu'), isFalse);
      expect(_codes(plain), isEmpty);
    }, skip: skip);

    test('§473 max_when: потолок, исключение по входу и род узла', () {
      Map<String, dynamic> body(int mtu, {bool awg = true}) => {
            'type': 'wireguard',
            'tag': 'wg',
            'mtu': mtu,
            if (awg) 'jc': 10,
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
          };

      // Вход не из `except_sources` — замена с warning-кодом на ИСХОДНОМ
      // значении.
      final clamped = RegistrySanitizer.sanitize(body(1420),
          scheme: 'wireguard', coreVersion: _core);
      expect(clamped.body!['mtu'], 1280);
      expect(clamped.warnings.single.code, 'awg_mtu_clamped');
      expect(clamped.warnings.single.path, 'mtu');
      expect(clamped.warnings.single.value, '1420');

      // Вход `singbox` — значение цело, код info.
      final kept = RegistrySanitizer.sanitize(body(1420),
          scheme: 'wireguard',
          coreVersion: _core,
          source: BodySource.singbox);
      expect(kept.body!['mtu'], 1420);
      expect(kept.warnings.single.code, 'awg_mtu_high');
      expect(kept.warnings.single.value, '1420');

      // Обычный WireGuard — правила нет ни на каком входе.
      for (final src in BodySource.values) {
        final plain = RegistrySanitizer.sanitize(body(1420, awg: false),
            scheme: 'wireguard', coreVersion: _core, source: src);
        expect(plain.body!['mtu'], 1420, reason: '$src');
        expect(plain.warnings, isEmpty, reason: '$src');
      }

      // Значение НИЖЕ потолка правило не трогает: потолок, а не дефолт.
      final low = RegistrySanitizer.sanitize(body(1200),
          scheme: 'wireguard', coreVersion: _core);
      expect(low.body!['mtu'], 1200);
      expect(low.warnings, isEmpty);
    }, skip: skip);

    test('§473 any_set судит НАЛИЧИЕ ключа, а не заданность значения', () {
      // Пара к §467: `conflicts`/`requires` судят значение, и `jc: 0` для них
      // «не задано». Здесь ровно наоборот — `jc: 0` значит «мусорные пакеты
      // выключены» у настоящего AmneziaWG, и потолок обязан остаться.
      // Смешай предикаты — туннель молча перестал бы нести данные.
      for (final marker in const [0, false, '', <String>[]]) {
        final r = RegistrySanitizer.sanitize({
          'type': 'wireguard',
          'tag': 'wg',
          'mtu': 1420,
          'jc': marker,
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
        }, scheme: 'wireguard', coreVersion: _core);
        expect(r.body!['mtu'], 1280, reason: 'jc=$marker — ключ есть');
        expect(r.warnings.map((w) => w.code), contains('awg_mtu_clamped'),
            reason: 'jc=$marker');
      }
    }, skip: skip);

    test('grpc service_name: нормализации нет — значение как есть', () {
      // §468 (контракт 1.1.3): правило `normalize: grpc_service_name` снято
      // целиком. Ведущий «/» разбирает ядро v1.14.1-lx.8 само, и любая
      // правка значения на нашей стороне сломала бы готовый путь.
      for (final v in const [
        'abcde',
        '/abcde',
        '/abcde/Tun',
        '/a/b/Tun',
        '/a/Stream',
        '/abcde/Tun|multi',
        'a/b',
      ]) {
        final r = _san(_vless({
          'transport': {'type': 'grpc', 'service_name': v}
        }));
        expect((r.body!['transport'] as Map)['service_name'], v, reason: v);
        expect(r.warnings, isEmpty, reason: v);
      }
    }, skip: skip);

    test('type awg_range: число и диапазон проходят, мусор снят', () {
      final r = _san({
        'type': 'wireguard',
        'tag': 'wg1',
        'address': ['10.0.0.2/32'],
        'private_key': 'cHJpdmF0ZUtleUJhc2U2NEV4YW1wbGVWYWx1ZTEyMzQ=',
        // §481 — значения НЕ пересекаются намеренно: пересечение h1..h4 теперь
        // роняет узел связью `ranges_disjoint` (свой кейс ниже), и старая пара
        // «5-10» + 7 проверяла бы уже не форму awg_range.
        'h1': '5-10',
        'h2': 20,
        'h3': 'junk',
        'peers': [
          {
            'address': '1.2.3.4',
            'port': 51820,
            'public_key': 'cHVibGljS2V5QmFzZTY0RXhhbXBsZVZhbHVlMTIzNDU=',
            'allowed_ips': ['0.0.0.0/0'],
          }
        ],
      }, scheme: 'wireguard', core: '1.14.0-lx.40');
      // Форма прибытия законна ОБЕ и не подменяется: `"5-10"` осталось
      // строкой, `7` — числом.
      expect(r.body!['h1'], '5-10');
      expect(r.body!['h2'], 20);
      expect(r.body!.containsKey('h3'), isFalse);
      // §481 (контракт 1.1.11): у h1..h4 появился свой `on_invalid` —
      // негодное значение снимает поле с awg_header_invalid, а не с общим
      // type_invalid.
      expect(_byCode(r, 'awg_header_invalid').path, 'h3');
    }, skip: skip);

    // ───── §481 (контракт 1.1.11) — четыре новых атрибута ─────
    //
    // Все четыре завёл один заход лаунчера, и все четыре — ОБЩИЕ выражения
    // движка: `if scheme == 'wireguard'` нигде не появляется, схема лишь
    // объявляет их у своих полей.

    Map<String, dynamic> wgBody([Map<String, dynamic> extra = const {}]) => {
          'type': 'wireguard',
          'tag': 'wg1',
          'address': ['10.0.0.2/32'],
          'private_key': 'cHJpdmF0ZUtleUJhc2U2NEV4YW1wbGVWYWx1ZTEyMzQ=',
          'peers': [
            {
              'address': '1.2.3.4',
              'port': 51820,
              'public_key': 'cHVibGljS2V5QmFzZTY0RXhhbXBsZVZhbHVlMTIzNDU=',
              'allowed_ips': ['0.0.0.0/0'],
            }
          ],
          ...extra,
        };

    SanitizeResult sanWg([Map<String, dynamic> extra = const {}]) =>
        _san(wgBody(extra), scheme: 'wireguard', core: '1.14.0-lx.40');

    test('normalize range_order: перевёрнутая пара свопается ТИХО', () {
      final r = sanWg({'h1': '40-10'});
      expect(r.body!['h1'], '10-40',
          reason: 'порядок границ смысла не несёт — ядро выбирает значение ИЗ '
              'диапазона, и [10,40] = [40,10]');
      // Кода нет: это перевод НАПИСАНИЯ, как trim, а не замена значения.
      expect(_codes(r), isEmpty);
    }, skip: skip);

    test('normalize range_order: голое число и прямая пара не трогаются', () {
      expect(sanWg({'h1': 7}).body!['h1'], 7);
      expect(sanWg({'h1': '10-40'}).body!['h1'], '10-40');
    }, skip: skip);

    test('range_order НЕ стоит у таймингов AWG 3.x — перевёрнутая пара там '
        'опечатка и снимается с кодом', () {
      final r = sanWg({'rekey_after_time': '120-10'});
      expect(r.body!.containsKey('rekey_after_time'), isFalse);
      expect(_byCode(r, 'awg3_field_invalid').path, 'rekey_after_time');
    }, skip: skip);

    test('awg_range: граница ШИРЕ uint32 снимает поле (ядро отвергло бы '
        'разбором весь конфиг)', () {
      final r = sanWg({'h1': '1-4294967296'});
      expect(r.body, isNotNull, reason: 'снимается ПОЛЕ, не узел');
      expect(r.body!.containsKey('h1'), isFalse);
      expect(_byCode(r, 'awg_header_invalid').path, 'h1');
    }, skip: skip);

    test('body.relations ranges_disjoint: пересечение h1..h4 роняет УЗЕЛ', () {
      final r = sanWg({'h1': '5-10', 'h2': 7});
      expect(r.body, isNull);
      expect(r.explicitDropNode, isTrue);
      expect(_codes(r), contains('awg_headers_overlap'));
    }, skip: skip);

    test('ranges_disjoint: незаданный заголовок участвует ДЕФОЛТОМ ядра', () {
      // h2 не задан, ядро читает его как 2 — и h1=2 с ним пересекается.
      final r = sanWg({'h1': 2});
      expect(r.body, isNull);
      expect(_codes(r), contains('awg_headers_overlap'));
      // А непересекающийся с дефолтами набор живёт.
      expect(sanWg({'h1': 100}).body, isNotNull);
    }, skip: skip);

    test('ranges_disjoint читает ЧИСТУЮ карту: снятое поле не «пересекается»',
        () {
      // Ловушка, на которую наступил лаунчер: загляни связь в ИСХОДНОЕ тело,
      // снятый за негодное значение h1 продолжал бы спорить с соседями, и
      // вина уехала бы не на того.
      final r = sanWg({'h1': '1-4294967296', 'h2': 2});
      expect(r.body, isNotNull);
      expect(_codes(r), isNot(contains('awg_headers_overlap')));
      expect(_byCode(r, 'awg_header_invalid').path, 'h1');
    }, skip: skip);

    test('min_when: паддинг ниже порога при заданном ключе роняет УЗЕЛ', () {
      final r = sanWg({
        'header_protection_key': 'aGVhZGVyS2V5QmFzZTY0RXhhbXBsZVZhbHVlMTIz',
        's1': 5,
        's2': 20,
        's3': 20,
        's4': 20,
      });
      expect(r.body, isNull);
      expect(r.explicitDropNode, isTrue);
      expect(_byCode(r, 'awg3_padding_too_short').path, 's1');
    }, skip: skip);

    test('min_when absent_is_zero: ОТСУТСТВУЮЩИЙ паддинг при ключе — так же '
        'фатально', () {
      final r = sanWg({
        'header_protection_key': 'aGVhZGVyS2V5QmFzZTY0RXhhbXBsZVZhbHVlMTIz',
      });
      expect(r.body, isNull);
      expect(_codes(r), contains('awg3_padding_too_short'));
    }, skip: skip);

    test('min_when: без ключа защиты порога НЕТ — обычный AmneziaWG живёт '
        'с любым паддингом', () {
      final r = sanWg({'s1': 5, 'jc': 3, 'jmin': 10, 'jmax': 50});
      expect(r.body, isNotNull);
      expect(r.body!['s1'], 5);
      expect(_codes(r), isNot(contains('awg3_padding_too_short')));
    }, skip: skip);

    test('pattern у header_protection_key: все нули роняют УЗЕЛ', () {
      // 32 нулевых байта и есть строка из одних `A` с паддингом.
      final r = sanWg({
        'header_protection_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        's1': 20,
        's2': 20,
        's3': 20,
        's4': 20,
      });
      expect(r.body, isNull);
      expect(_codes(r), contains('awg3_header_key_invalid'));
    }, skip: skip);

    test('ключи WG судит РЕЕСТР: не-32-байтный ключ роняет узел '
        'с wg_key_invalid, а не молча', () {
      final short = _san({
        ...wgBody(),
        'private_key': 'c2hvcnQ=',
      }, scheme: 'wireguard', core: '1.14.0-lx.40');
      expect(short.body, isNull);
      expect(short.explicitDropNode, isTrue);
      final w = _byCode(short, 'wg_key_invalid');
      expect(w.path, 'private_key');
      // `secret: true` — значение в предупреждении маскируется.
      expect(w.value, '***');
    }, skip: skip);

    test('битый pre_shared_key роняет УЗЕЛ наравне с обязательными ключами',
        () {
      final body = wgBody();
      (body['peers'] as List).first['pre_shared_key'] = 'not-base64-at-all!!';
      final r = _san(body, scheme: 'wireguard', core: '1.14.0-lx.40');
      expect(r.body, isNull, reason: 'решение владельца 19.09.2026: туннель '
          'без ожидаемого сервером PSK — тихо сломанный туннель');
      expect(_codes(r), contains('wg_key_invalid'));
    }, skip: skip);

    // ───── §481 (контракт 1.1.12, CANON §6.1) — `absent_when` ─────

    test('absent_when: tls{enabled:false} снимается ЦЕЛИКОМ и ТИХО', () {
      final r = _san(_vless({
        'tls': {'enabled': false, 'server_name': 'example.com'}
      }));
      expect(r.body!.containsKey('tls'), isFalse,
          reason: 'у ядра это «TLS не задан», а не «TLS с выключенным флагом»: '
              'явный disabled-блок ронял ядра lx.5..lx.18 в SIGSEGV');
      // Кода нет: запись «настройки нет» — не деградация.
      expect(_codes(r), isEmpty);
    }, skip: skip);

    test('absent_when судится ДО правил полей: мусор ВНУТРИ снятого блока '
        'кодов не даёт', () {
      final r = _san(_vless({
        'tls': {
          'enabled': false,
          'reality': {'enabled': true, 'public_key': 'не-ключ-вовсе'},
        }
      }));
      expect(r.body!.containsKey('tls'), isFalse);
      expect(_codes(r), isEmpty,
          reason: 'иначе человек получил бы коды на поля блока, которого в '
              'теле не будет');
    }, skip: skip);

    test('absent_when у вложенного: reality{enabled:false} исчезает, '
        'живой tls остаётся', () {
      final r = _san(_vless({
        'tls': {
          'enabled': true,
          'server_name': 'example.com',
          'reality': {'enabled': false, 'public_key': 'не-ключ-вовсе'},
        }
      }));
      final tls = r.body!['tls'] as Map;
      expect(tls['enabled'], true);
      expect(tls.containsKey('reality'), isFalse);
      expect(_codes(r), isEmpty);
    }, skip: skip);

    test('absent_when: tls БЕЗ ключа `enabled` — тело без флага, а не '
        'выключенный TLS', () {
      final r = _san(_vless({
        'tls': {'server_name': 'example.com'}
      }));
      expect(r.body!.containsKey('tls'), isTrue);
    }, skip: skip);

    test('absent_when сравнивает по печатной форме: строковое "false" '
        'совпадает с булевым', () {
      final r = _san(_vless({
        'tls': {'enabled': 'false', 'server_name': 'example.com'}
      }));
      expect(r.body!.containsKey('tls'), isFalse);
    }, skip: skip);

    test('default_when у allowed_ips: тело без ключа получает дефолт, '
        'а не теряет узел', () {
      final body = wgBody();
      (body['peers'] as List).first.remove('allowed_ips');
      final r = _san(body, scheme: 'wireguard', core: '1.14.0-lx.40');
      expect(r.body, isNotNull);
      expect((r.body!['peers'] as List).first['allowed_ips'],
          ['0.0.0.0/0', '::/0']);
      // Кода нет — это дефолт-конвенция, а не замена значения.
      expect(_codes(r), isEmpty);
    }, skip: skip);

    test('type int_array: reserved из трёх чисел цел, мусор снят', () {
      Map<String, dynamic> wg(Object? reserved) => {
            'type': 'wireguard',
            'tag': 'wg1',
            'address': ['10.0.0.2/32'],
            'private_key': 'cHJpdmF0ZUtleUJhc2U2NEV4YW1wbGVWYWx1ZTEyMzQ=',
            'peers': [
              {
                'address': '1.2.3.4',
                'port': 51820,
                'public_key': 'cHVibGljS2V5QmFzZTY0RXhhbXBsZVZhbHVlMTIzNDU=',
                'allowed_ips': ['0.0.0.0/0'],
                'reserved': reserved,
              }
            ],
          };
      final ok = _san(wg([1, 2, 3]), scheme: 'wireguard');
      expect(((ok.body!['peers'] as List).first as Map)['reserved'],
          [1, 2, 3]);

      final bad = _san(wg(['a', 'b', 'c']), scheme: 'wireguard');
      final peer = (bad.body!['peers'] as List).first as Map;
      expect(peer.containsKey('reserved'), isFalse);
    }, skip: skip);

    test('неизвестное выражение реестра не роняет и не портит значение', () {
      // Контракт может уехать вперёд кода: выражение, которого санитайзер не
      // знает, обязано остаться незамеченным, а не съесть поле.
      final r = _san(_vless({'transport': {'type': 'ws', 'path': '/x'}}));
      expect((r.body!['transport'] as Map)['path'], '/x');
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
