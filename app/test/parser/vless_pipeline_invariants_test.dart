import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/parse_warnings.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/contract/warning_codes.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §472 шаг 3, раздел 3 спеки — инварианты переезда vless на конвейер.
///
/// Инварианты 1 и 2 (корпус и golden) держат свои тесты: корпус URI —
/// `test/contract/`, эталоны конфигов — `test/builder/`. Здесь то, что
/// специфично для переезда протокола: identity, round-trip и цена.
const _contractRoot = 'contract';

/// Снимок identity, снятый СТАРЫМ путём ДО правки (18.09.2026).
///
/// Зачем фикстура файлом, а не картой в коде: vless-кейсов корпуса 89, и
/// восемьдесят семь хешей в литерале читать невозможно. Формат тот же, что у
/// шага 2 (`trojan_pipeline_invariants_test.dart`), — имя кейса → хеш, — но
/// вместе с САМОЙ ССЫЛКОЙ: тест обязан падать и тогда, когда кейс корпуса
/// переписали, а не только когда изменился разбор.
///
/// Расхождение здесь значит, что у пользователей слетят выбор узла,
/// отключения и цепочки (`node_hash.dart`: identity = сырой тег, дедуп
/// подписки — `legacyNodeIdentityHash` от тела).
const _identityFixture = 'test/fixtures/vless/pipeline_identity_before.json';

Map<String, Map<String, dynamic>> _identityBefore() {
  final raw = jsonDecode(File(_identityFixture).readAsStringSync()) as Map;
  return (raw['cases'] as Map).map(
    (k, v) => MapEntry(k as String, (v as Map).cast<String, dynamic>()),
  );
}

/// Все vless-ссылки корпуса, в порядке файлов.
List<String> _corpusUris() {
  final out = <String>[];
  final files = Directory('$_contractRoot/corpus/uri/vless')
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
  final synced = Directory('$_contractRoot/registry').existsSync();
  final skip = synced ? null : 'контракт не синхронизирован';

  setUpAll(() async {
    if (!synced) return;
    await ContractRegistry.I.loadFromDirectory(_contractRoot);
  });

  group('§472 инвариант 4 — identity vless не меняется', () {
    test('каждый кейс корпуса даёт хеш из фикстуры', () {
      final before = _identityBefore();
      expect(before, hasLength(greaterThan(80)),
          reason: 'фикстура похудела — проверьте, не срезан ли корпус');
      for (final e in before.entries) {
        final uri = e.value['uri'] as String;
        final want = e.value['identity'] as String?;
        final spec = parseUri(uri);
        if (want == null) {
          // «Ссылка не разбирается вовсе» — тоже свойство, которое обязано
          // сохраниться: узел, которого раньше не было, появившись, влез бы
          // в подписку новым.
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
    }, skip: skip);

    test('identity всего корпуса vless считается и не пуста', () {
      final nodes = <NodeSpec>[];
      for (final u in _corpusUris()) {
        final spec = parseUri(u);
        if (spec != null) nodes.add(spec);
      }
      expect(nodes, isNotEmpty);
      // Идентичность = сырой тег: у узла с именем она есть всегда.
      expect(sourceNodeIdentities(nodes).length, nodes.length);
    }, skip: skip);
  });

  group('§472 инвариант 3 — parseUri(toUri()) ≈ spec', () {
    // Кейсы, которые круг не переживали и ДО переезда. Как и у trojan (шаг 2),
    // все расхождения принадлежат ОБЩЕЙ URI-эмиссии (`transport.dart` +
    // `node_spec_emit.dart`), не тронутой этим шагом.
    //
    // `enc-pq` — `encryption` длиной ~1600 символов: собранная обратно ссылка
    //   перерастает `maxURILength`, и `parseUri` её не берёт. Свойство
    //   потолка длины, а не разбора.
    //
    // `xhttp-mode-invalid`, `xhttp-bogus-plc` — значение вне enum'а XHTTP.
    //   ДО переезда оно жило в модели и уезжало обратно в ссылку
    //   (`mode=garbage`), а в тело не попадало: его срезал `toSingbox()`.
    //   Теперь его снимает санитайзер, и круг даёт ссылку без мусора. Тело и
    //   identity при этом те же — расходится только текст ссылки, и в
    //   сторону очистки.
    //
    const notIdempotent = {'enc-pq', 'xhttp-mode-invalid', 'xhttp-bogus-plc'};

    // Явный `path=/` в транспорте: `transportToQuery` его опускает
    // (`p != '/'`), и на обратном разборе путь становится пустым. Тот же
    // кейс, что `tr` у trojan (шаг 2, раздел 8.5), и такой же до переезда —
    // проверено на СТАРОМ пути напрямую. Разница видна только в теле
    // (`path:"/"` против отсутствия ключа), ядро трактует их одинаково.
    //
    // Отбор по СВОЙСТВУ тела, а не списком тегов: корпус растёт, и список
    // пришлось бы дописывать на каждый новый кейс с `path=%2F`, пряча за
    // ним настоящие расхождения.
    bool hasExplicitRootPath(NodeSpec s) {
      final t = s.emit(TemplateVars.empty).map['transport'];
      return t is Map && t['path'] == '/';
    }

    test('весь корпус vless переживает круг', () {
      var checked = 0;
      for (final u in _corpusUris()) {
        final a = parseUri(u);
        if (a == null) continue;
        if (notIdempotent.contains(a.tag)) continue;
        if (hasExplicitRootPath(a)) continue;
        final b = parseUri(a.toUri());
        expect(b, isNotNull, reason: 'круг потерял узел: $u');
        // Сравнение по ТЕЛУ: `id` случаен, `rawSource` у второго — уже
        // сгенерированная ссылка, и оба в identity не входят.
        expect(
          b!.emit(TemplateVars.empty).map,
          a.emit(TemplateVars.empty).map,
          reason: 'круг изменил тело: $u',
        );
        expect(legacyNodeIdentityHash(b), legacyNodeIdentityHash(a),
            reason: 'круг изменил identity: $u');
        checked++;
      }
      // Страж от «список исключений съел корпус».
      expect(checked, greaterThan(75));
    }, skip: skip);
  });

  group('§472 инвариант 5 — цена разбора', () {
    // Замер на рабочей машине (2000 узлов vless+reality+ws, прогон
    // `flutter test` в одиночку, вторая итерация — после прогрева JIT):
    //
    //   старый полный путь (parseVless + annotateAllWithRegistry)  ~222 мс
    //   конвейер (parseUri)                                        ~216 мс
    //   отношение                                                  ×0,97
    //
    // Инвариант 5 спеки — «не хуже ×1,5 к текущему». Сравнение честно только
    // на ПОЛНОЙ воронке: у старого пути санитайзер шёл отдельным проходом
    // ПОСЛЕ разбора, и разбор в отрыве от него мерил половину работы (шаг 2,
    // раздел 8.5). Конвейер здесь ДЕШЕВЛЕ старого пути: второго прохода по
    // `emit()` у его узлов нет вовсе (`isPipelineParsed`).
    //
    // Порог ниже — абсолютный потолок, а не проценты: миллисекунды на
    // CI-раннере и на ноутбуке несопоставимы, и тест на ±20 % был бы
    // флаки-генератором. Он ловит уход в квадратичность, запас десятикратный.
    // Берётся ЛУЧШИЙ из трёх прогонов: `flutter test -j 2` гоняет изоляты
    // параллельно, и рядом идёт такой же цикл trojan — первый замер под
    // соседом растягивался до ~12 с. При уходе в квадратичность медленны ВСЕ
    // три, так что чувствительности это не снижает.
    test('2000 vless-узлов разбираются за разумное время', () {
      const n = 2000;
      final uris = [
        for (var i = 0; i < n; i++)
          'vless://11111111-1111-1111-1111-11111111111$i@example-$i.com:443'
              '?type=ws&path=%2Fx%3Fed%3D2560&security=reality'
              '&pbk=AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw&sid=abcd'
              '&sni=example-$i.com&fp=chrome&alpn=h2,http/1.1#node$i',
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
        reason: 'разбор $n vless-узлов конвейером: $best мс (лучший из трёх)',
      );
    }, skip: skip);
  });

  group('§472 — коды vless приходят из реестра, с путём и сырым значением', () {
    test('мусорный fp судит реестр по написанному автором', () {
      final spec = parseUri(
          'vless://u@h.example:443?security=tls&fp=bogus&sni=x.com#n')!;
      final w = spec.warnings
          .whereType<RegistryWarning>()
          .firstWhere((w) => w.code == 'utls_fp_unknown');
      expect(w.path, 'tls.utls.fingerprint');
      expect(w.value, 'bogus');
    }, skip: skip);

    test('flow вне пары даёт flow_deprecated с путём', () {
      final spec = parseUri('vless://u@h.example:443?security=tls&sni=x.com'
          '&flow=xtls-rprx-direct#n')!;
      final w = spec.warnings
          .whereType<RegistryWarning>()
          .firstWhere((w) => w.code == 'flow_deprecated');
      expect(w.path, 'flow');
      expect(w.value, 'xtls-rprx-direct');
      expect(spec.emit(TemplateVars.empty).map.containsKey('flow'), isFalse);
    }, skip: skip);

    test('мусорный packetEncoding — код реестра, поле снято', () {
      final spec = parseUri('vless://u@h.example:443?security=tls&sni=x.com'
          '&packetEncoding=teleport#n')!;
      final w = spec.warnings
          .whereType<RegistryWarning>()
          .firstWhere((w) => w.code == 'packet_encoding_unknown');
      expect(w.path, 'packet_encoding');
      expect(w.value, 'teleport');
      expect((spec as VlessSpec).packetEncoding, '');
    }, skip: skip);

    test('негодный pbk снимает REALITY молча, кроме одного кода', () {
      // §169 — узел деградирует до plain TLS, а не выбрасывается. Коды
      // зависимых полей (`short_id`, `key_share`) при этом не ставятся: их
      // потеря уже объяснена (`body_sanitizer.dart`, `explainedDrops`).
      final spec = parseUri('vless://u@h.example:443?security=tls&sni=x.com'
          '&pbk=enabled&sid=abcd&key_share=hybrid#n')!;
      final codes =
          spec.warnings.map(warningCodeOf).whereType<String>().toList();
      expect(codes, ['reality_pbk_invalid']);
      final tls = spec.emit(TemplateVars.empty).map['tls'] as Map;
      expect(tls.containsKey('reality'), isFalse);
    }, skip: skip);

    test('sid только в другом регистре — нормализация без кода', () {
      // Корпус `reality_valid_pbk_sid`: `ABCD` → `abcd` молча. Регистр ничего
      // не ЗАБИРАЕТ, а `normalize_code` объявляет именно потерю.
      final spec = parseUri('vless://u@h.example:443?security=reality&sni=x.com'
          '&pbk=AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw&sid=ABCD#n')!;
      expect(spec.warnings.map(warningCodeOf),
          isNot(contains('reality_short_id_invalid')));
      final reality =
          (spec.emit(TemplateVars.empty).map['tls'] as Map)['reality'] as Map;
      expect(reality['short_id'], 'abcd');
    }, skip: skip);

    test('§453 dial-поля идут мимо санитайзера и не теряются', () {
      // Реестр их не описывает (`dialer.json` → `skipped`), и в теле
      // санитайзер снимал бы их как `unknown_key` вместе с настройкой
      // человека. См. `UriMapping.extensionFields`.
      final spec = parseUri('vless://u@h.example:443'
          '?tcp_keep_alive=30s&tcp_keep_alive_interval=15s'
          '&disable_tcp_keep_alive=1#KA')!;
      expect(spec.tcpKeepAlive?.idle, '30s');
      expect(spec.tcpKeepAlive?.interval, '15s');
      expect(spec.tcpKeepAlive?.disabled, isTrue);
      expect(spec.warnings.map(warningCodeOf), isNot(contains('unknown_key')));
    }, skip: skip);

    test('encryption из ссылки доезжает до тела', () {
      // §335 — до шага 3 `parseSingboxEntry` поле не читал вовсе, и на
      // конвейере узел уехал бы без постквантового слоя.
      final spec = parseUri('vless://u@h.example:443?security=none'
          '&encryption=mlkem768x25519plus.native.1rtt.AbCd#n')!;
      expect((spec as VlessSpec).encryption,
          'mlkem768x25519plus.native.1rtt.AbCd');
      expect(spec.emit(TemplateVars.empty).map['encryption'],
          'mlkem768x25519plus.native.1rtt.AbCd');
    }, skip: skip);
  });

  group('§472 — второй проход по emit() узла конвейера не дублирует коды', () {
    test('annotateAllWithRegistry на разобранном vless ничего не добавляет',
        () {
      final spec = parseUri(
          'vless://u@h.example:443?security=tls&fp=bogus&sni=x.com#n')!;
      final before = spec.warnings.length;
      annotateAllWithRegistry([spec]);
      expect(spec.warnings, hasLength(before),
          reason: 'второй проход задвоил коды узла конвейера');
    }, skip: skip);
  });
}
