import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'engine_test_setup.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/parse_warnings.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/contract/warning_codes.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §472 шаг 2, раздел 3 спеки — инварианты переезда trojan на конвейер.
///
/// Инварианты 1 и 2 (корпус и golden) держат свои тесты: корпус URI —
/// `test/contract/`, эталоны конфигов — `test/builder/`. Здесь то, что
/// специфично для переезда протокола: identity, round-trip и цена.
const _contractRoot = 'contract';

/// Хеши, теги и тела trojan-узлов лежат ФАЙЛОМ:
/// `test/fixtures/trojan/pipeline_identity_before.json`.
///
/// Шаг 2 §472 держал три кейса картой прямо здесь; задачей §480 снимок
/// доснят до тридцати пяти, и карта в литерале перестала читаться — формат
/// теперь общий с остальными схемами (`vless`, `masque`, `wireguard`).
///
/// Сверяет файл `before_480_identity_snapshot_test.dart`, а не этот тест: у
/// групп ниже гейт на вендоренную копию `app/contract/` (корпус), которой на
/// CI нет вовсе, и под ним снимок молча пропускался бы именно там, где он
/// нужнее всего. Снимок гейтится на зеркало реестра `assets/contract`.
void main() {
  setUpAll(loadEngineSections);

  final synced = Directory('$_contractRoot/registry').existsSync();
  final skip = synced ? null : 'контракт не синхронизирован';

  setUpAll(() async {
    if (!synced) return;
    await ContractRegistry.I.loadFromDirectory(_contractRoot);
  });

  group('§472 инвариант 4 — identity trojan не меняется', () {
    test('identity всего корпуса trojan считается и не пуста', () {
      final nodes = <NodeSpec>[];
      for (final f in Directory('$_contractRoot/corpus/uri/trojan')
          .listSync()
          .whereType<File>()) {
        if (!f.path.endsWith('.uri')) continue;
        for (final line in f.readAsLinesSync()) {
          final t = line.trim();
          if (t.isEmpty || t.startsWith('#')) continue;
          final spec = parseUri(t);
          if (spec != null) nodes.add(spec);
        }
      }
      expect(nodes, isNotEmpty);
      final ids = sourceNodeIdentities(nodes);
      // Идентичность = сырой тег: у узла с именем она есть всегда.
      expect(ids.length, nodes.length);
    }, skip: skip);
  });

  group('§472 инвариант 3 — parseUri(toUri()) ≈ spec', () {
    // Кейсы, которые круг не переживали и ДО переезда. Оба расхождения
    // принадлежат общей URI-эмиссии (`transport.dart`), не тронутой шагом 2:
    // проверено напрямую на `parseTransport` + `transportToQuery`, в обход
    // конвейера, — результат тот же.
    //
    // `triple-enc` — снятие остаточного percent-кодирования
    //   (`decodeResidualPercent`, §320) ограничено двумя проходами и потому
    //   не идемпотентно: `/%25252F` → `/%2F` на первом разборе и `//` на
    //   втором. Потолок нормирован корпусом
    //   (`ws_path_triple_encoded_depth2`) — менять его здесь нельзя.
    //
    // `tr` — явный `path=/`: `transportToQuery` его опускает (`p != '/'`), и
    //   на обратном разборе путь становится пустым. Разница видна только в
    //   теле (`path:"/"` против отсутствия ключа), ядро трактует их
    //   одинаково.
    //
    // Чинить их шагом 2 нельзя: правка общей эмиссии задела бы остальные
    // двенадцать схем и золотые эталоны. Отдельная задача.
    const notIdempotent = {'triple-enc', 'tr'};

    test('весь корпус trojan переживает круг', () {
      var checked = 0;
      for (final f in Directory('$_contractRoot/corpus/uri/trojan')
          .listSync()
          .whereType<File>()) {
        if (!f.path.endsWith('.uri')) continue;
        for (final line in f.readAsLinesSync()) {
          final t = line.trim();
          if (t.isEmpty || t.startsWith('#')) continue;
          final a = parseUri(t);
          if (a == null) continue;
          if (notIdempotent.contains(a.tag)) continue;
          final b = parseUri(a.toUri());
          expect(b, isNotNull, reason: 'круг потерял узел: $t');
          // Сравнение по ТЕЛУ: `id` случаен, `rawSource` у второго — уже
          // сгенерированная ссылка, и оба в identity не входят.
          expect(
            b!.emit(TemplateVars.empty).map,
            a.emit(TemplateVars.empty).map,
            reason: 'круг изменил тело: $t',
          );
          expect(legacyNodeIdentityHash(b), legacyNodeIdentityHash(a),
              reason: 'круг изменил identity: $t');
          checked++;
        }
      }
      // Страж от «список исключений съел корпус».
      expect(checked, greaterThan(25));
    }, skip: skip);
  });

  group('§472 инвариант 5 — цена разбора', () {
    // Замер на рабочей машине (2000 узлов, release-прогон `flutter test`):
    //
    //   старый полный путь trojan (парсер + annotateAllWithRegistry)  ~155 мс
    //   конвейер (parseAll)                                           ~193 мс
    //   отношение                                                     ×1,25
    //
    // Инвариант 5 спеки — «не хуже ×1,5 к текущему». Сравнение честно только
    // на ПОЛНОЙ воронке: у старого пути санитайзер шёл отдельным проходом
    // ПОСЛЕ разбора, и `parseTrojan` в отрыве от него мерил половину работы
    // (там отношение выглядело как ×3,5 и было артефактом замера).
    //
    // Порог ниже — абсолютный потолок, а не проценты: миллисекунды на
    // CI-раннере и на ноутбуке несопоставимы, и тест на ±20 % был бы
    // флаки-генератором. Он ловит уход в квадратичность, запас десятикратный.
    //
    // §472 шаг 3 — берётся ЛУЧШИЙ из трёх прогонов, а не первый. `flutter
    // test -j 2` гоняет изоляты параллельно, и шагом 3 рядом встал такой же
    // перф-тест vless: два цикла по 2000 узлов на одной машине растягивали
    // первый замер до ~12 с — при уходе в квадратичность медленны ВСЕ три,
    // так что чувствительность теста это не снижает.
    test('2000 trojan-узлов разбираются за разумное время', () {
      const n = 2000;
      final nodes = <NodeSpec>[];
      final uris = [
        for (var i = 0; i < n; i++)
          'trojan://pass123@example-$i.com:443?type=ws'
              '&path=%2Fx%3Fed%3D2560&security=tls&sni=example-$i.com'
              '&fp=chrome&alpn=h2,http/1.1#node$i',
      ];

      // Прогрев кэша схем и JIT.
      for (var i = 0; i < 200; i++) {
        parseUri(uris[i]);
      }

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
        reason: 'разбор $n trojan-узлов конвейером: $best мс (лучший из трёх)',
      );
    }, skip: skip);
  });

  group('§472 — второй проход по emit() узла конвейера не дублирует коды', () {
    test('annotateAllWithRegistry на разобранном узле ничего не добавляет', () {
      // Мусорный отпечаток: код ставит санитайзер конвейера по СЫРОМУ
      // значению ссылки.
      final spec = parseUri(
          'trojan://p@h.example:443?security=tls&fp=bogus&sni=x.com#n')!;
      final before = spec.warnings.length;
      final codes = spec.warnings.map(warningCodeOf).whereType<String>();
      expect(codes, contains('utls_fp_unknown'));

      annotateAllWithRegistry([spec]);
      expect(spec.warnings, hasLength(before),
          reason: 'второй проход задвоил коды узла конвейера');

      // И `value` называет то, что написал автор ссылки, а не канон.
      final w = spec.warnings
          .whereType<RegistryWarning>()
          .firstWhere((w) => w.code == 'utls_fp_unknown');
      expect(w.value, 'bogus');
    }, skip: skip);
  });
}
