import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../contract_paths.dart';

import 'engine_test_setup.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/parse_warnings.dart';
import 'package:lxbox/services/contract/warning_codes.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §472 шаг 2, раздел 3 спеки — инварианты переезда trojan на конвейер.
///
/// Инварианты 1 и 2 (корпус и golden) держат свои тесты: корпус URI —
/// `test/contract/`, эталоны конфигов — `test/builder/`. Здесь то, что
/// специфично для переезда протокола: round-trip.

void main() {
  final corpusSkip = corpusTestSkip('test/parser/trojan_pipeline_invariants_test.dart');
  setUpAll(loadEngineSections);

  setUpAll(() async {
    await loadTestRegistry();
  });

  group('§472 инвариант 3 — parseUri(toUri()) ≈ spec', () {
    // Кейсы, которые круг не переживали и ДО переезда. Оба расхождения
    // принадлежат общей URI-эмиссии, не тронутой шагом 2: на момент шага это
    // было проверено напрямую на `parseTransport` + `transportToQuery`, в
    // обход конвейера, — результат тот же. С §480 W7 обратный ход ведёт
    // секция-маппер, и рукописного `transportToQuery` больше нет; оба
    // расхождения остались прежними, они свойство правил, а не слоя.
    //
    // `triple-enc` — снятие остаточного percent-кодирования
    //   (`decodeResidualPercent`, §320) ограничено двумя проходами и потому
    //   не идемпотентно: `/%25252F` → `/%2F` на первом разборе и `//` на
    //   втором. Потолок нормирован корпусом
    //   (`ws_path_triple_encoded_depth2`) — менять его здесь нельзя.
    //
    // `tr` — явный `path=/`: эмиссия его опускает как равный умолчанию, и
    //   на обратном разборе путь становится пустым. Разница видна только в
    //   теле (`path:"/"` против отсутствия ключа), ядро трактует их
    //   одинаково.
    //
    // Чинить их шагом 2 нельзя: правка общей эмиссии задела бы остальные
    // двенадцать схем и золотые эталоны. Отдельная задача.
    const notIdempotent = {'triple-enc', 'tr'};

    test('весь корпус trojan переживает круг', () {
      var checked = 0;
      for (final f in Directory('$kVendorRoot/corpus/uri/trojan')
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
    }, skip: corpusSkip);
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
    });
  });
}
