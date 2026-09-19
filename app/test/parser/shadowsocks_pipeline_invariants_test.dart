import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../contract_paths.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/parse_warnings.dart';
import 'package:lxbox/services/contract/warning_codes.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §472 шаг 4, раздел 3 спеки — инварианты переезда shadowsocks на конвейер.
///
/// Инварианты 1 и 2 (корпус и golden) держат свои тесты: корпус URI —
/// `test/contract/`, эталоны конфигов — `test/builder/`. Здесь то, что
/// специфично для переезда протокола: identity, round-trip и цена.

/// Снимок identity, снятый СТАРЫМ путём ДО правки (18.09.2026). Кейсов
/// корпуса у схемы всего девять, поэтому в фикстуру взяты и ссылки из
/// `app/test` — иначе сдвиг identity было бы нечем поймать.
const _identityFixture =
    'test/fixtures/shadowsocks/pipeline_identity_before.json';

Map<String, Map<String, dynamic>> _identityBefore() {
  final raw = jsonDecode(File(_identityFixture).readAsStringSync()) as Map;
  return (raw['cases'] as Map).map(
    (k, v) => MapEntry(k as String, (v as Map).cast<String, dynamic>()),
  );
}

/// Все ss-ссылки корпуса, в порядке файлов.
List<String> _corpusUris() {
  final out = <String>[];
  final files = Directory('$kVendorRoot/corpus/uri/shadowsocks')
      .listSync()
      .whereType<File>()
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    if (!f.path.endsWith('.uri')) continue;
    for (final line in f.readAsLinesSync()) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      out.add(t);
    }
  }
  return out;
}

void main() {
  final corpusSkip = corpusTestSkip('test/parser/shadowsocks_pipeline_invariants_test.dart');

  setUpAll(() async {
    await loadTestRegistry();
  });

  group('§472 инвариант 4 — identity shadowsocks не меняется', () {
    test('каждая ссылка фикстуры даёт прежний хеш', () {
      final before = _identityBefore();
      expect(before, hasLength(greaterThan(15)),
          reason: 'фикстура похудела — проверьте, не срезан ли корпус');
      for (final e in before.entries) {
        final uri = e.value['uri'] as String;
        final want = e.value['identity'] as String?;
        final spec = parseUri(uri);
        if (want == null) {
          expect(spec, isNull, reason: 'кейс ${e.key} стал разбираться');
          continue;
        }
        expect(spec, isNotNull, reason: 'кейс ${e.key} перестал разбираться');
        expect(
          legacyNodeIdentityHash(spec!),
          want,
          reason: 'identity кейса ${e.key} изменилась: у пользователей слетят '
              'выбор узла, отключения и цепочки',
        );
      }
    });

    test('безымянная ссылка держит прежний тег-фолбэк', () {
      // Ссылка зовётся `ss://`, а тело — `shadowsocks`, и фолбэк строится по
      // ИМЕНИ ТИПА ТЕЛА. Возьми конвейер имя схемы — тег стал бы
      // `ss-h.example-8388`, а тег И ЕСТЬ identity (`node_hash.dart`).
      final spec = parseUri('ss://${base64.encode(utf8.encode(
        'aes-256-gcm:pass123',
      ))}@h.example:8388')!;
      expect(spec.tag, 'shadowsocks-h.example-8388');
    });
  });

  group('§472 инвариант 3 — parseUri(toUri()) ≈ spec', () {
    test('весь корпус shadowsocks переживает круг', () {
      var checked = 0;
      for (final u in _corpusUris()) {
        final a = parseUri(u);
        if (a == null) continue;
        final b = parseUri(a.toUri());
        expect(b, isNotNull, reason: 'круг потерял узел: $u');
        expect(
          b!.emit(TemplateVars.empty).map,
          a.emit(TemplateVars.empty).map,
          reason: 'круг изменил тело: $u',
        );
        expect(legacyNodeIdentityHash(b), legacyNodeIdentityHash(a),
            reason: 'круг изменил identity: $u');
        checked++;
      }
      // Исключений у схемы нет ни одного: эмиттер собирает ту же
      // SIP002-форму, из которой узел и пришёл, а legacy-форма сходится к ней
      // же — метод, пароль, адрес и порт у обеих одни.
      expect(checked, greaterThan(7));
    }, skip: corpusSkip);
  });

  group('§472 инвариант 5 — цена разбора', () {
    // Замер на рабочей машине («лучший из трёх» — обоснование порога и формы
    // замера см. в `vless_pipeline_invariants_test.dart`).
    test('2000 ss-узлов разбираются за разумное время', () {
      const n = 2000;
      final uris = [
        for (var i = 0; i < n; i++)
          'ss://${base64.encode(utf8.encode('aes-256-gcm:pass$i'))}'
              '@example-$i.com:8388?plugin=obfs-local%3Bobfs%3Dhttp#node$i',
      ];

      for (var i = 0; i < 200; i++) {
        parseUri(uris[i]);
      }

      final nodes = <NodeSpec>[];
      var best = 1 << 30;
      for (var rep = 0; rep < 3; rep++) {
        nodes.clear();
        final sw = Stopwatch()..start();
        for (final u in uris) {
          final s = parseUri(u);
          if (s != null) nodes.add(s);
        }
        sw.stop();
        if (sw.elapsedMilliseconds < best) best = sw.elapsedMilliseconds;
      }
      expect(nodes, hasLength(n));
      expect(
        best,
        lessThan(3000),
        reason: 'разбор $n ss-узлов конвейером: $best мс (лучший из трёх)',
      );
    });
  });

  group('§472 — коды shadowsocks приходят из реестра', () {
    test('stream-шифр даёт ss_method_legacy из реестра, узел живёт', () {
      // D-122 — девять shadowstream-шифров ядро принимает: узел остаётся, а
      // человек видит info-код. Раньше код ставил рукописный
      // `RegistryWarning` прямо в парсере.
      final spec = parseUri('ss://${base64.encode(utf8.encode(
        'aes-128-cfb:pass123',
      ))}@h.example:8388#legacy')!;
      final w = spec.warnings
          .whereType<RegistryWarning>()
          .firstWhere((w) => w.code == 'ss_method_legacy');
      expect(w.path, 'method');
      expect(w.value, 'aes-128-cfb');
      expect((spec as ShadowsocksSpec).method, 'aes-128-cfb');
    });

    test('метод вне набора ядра снимает узел целиком', () {
      // `on_invalid: drop_node` — ядро на таком значении не стартует ВСЕМ
      // конфигом, поэтому узла не будет. Раньше это делал рукописный гейт
      // `isValidShadowsocksMethod`, и происходило это МОЛЧА.
      final spec = parseUri('ss://${base64.encode(utf8.encode(
        'rot13:pass123',
      ))}@h.example:8388#bogus');
      expect(spec, isNull);
    });

    test('SS2022 с составным паролем k1:k2 сохраняет его целиком', () {
      // Пароль — ВСЁ после первого `:`. Резать по второму значило бы
      // потерять ключ пользователя, и узел бы не поднялся.
      const pw = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=:'
          'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=';
      final spec = parseUri('ss://${base64.encode(utf8.encode(
        '2022-blake3-aes-256-gcm:$pw',
      ))}@h.example:8388#ss2022')!;
      expect((spec as ShadowsocksSpec).password, pw);
      expect(spec.method, '2022-blake3-aes-256-gcm');
      expect(spec.warnings.map(warningCodeOf), isNot(contains('type_invalid')));
    });

    test('plugin SIP003 раскладывается на два поля и доезжает до тела', () {
      // §472 шаг 4 — до переезда `parseSingboxEntry` эти поля не читал вовсе,
      // и на конвейере они пропали бы молча (тот же класс, что `encryption`
      // у vless на шаге 3).
      final spec = parseUri('ss://${base64.encode(utf8.encode(
        'aes-256-gcm:pass123',
      ))}@h.example:8388?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dx.com'
          '#plug')!;
      expect((spec as ShadowsocksSpec).plugin, 'obfs-local');
      expect(spec.pluginOpts, 'obfs=http;obfs-host=x.com');
      final body = spec.emit(TemplateVars.empty).map;
      expect(body['plugin'], 'obfs-local');
      expect(body['plugin_opts'], 'obfs=http;obfs-host=x.com');
      expect(spec.warnings.map(warningCodeOf), isNot(contains('unknown_key')));
    });

    test('§453 dial-поля идут мимо санитайзера и не теряются', () {
      // До переезда они лежали в теле, и санитайзер снимал их как
      // `unknown_key` — узел терял настройку человека (тот же дефект, что
      // шаг 3 нашёл у trojan).
      final spec = parseUri('ss://${base64.encode(utf8.encode(
        'aes-128-gcm:pw',
      ))}@h.example:8388?tcp_keep_alive=30s#S')!;
      expect(spec.tcpKeepAlive?.idle, '30s');
      expect(spec.warnings.map(warningCodeOf), isNot(contains('unknown_key')));
    });
  });

  group('§472 — второй проход по emit() узла конвейера не дублирует коды', () {
    test('annotateAllWithRegistry на разобранном ss ничего не добавляет', () {
      final spec = parseUri('ss://${base64.encode(utf8.encode(
        'aes-128-cfb:pass123',
      ))}@h.example:8388#legacy')!;
      final before = spec.warnings.length;
      annotateAllWithRegistry([spec]);
      expect(spec.warnings, hasLength(before),
          reason: 'второй проход задвоил коды узла конвейера');
    });
  });
}
