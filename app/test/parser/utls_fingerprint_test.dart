import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/parser/utls_fingerprint.dart';

// §169 — валидный X25519 public key (43-симв base64url = 32 байта).
const _validPbk = 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw';

/// §281 — uTLS fingerprint вне словаря ядра = fatal ВСЕГО конфига на старте
/// («unknown uTLS fingerprint»). Xray-псевдонимы канонизируются молча,
/// неопознанный мусор → chrome + UnknownFingerprintWarning.
void main() {
  group('normalizeUtlsFingerprintValue (чистая функция)', () {
    test('значения словаря проходят как есть', () {
      for (final fp in kUtlsFingerprints) {
        final n = normalizeUtlsFingerprintValue(fp);
        expect(n.value, fp);
        expect(n.junk, isFalse);
      }
    });

    test('регистр и пробелы канонизируются', () {
      expect(normalizeUtlsFingerprintValue('QQ'), (value: 'qq', junk: false));
      expect(normalizeUtlsFingerprintValue(' Chrome '),
          (value: 'chrome', junk: false));
    });

    test('xray-псевдонимы hello* → семейство, НЕ junk', () {
      const cases = {
        'hellochrome_120': 'chrome',
        'hellochrome_106_shuffle': 'chrome',
        'hellochrome_auto': 'chrome',
        'HelloChrome_120': 'chrome',
        'hellofirefox_auto': 'firefox',
        'helloedge_85': 'edge',
        'hellosafari_auto': 'safari',
        'hello360_auto': '360',
        'helloqq_auto': 'qq',
        'helloios_auto': 'ios',
        'helloandroid_11_okhttp': 'android',
        // §463 / контракт §24.2 п. 7.1 — весь префикс `hellorandom*` даёт
        // `random`: подписка просила случайный отпечаток, и подменять его
        // фиксированным (раньше голый `hellorandom` уезжал в `chrome`)
        // значило вернуть ту самую узнаваемую сигнатуру, от которой уходили.
        'hellorandom': 'random',
        'hellorandomized': 'random',
        'hellorandomizedalpn': 'random',
        'hellorandomizednoalpn': 'random',
      };
      cases.forEach((raw, want) {
        final n = normalizeUtlsFingerprintValue(raw);
        expect(n.value, want, reason: raw);
        expect(n.junk, isFalse, reason: raw);
      });
    });

    test('неопознанный мусор → chrome + junk', () {
      for (final raw in ['garbage', 'hellogolang', 'hellocustom', 'none']) {
        final n = normalizeUtlsFingerprintValue(raw);
        expect(n.value, 'chrome', reason: raw);
        expect(n.junk, isTrue, reason: raw);
      }
    });

    test('пустая/пробельная строка → пустая, НЕ junk', () {
      expect(normalizeUtlsFingerprintValue(''), (value: '', junk: false));
      expect(normalizeUtlsFingerprintValue('  '), (value: '', junk: false));
    });
  });

  group('SPEC 083/086/087 — REALITY + отпечаток без гибридного key share', () {
    test('kRealityHybridFingerprints ⊂ словаря ядра', () {
      expect(kUtlsFingerprints.containsAll(kRealityHybridFingerprints), isTrue);
      expect(isRealityHybridFingerprint(''), isTrue, reason: 'дефолт ядра');
      expect(isRealityHybridFingerprint('chrome_pq'), isTrue);
      expect(isRealityHybridFingerprint('random'), isFalse);
      expect(isRealityHybridFingerprint('randomized'), isFalse);
    });

    // §451 / ядро SPEC 086+087 (libbox ≥ v1.14.1-lx.3) — форк utls добавил
    // Firefox 148 и Safari 26.3 с гибридным key share.
    test('firefox и safari несут гибрид, остальные не-chrome — нет', () {
      for (final fp in ['firefox', 'safari']) {
        expect(isRealityHybridFingerprint(fp), isTrue, reason: fp);
      }
      for (final fp in ['edge', 'ios', 'android', '360', 'qq']) {
        expect(isRealityHybridFingerprint(fp), isFalse, reason: fp);
      }
    });

    test('REALITY + fp=firefox/safari → без предупреждения, значение сохранено',
        () {
      for (final fp in ['firefox', 'safari']) {
        final spec = parseVless(
            'vless://u@h:443?type=tcp&security=reality&encryption=none'
            '&fp=$fp&pbk=$_validPbk#L')!;
        expect(spec.tls.fingerprint, fp,
            reason: '§444: отпечаток источника не подменяется');
        expect(spec.warnings.whereType<RealityFingerprintWarning>(), isEmpty,
            reason: fp);
        expect(spec.warnings.whereType<UnknownFingerprintWarning>(), isEmpty);
      }
    });

    // §472 шаг 3 — vless разбирается конвейером, и код ставит РЕЕСТР
    // (`tls.json` → `utls.fingerprint`, `advisory` с `except`), а не
    // рукописный `normalizeTlsFingerprint`. Исход прежний — значение цело,
    // узел под предупреждением, — но код реестровый и несёт путь.
    // Реестр здесь уже загружен: его грузит `setUpAll`-подобный вызов в
    // группе «остальные URI-парсеры» ниже по файлу. Без него эти тесты
    // проверяли бы разбор без санитайзера, то есть не то поведение, которое
    // видит приложение.
    test('REALITY + fp=edge → reality_fp_not_chrome, значение сохранено',
        () async {
      await ContractRegistry.I.loadFromDirectory('contract');
      final spec = parseVless(
          'vless://u@h:443?type=tcp&security=reality&encryption=none'
          '&fp=edge&pbk=$_validPbk#L')!;
      expect(spec.tls.fingerprint, 'edge',
          reason: '§444: отпечаток источника не подменяется ни в entry, ни в конфиге');
      final w = spec.warnings.whereType<RegistryWarning>().firstWhere(
            (w) => w.code == 'reality_fp_not_chrome',
            orElse: () => fail('нет кода reality_fp_not_chrome: ${spec.warnings}'),
          );
      expect(w.path, 'tls.utls.fingerprint');
      expect(w.value, 'edge');
      expect(spec.warnings.whereType<UnknownFingerprintWarning>(), isEmpty);
    });

    test('REALITY + xray-псевдоним hellofirefox_auto → firefox, без предупреждения',
        () {
      final spec = parseVless(
          'vless://u@h:443?type=tcp&security=reality&encryption=none'
          '&fp=hellofirefox_auto&pbk=$_validPbk#L')!;
      expect(spec.tls.fingerprint, 'firefox');
      expect(spec.warnings.whereType<RealityFingerprintWarning>(), isEmpty);
    });

    test('REALITY + xray-псевдоним helloqq_auto → qq + предупреждение',
        () async {
      await ContractRegistry.I.loadFromDirectory('contract');
      final spec = parseVless(
          'vless://u@h:443?type=tcp&security=reality&encryption=none'
          '&fp=helloqq_auto&pbk=$_validPbk#L')!;
      expect(spec.tls.fingerprint, 'qq');
      // Перевод написания кода не даёт, а отпечаток без гибридного шара —
      // даёт, и на уже переведённом значении (§472 шаг 3: судит реестр).
      final w = spec.warnings.whereType<RegistryWarning>().firstWhere(
            (w) => w.code == 'reality_fp_not_chrome',
            orElse: () => fail('нет кода reality_fp_not_chrome: ${spec.warnings}'),
          );
      expect(w.value, 'qq');
    });

    test('REALITY + chrome-семейство и дефолтный random → без предупреждения',
        () {
      for (final q in ['&fp=chrome', '&fp=chrome_pq', '&fp=HelloChrome_120', '']) {
        final spec = parseVless(
            'vless://u@h:443?type=tcp&security=reality&encryption=none'
            '$q&pbk=$_validPbk#L')!;
        expect(spec.warnings.whereType<RealityFingerprintWarning>(), isEmpty,
            reason: 'q="$q"');
      }
    });

    test('plain TLS + fp=firefox → без предупреждения (сервер не REALITY)', () {
      final spec = parseVless(
          'vless://u@h:443?type=tcp&security=tls&encryption=none'
          '&fp=firefox&sni=h#L')!;
      expect(spec.tls.reality, isNull);
      expect(spec.warnings.whereType<RealityFingerprintWarning>(), isEmpty);
    });

    test('raw sing-box JSON: REALITY + safari — без аккумулятора, значение цело',
        () {
      final spec = parseSingboxEntry({
        'type': 'vless',
        'tag': 't',
        'server': 'h',
        'server_port': 443,
        'uuid': '0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c',
        'tls': {
          'enabled': true,
          'server_name': 'x.com',
          'utls': {'enabled': true, 'fingerprint': 'safari'},
          'reality': {'enabled': true, 'public_key': _validPbk},
        },
      })! as VlessSpec;
      expect(spec.tls.fingerprint, 'safari');
    });
  });

  group('VLESS (реальный кейс подписки)', () {
    test('REALITY + fp=hellochrome_120 → chrome, МОЛЧА, reality на месте', () {
      final spec = parseVless(
          'vless://u@h:443?type=tcp&security=reality&encryption=none'
          '&flow=xtls-rprx-vision&fp=hellochrome_120&pbk=$_validPbk#L')!;
      expect(spec.tls.fingerprint, 'chrome');
      expect(spec.tls.reality, isNotNull, reason: 'REALITY не потерян');
      expect(spec.warnings.whereType<UnknownFingerprintWarning>(), isEmpty,
          reason: 'псевдоним = синоним, не warning');
    });

    test('fp=QQ → qq (регистр)', () {
      final spec = parseVless(
          'vless://u@h:443?type=grpc&security=reality&fp=QQ&pbk=$_validPbk#L')!;
      expect(spec.tls.fingerprint, 'qq');
      expect(spec.warnings.whereType<UnknownFingerprintWarning>(), isEmpty);
    });

    // §472 шаг 3 — тот же переезд, что у trojan шагом 2: мусор сводит к
    // `chrome` реестр (`on_invalid: coerce`), код `utls_fp_unknown` несёт
    // путь и СЫРОЕ значение ссылки.
    test('мусор → chrome + код реестра utls_fp_unknown', () async {
      await ContractRegistry.I.loadFromDirectory('contract');
      final spec =
          parseVless('vless://u@h:443?security=tls&fp=garbage&sni=x.com#L')!;
      expect(spec.tls.fingerprint, 'chrome');
      final w = spec.warnings.whereType<RegistryWarning>().firstWhere(
            (w) => w.code == 'utls_fp_unknown',
            orElse: () => fail('нет кода utls_fp_unknown: ${spec.warnings}'),
          );
      expect(w.path, 'tls.utls.fingerprint');
      expect(w.value, 'garbage');
    });

    test('emit отдаёт канонизированный utls.fingerprint', () {
      final spec = parseVless(
          'vless://u@h:443?security=tls&fp=hellochrome_120&sni=x.com#L')!;
      final out = spec.emit(TemplateVars.empty).map;
      final utls = (out['tls'] as Map)['utls'] as Map;
      expect(utls['fingerprint'], 'chrome');
    });

    test('пустой fp → существующий дефолт random (не тронут)', () {
      final spec = parseVless('vless://u@h:443?security=tls&fp=&sni=x.com#L')!;
      expect(spec.tls.fingerprint, 'random');
    });
  });

  group('остальные URI-парсеры', () {
    test('trojan: псевдоним молча', () {
      final spec = parseTrojan(
          'trojan://p@h:443?security=tls&fp=hellofirefox_auto&sni=x.com#L')!;
      expect(spec.tls.fingerprint, 'firefox');
      expect(spec.warnings.whereType<UnknownFingerprintWarning>(), isEmpty);
    });

    // §472 шаг 2 — trojan разбирается конвейером, и мусорный отпечаток судит
    // РЕЕСТР (`tls.json` → `utls.fingerprint`: enum + `on_invalid: coerce
    // chrome`), а не рукописный `normalizeTlsFingerprint`. Исход прежний —
    // `chrome` плюс предупреждение, — но код реестровый (`utls_fp_unknown`) и
    // несёт путь со значением, чего у рукописного класса не было.
    test('trojan: мусор → chrome + код реестра utls_fp_unknown', () async {
      await ContractRegistry.I.loadFromDirectory('contract');
      final spec =
          parseTrojan('trojan://p@h:443?security=tls&fp=bogus&sni=x.com#L')!;
      expect(spec.tls.fingerprint, 'chrome');
      final w = spec.warnings.whereType<RegistryWarning>().firstWhere(
            (w) => w.code == 'utls_fp_unknown',
            orElse: () => fail('нет кода utls_fp_unknown: ${spec.warnings}'),
          );
      expect(w.path, 'tls.utls.fingerprint');
      expect(w.value, 'bogus');
    });

    test('trojan: пустой fp → null (без utls-блока)', () {
      final spec = parseTrojan('trojan://p@h:443?security=tls&sni=x.com#L')!;
      expect(spec.tls.fingerprint, isNull);
    });

    test('vmess: мусор в fp из base64-JSON → chrome + warning', () {
      final cfg = {
        'v': '2',
        'ps': 'L',
        'add': 'h',
        'port': '443',
        'id': '0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c',
        'net': 'ws',
        'tls': 'tls',
        'fp': 'wat',
        'host': 'x.com',
        'path': '/',
      };
      final uri = 'vmess://${base64Encode(utf8.encode(jsonEncode(cfg)))}';
      final spec = parseVmess(uri)!;
      expect(spec.tls.fingerprint, 'chrome');
      expect(spec.warnings, contains(const UnknownFingerprintWarning('wat')));
    });

    test('anytls: псевдоним молча (через VLESS-конвенцию)', () {
      final spec =
          parseAnyTls('anytls://p@h:443?fp=hellochrome_131&sni=x.com#L')!;
      expect(spec.tls.fingerprint, 'chrome');
      expect(spec.warnings.whereType<UnknownFingerprintWarning>(), isEmpty);
    });

    test('hysteria2: мусор → chrome + warning (тот же tls.NewClient ядра)',
        () {
      final spec =
          parseHysteria2('hysteria2://p@h:443?fp=bogus&sni=x.com#L')!;
      expect(spec.tls.fingerprint, 'chrome');
      expect(spec.warnings, contains(const UnknownFingerprintWarning('bogus')));
    });

    test('proxy-https: псевдоним молча', () {
      final spec = parseHttpProxy(
          'proxy-https://u:p@h:443?fp=hellochrome_120&sni=x.com#L')!;
      expect(spec.tls.fingerprint, 'chrome');
      expect(spec.warnings.whereType<UnknownFingerprintWarning>(), isEmpty);
    });
  });

  group('§282 — QUIC (hysteria2/tuic) не эмитит uTLS', () {
    Map<String, dynamic> emitTls(NodeSpec spec) =>
        spec.emit(TemplateVars.empty).map['tls'] as Map<String, dynamic>;

    test('hysteria2 URI с fp → emit-конфиг БЕЗ utls', () {
      final spec = parseHysteria2('hysteria2://p@h:443?fp=chrome&sni=x.com#L')!;
      expect(spec.tls.fingerprint, 'chrome', reason: 'в модели fp живёт');
      final tls = emitTls(spec);
      expect(tls.containsKey('utls'), isFalse,
          reason: 'uTLS поверх QUIC = мёртвая нода');
      expect(tls['server_name'], 'x.com', reason: 'остальной TLS цел');
    });

    test('hysteria2 round-trip URI сохраняет fp (данные не теряются)', () {
      final spec = parseHysteria2('hysteria2://p@h:443?fp=chrome&sni=x.com#L')!;
      expect(spec.toUri(), contains('fp=chrome'));
    });

    test('tuic из sing-box JSON с fp → emit-конфиг БЕЗ utls', () {
      final spec = parseSingboxEntry({
        'type': 'tuic',
        'tag': 't',
        'server': 'h',
        'server_port': 443,
        'uuid': '0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c',
        'password': 'p',
        'tls': {
          'enabled': true,
          'server_name': 'x.com',
          'alpn': ['h3'],
          'utls': {'enabled': true, 'fingerprint': 'chrome'},
        },
      })!;
      final tls = emitTls(spec);
      expect(tls.containsKey('utls'), isFalse);
      expect(tls['alpn'], ['h3'], reason: 'alpn для QUIC валиден, не трогаем');
    });

    test('TCP-протокол (vless) с fp → utls НА МЕСТЕ (контроль)', () {
      final spec =
          parseVless('vless://u@h:443?security=tls&fp=chrome&sni=x.com#L')!;
      final tls = emitTls(spec);
      expect((tls['utls'] as Map)['fingerprint'], 'chrome');
    });

    test('РЕВЬЮ §282: reality на tuic → emit БЕЗ reality и БЕЗ utls', () {
      // reality поверх QUIC тоже мёртв (RealityClientConfig.STDConfig ошибка);
      // reality на hy2/tuic = мусор подписок, срезаем оба блока.
      final spec = parseSingboxEntry({
        'type': 'tuic',
        'tag': 't',
        'server': 'h',
        'server_port': 443,
        'uuid': '0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c',
        'password': 'p',
        'tls': {
          'enabled': true,
          'server_name': 'x.com',
          'reality': {'enabled': true, 'public_key': _validPbk},
          'utls': {'enabled': true, 'fingerprint': 'chrome'},
        },
      })!;
      final tls = emitTls(spec);
      expect(tls.containsKey('utls'), isFalse);
      expect(tls.containsKey('reality'), isFalse);
      expect(tls['server_name'], 'x.com');
    });
  });

  group('JSON-парсеры', () {
    test('xray streamSettings: псевдоним в reality.fingerprint → chrome', () {
      final spec = parseXrayOutbound(<String, dynamic>{
        'remarks': 'L',
        'outbounds': [
          {
            'protocol': 'vless',
            'tag': 'proxy',
            'settings': {
              'vnext': [
                {
                  'address': 'h',
                  'port': 443,
                  'users': [
                    {'id': '0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c'}
                  ],
                }
              ],
            },
            'streamSettings': {
              'network': 'tcp',
              'security': 'reality',
              'realitySettings': {
                'publicKey': _validPbk,
                'fingerprint': 'hellochrome_120',
                'serverName': 'x.com',
              },
            },
          },
        ],
      })! as VlessSpec;
      expect(spec.tls.fingerprint, 'chrome');
      expect(spec.warnings.whereType<UnknownFingerprintWarning>(), isEmpty);
    });

    test('raw sing-box entry: псевдоним и мусор канонизируются молча', () {
      VlessSpec entryWithFp(String fp) => parseSingboxEntry({
            'type': 'vless',
            'tag': 't',
            'server': 'h',
            'server_port': 443,
            'uuid': '0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c',
            'tls': {
              'enabled': true,
              'server_name': 'x.com',
              'utls': {'enabled': true, 'fingerprint': fp},
            },
          })! as VlessSpec;
      expect(entryWithFp('HelloChrome_120').tls.fingerprint, 'chrome');
      expect(entryWithFp('garbage').tls.fingerprint, 'chrome');
    });

    test(
        'РЕВЬЮ §281: REALITY + пустой/пробельный fingerprint → chrome '
        '(иначе toSingbox не эмитит utls, а ядру uTLS при reality обязателен)',
        () {
      for (final fp in ['', '  ']) {
        final spec = parseSingboxEntry({
          'type': 'vless',
          'tag': 't',
          'server': 'h',
          'server_port': 443,
          'uuid': '0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c',
          'tls': {
            'enabled': true,
            'server_name': 'x.com',
            'utls': {'enabled': true, 'fingerprint': fp},
            'reality': {'enabled': true, 'public_key': _validPbk},
          },
        })! as VlessSpec;
        expect(spec.tls.fingerprint, 'chrome', reason: 'fp="$fp"');
        expect(spec.tls.reality, isNotNull);
        final utls =
            (spec.emit(TemplateVars.empty).map['tls'] as Map)['utls'] as Map;
        expect(utls['fingerprint'], 'chrome');
      }
    });

    test('РЕВЬЮ §281: xray reality с пустым fingerprint → chrome', () {
      final spec = parseXrayOutbound(<String, dynamic>{
        'remarks': 'L',
        'outbounds': [
          {
            'protocol': 'vless',
            'tag': 'proxy',
            'settings': {
              'vnext': [
                {
                  'address': 'h',
                  'port': 443,
                  'users': [
                    {'id': '0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c'}
                  ],
                }
              ],
            },
            'streamSettings': {
              'network': 'tcp',
              'security': 'reality',
              'realitySettings': {
                'publicKey': _validPbk,
                'fingerprint': '',
                'serverName': 'x.com',
              },
            },
          },
        ],
      })! as VlessSpec;
      expect(spec.tls.fingerprint, 'chrome');
      expect(spec.tls.reality, isNotNull);
    });

    test(
        'РЕВЬЮ §281: naive-entry срезает TLS до enabled/server_name '
        '(alpn/utls/insecure/reality для naive = fatal у ядра)', () {
      final spec = parseSingboxEntry({
        'type': 'naive',
        'tag': 't',
        'server': 'h',
        'server_port': 443,
        'username': 'u',
        'password': 'p',
        'tls': {
          'enabled': true,
          'server_name': 'x.com',
          'insecure': true,
          'alpn': ['h2'],
          'utls': {'enabled': true, 'fingerprint': 'chrome'},
          'reality': {'enabled': true, 'public_key': _validPbk},
        },
      })! as NaiveSpec;
      expect(spec.tls.enabled, isTrue);
      expect(spec.tls.serverName, 'x.com');
      expect(spec.tls.fingerprint, isNull);
      expect(spec.tls.alpn, isEmpty);
      expect(spec.tls.insecure, isFalse);
      expect(spec.tls.reality, isNull);
    });
  });
}
