import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../contract_paths.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/parse_warnings.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §472 шаг 6, раздел 3 спеки — инварианты переезда anytls на конвейер.
///
/// Инварианты 1 и 2 (корпус и golden) держат свои тесты: корпус URI —
/// `test/contract/`, эталоны конфигов — `test/builder/` и
/// `test/storage_migration/`. Здесь то, что специфично для переезда
/// протокола: identity, round-trip, цена и коды из реестра.

/// Снимок identity, снятый СТАРЫМ путём ДО правки (18.09.2026).
const _identityFixture = 'test/fixtures/anytls/pipeline_identity_before.json';

Map<String, Map<String, dynamic>> _identityBefore() {
  final raw = jsonDecode(File(_identityFixture).readAsStringSync()) as Map;
  return (raw['cases'] as Map).map(
    (k, v) => MapEntry(k as String, (v as Map).cast<String, dynamic>()),
  );
}

/// Все anytls-ссылки корпуса, в порядке файлов.
List<String> _corpusUris() {
  final out = <String>[];
  final files = Directory('$kVendorRoot/corpus/uri/anytls')
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

List<RegistryWarning> _registry(NodeSpec n) =>
    n.warnings.whereType<RegistryWarning>().toList();

void main() {
  final corpusSkip = corpusTestSkip('test/parser/anytls_pipeline_invariants_test.dart');

  setUpAll(() async {
    await loadTestRegistry();
  });

  group('§472 инвариант 4 — identity anytls не меняется', () {
    test('каждый кейс корпуса даёт хеш из фикстуры', () {
      final before = _identityBefore();
      expect(before, hasLength(greaterThan(11)),
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
  });

  group('§472 инвариант 3 — parseUri(toUri()) ≈ spec', () {
    test('весь корпус anytls переживает круг', () {
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
      // У anytls круг проходят ВСЕ разбираемые кейсы, без исключений.
      expect(checked, greaterThan(9));
    }, skip: corpusSkip);
  });

  group('§472 инвариант 5 — цена разбора', () {
    test('2000 anytls-узлов разбираются за разумное время', () {
      const n = 2000;
      final uris = [
        for (var i = 0; i < n; i++)
          'anytls://pass$i@example-$i.com:443?sni=example-$i.com'
              '&fp=chrome&alpn=h2&idle_session_timeout=30'
              '&min_idle_session=2#node$i',
      ];

      // Прогрев кэша схем и JIT.
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
        reason: 'разбор $n anytls-узлов конвейером: $best мс (лучший из трёх)',
      );
    });
  });

  group('§472 — коды anytls приходят из реестра, с путём и значением', () {
    test('min_idle_session судит РЕЕСТР, а не рукописный класс', () {
      // Прежде это правило исполнял `AnyTlsMinIdleInvalidWarning` — код без
      // пути и без значения. На нём же стоял дедуп-пример
      // `parse_warnings_test.dart`, переехавший шагом 6 на masque.
      // §472 шаг 9 — сам класс снят (производителей в lib/ не осталось),
      // поэтому проверять его отсутствие больше нечем: он не компилируется.
      for (final raw in ['-5', 'abc']) {
        final spec = parseUri('anytls://pw@h.example:443?sni=a.example'
            '&min_idle_session=$raw#n')!;
        final w = _registry(spec)
            .firstWhere((w) => w.code == 'anytls_min_idle_invalid');
        expect(w.path, 'min_idle_session');
        expect(w.value, raw, reason: 'значение как написал автор');
        expect(
            spec.emit(TemplateVars.empty).map.containsKey('min_idle_session'),
            isFalse,
            reason: 'поле снято — ядро подставит свой дефолт');
      }
      // Ноль — законное значение, кода нет.
      final zero =
          parseUri('anytls://pw@h.example:443?min_idle_session=0#n')!;
      expect(_registry(zero).map((w) => w.code),
          isNot(contains('anytls_min_idle_invalid')));
    });

    test('insecure даёт код реестра с путём и значением', () {
      final spec =
          parseUri('anytls://pw@h.example:443?sni=a.example&insecure=1#n')!;
      expect(
          spec.warnings.where(
              (w) => w is RegistryWarning && w.code == 'tls_insecure'),
          isNotEmpty);
      final w = _registry(spec).firstWhere((w) => w.code == 'tls_insecure');
      expect(w.path, 'tls.insecure');
      expect(w.value, 'true');
    });

    test('REALITY: годность ключа судит реестр', () {
      const pbk = 'AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw';
      final ok = parseUri('anytls://pw@h.example:443?security=reality'
          '&pbk=$pbk&sid=abcd#n')!;
      final tls = ok.emit(TemplateVars.empty).map['tls'] as Map;
      expect((tls['reality'] as Map)['public_key'], pbk);

      // Мусорный ключ: блок создаёт маппер, снимает реестр по `base64_32`.
      final junk =
          parseUri('anytls://pw@h.example:443?security=reality&pbk=enabled#n')!;
      final junkTls = junk.emit(TemplateVars.empty).map['tls'] as Map;
      expect(junkTls.containsKey('reality'), isFalse);
      expect(_registry(junk).map((w) => w.code),
          contains('reality_pbk_invalid'));
      // Узел жив и деградировал до plain TLS — так же, как прежде.
      expect(junkTls['enabled'], isTrue);
    });
  });

  group('§472 — anytls: перевод, который остаётся за маппером', () {
    test('security=none НЕ снимает блок TLS и не теряет параметры', () {
      // AnyTLS живёт только поверх TLS (`body.fields.tls` → `required`), и
      // `security=none` для него бессмысленен. Правило `security_none_no_tls`
      // унесло бы весь блок вместе с `sni`/`alpn`/`insecure`, которые автор
      // написал; кейс корпуса `security_none_params_kept` нормирует обратное.
      final spec = parseUri('anytls://pw@h.example:8443?security=none'
          '&sni=cdn.example&alpn=h2&fp=chrome#n')!;
      final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
      expect(tls['enabled'], isTrue);
      expect(tls['server_name'], 'cdn.example');
      expect(tls['alpn'], ['h2']);
    });

    test('эвристика SNI: имя без точки и 🔒 уступают адресу сервера', () {
      // `sni_heuristic_falls_back_to_server` — у anytls правило есть на обоих
      // проектах (в отличие от trojan/vless/vmess).
      for (final bad in ['localhost', '🔒']) {
        final spec = parseUri(
            'anytls://pw@h.example:443?sni=${Uri.encodeComponent(bad)}#n')!;
        expect((spec.emit(TemplateVars.empty).map['tls'] as Map)['server_name'],
            'h.example',
            reason: 'sni=$bad');
      }
      final ok = parseUri('anytls://pw@h.example:443?sni=a.b#n')!;
      expect((ok.emit(TemplateVars.empty).map['tls'] as Map)['server_name'],
          'a.b');
    });

    test('без fp= отпечаток random (vless-конвенция D-009)', () {
      final spec = parseUri('anytls://pw@h.example:443?sni=a.b#n')!;
      final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
      expect((tls['utls'] as Map)['fingerprint'], 'random');
    });

    test('голое число duration-поля читается как секунды', () {
      // Та же конвенция, что `heartbeat_bare_number` у tuic: ядро отвергает
      // «30» без единицы измерения фаталом на весь конфиг.
      final spec = parseUri('anytls://pw@h.example:443?sni=a.b'
          '&idle_session_timeout=30&idle_session_check_interval=15s#n')!;
      final body = spec.emit(TemplateVars.empty).map;
      expect(body['idle_session_timeout'], '30s');
      expect(body['idle_session_check_interval'], '15s');
    });

    test('пароль с двоеточием внутри остаётся целым', () {
      // userinfo у anytls это пароль ЦЕЛИКОМ (в отличие от tuic, где до
      // первого двоеточия лежит uuid).
      final spec = parseUri('anytls://p%40ss%3Aword@h.example:443#n')!;
      expect(spec.emit(TemplateVars.empty).map['password'], 'p@ss:word');
    });

    test('дефект: нечисловой min_idle_session в ТЕЛЕ не роняет узел', () {
      // `parseSingboxEntry` читал поле жёстким кастом `as num?`, и на любом
      // нечисловом значении бросал; `parseUri`/`parseAll` исключение ловят и
      // отдают `null` — узел исчезал ЦЕЛИКОМ и молча. Строка вместо числа у
      // агрегаторов обычное дело, и до конвейера это было незаметно: URI-путь
      // приводил значение к int сам, ещё до модели.
      final node = parseSingboxEntry({
        'type': 'anytls',
        'tag': 'n',
        'server': 'h.example',
        'server_port': 443,
        'password': 'pw',
        'min_idle_session': 'abc',
        'tls': {'enabled': true, 'server_name': 'h.example'},
      });
      expect(node, isNotNull, reason: 'узел пережил нечисловое значение');
      expect((node as AnyTlsSpec).minIdleSession, isNull);

      // Число строкой — законная форма провайдера, и она читается.
      final asString = parseSingboxEntry({
        'type': 'anytls',
        'tag': 'n',
        'server': 'h.example',
        'server_port': 443,
        'password': 'pw',
        'min_idle_session': '3',
        'tls': {'enabled': true, 'server_name': 'h.example'},
      }) as AnyTlsSpec;
      expect(asString.minIdleSession, 3);
    });

    test('§453 dial-поля доезжают до тела и не теряются', () {
      final spec = parseUri(
          'anytls://pw@h.example:443?sni=a.b&tcp_keep_alive=30s#n')!;
      expect(spec.emit(TemplateVars.empty).map['tcp_keep_alive'], '30s');
      expect(_registry(spec).map((w) => w.code), isNot(contains('unknown_key')));
    });
  });

  group('§472 — второй проход по emit() узла конвейера не дублирует коды', () {
    test('annotateAllWithRegistry на разобранном anytls ничего не добавляет',
        () {
      final spec = parseUri(
          'anytls://pw@h.example:443?sni=x.com&fp=firefox&allow_insecure=1#L')!;
      final before = spec.warnings.length;
      annotateAllWithRegistry([spec]);
      expect(spec.warnings, hasLength(before),
          reason: 'второй проход задвоил коды узла конвейера');
    });
  });
}
