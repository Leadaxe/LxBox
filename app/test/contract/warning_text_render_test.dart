// §474 (контракт 1.1.6) — рендер текстов ВСЕХ кодов реестра.
//
// Тексты кодов — данные контракта, и в них есть подстановки: `{path}`,
// `{value}` и то, что код объявил сам в `params`. Незаполненный плейсхолдер
// человек видит буквально — «В записи задано {path} = {value}» вместо адреса
// и значения, — и молча такое доезжает до экрана.
//
// Ловилось это раньше только глазами и только на том коде, который кто-то
// открыл. Повод завести страж дал сам контракт 1.1.6: у `vision_with_transport`
// набор `params` сменился с `["transport"]` на `["path","with"]`, а у
// `tls_insecure` был пуст при двух плейсхолдерах в тексте. Обе правки прошли
// у лаунчера — наши подстановки обязаны за ними поспевать.
//
// Что именно проверяется: каждый код реестра отрисован на обоих языках во всех
// четырёх местах (`title`/`text`/`cause`/`fix`) с ТИПОВЫМИ параметрами, и в
// результате не осталось `{…}`. Типовые — это `path`/`value` (подставляются
// всегда, `text_params_implicit`) плюс каждое имя из `params` кода. Если текст
// зовёт плейсхолдер, которого код не объявил, заполнить его неоткуда, и тест
// падает — чинится это в реестре, у лаунчера.
//
// Реестр грузится из `assets/contract` — зеркала в git: `app/contract/` на CI
// нет вовсе (гейт `existsSync` у тестов, которые читают копию), а зеркало едет
// в APK и лежит в репозитории.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../contract_paths.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/contract/registry_warning.dart';


/// Плейсхолдер в тексте реестра: `{path}`, `{with}`, `{method}`.
final _placeholder = RegExp(r'\{([a-z_][a-z0-9_]*)\}');

/// Коды, у которых текст зовёт плейсхолдер, не объявленный в `params`.
///
/// Заполнить такой неоткуда: подстановки ставит НАША сторона по объявлению
/// кода, а объявление — часть реестра. Пустой список — норма; запись здесь
/// означает открытый запрос к лаунчеру и обязана нести его номер.
const Map<String, String> _knownUndeclared = {};

void main() {
  setUpAll(loadTestRegistry);

  group('§474 — тексты кодов реестра рендерятся без дыр', () {
    test('у каждого кода все тексты заполнены на en и ru', () {
      final codes = _allCodes();
      expect(codes, isNotEmpty, reason: 'warnings.json не прочитан');

      final holes = <String>[];
      for (final code in codes) {
        final declared = ContractRegistry.I.textFor(code)?.params ?? const [];
        // Типовые параметры: явные `path`/`value` плюс всё, что код объявил.
        // Значения приметные — по ним видно, ЧТО не подставилось, если тест
        // упадёт на длинном тексте.
        final params = <String, String>{
          for (final p in declared)
            if (p != 'path' && p != 'value') p: '<$p>',
        };
        for (final lang in RegistryLang.values) {
          final rendered = <String>[
            registryTitle(code, lang,
                path: '<path>', value: '<value>', params: params),
            registryText(code, lang,
                path: '<path>', value: '<value>', params: params),
            registryCause(code, lang,
                    path: '<path>', value: '<value>', params: params) ??
                '',
            ...registryFix(code, lang,
                path: '<path>', value: '<value>', params: params),
          ];
          for (final s in rendered) {
            for (final m in _placeholder.allMatches(s)) {
              final name = m.group(1)!;
              if (_knownUndeclared.containsKey(code)) continue;
              holes.add('$code [${lang.name}]: {$name} не заполнен');
            }
          }
        }
      }
      expect(holes, isEmpty,
          reason: 'плейсхолдеры без подстановки:\n${holes.join('\n')}');
    });

    test('у каждого известного расхождения есть причина', () {
      for (final e in _knownUndeclared.entries) {
        expect(e.value.trim(), isNotEmpty,
            reason: 'расхождение ${e.key} без причины');
      }
    });

    // §474 — два кода, чьи `params` контракт 1.1.6 переписал. Проверяются
    // поимённо: общий тест выше упал бы и на них, но не сказал бы, ЧТО
    // именно разъехалось.
    test('tls_insecure объявляет path и value, severity info', () {
      final t = ContractRegistry.I.textFor('tls_insecure');
      expect(t, isNotNull);
      expect(t!.severity, 'info');
      expect(t.params, containsAll(<String>['path', 'value']));
    });

    // §474 (контракт 1.1.7) — код подмены `vmess.security`. Общий
    // `type_invalid` здесь врал: поле не снимается, а подменяется.
    test('vmess_security_unknown объявляет path и value, severity warning', () {
      final t = ContractRegistry.I.textFor('vmess_security_unknown');
      expect(t, isNotNull);
      expect(t!.severity, 'warning');
      expect(t.params, containsAll(<String>['path', 'value']));
    });

    // Четыре кода, у которых рукописный класс снят и текст взят из реестра.
    // Проверяется то, ради чего снимали: severity не съехал (все четыре были
    // `info` классом и обязаны остаться `info` реестром) и объявленный
    // параметр называется так, как его заполняет `NodeWarning.byCode` —
    // разойдись имена, человек прочёл бы `{query_name}` буквально.
    test('снятые классы: severity info и объявленный параметр на месте', () {
      const expected = <String, String?>{
        'ech_ignored': 'query_name',
        'ws_early_data_converted': 'max_early_data',
        'naive_extra_headers_invalid': 'entry',
        // `value` подставляется всегда (`text_params_implicit`), своего
        // имени коду не нужно.
        'naive_padding_ignored': null,
      };
      for (final e in expected.entries) {
        final t = ContractRegistry.I.textFor(e.key);
        expect(t, isNotNull, reason: 'кода ${e.key} нет в реестре');
        expect(t!.severity, 'info', reason: e.key);
        if (e.value != null) {
          expect(t.params, contains(e.value), reason: e.key);
        }
      }
    });

    test('vision_with_transport объявляет with, severity info', () {
      final t = ContractRegistry.I.textFor('vision_with_transport');
      expect(t, isNotNull);
      expect(t!.severity, 'info');
      expect(t.params, contains('with'));
      // `transport` из набора ушёл — текст зовёт `{with}`, и старое имя
      // не подставилось бы никогда.
      expect(t.params, isNot(contains('transport')));
    });
  });
}

/// Все коды `registry/warnings.json`. Читается файл, а не реестр: список кодов
/// нужен ДО того, как что-то из них отрисовано.
List<String> _allCodes() {
  final f = File('$kRegistryRoot/registry/warnings.json');
  if (!f.existsSync()) return const [];
  final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final byCode = (raw['warnings'] as Map).cast<String, dynamic>();
  return byCode.keys.toList()..sort();
}
