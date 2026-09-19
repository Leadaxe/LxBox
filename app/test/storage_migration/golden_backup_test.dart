import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'golden_harness.dart';

import '../parser/engine_test_setup.dart';

// §439 волна 0 — LX Backup 1.0 (писатель §438) из фикстуры хранения и круг
// «экспорт → импорт в пустое хранение → сборка конфига».
//
// Эталоны:
//   • `golden/<name>.backup.json` — файл экспорта; `exported_at`,
//     `exported_by.version` и `id` частей разделённого json-массива
//     (`<имя> #N`, миграция выдаёт им новый `id` при каждом прогоне, §439
//     §4.2) нормализованы;
//   • `golden/<name>.backup_roundtrip.json` — что круг теряет УЖЕ сегодня:
//     предупреждения экспорта и импорта и разница `config.json` после
//     импорта против `golden/<name>.config.json` (строки `путь: было →
//     стало`). Это ожидание, а не список багов к починке в волне 0: волны 439
//     обязаны его не расширять.
//
// Пустое хранение — новая установка без стартовых засевов (`directions`,
// пресеты по умолчанию): кэш тел подписок и скачанные `.srs` те же, что у
// фикстуры, — на живом устройстве их принесли бы сеть и загрузчик.

void main() {
  // §480 — разбор исполняет секции реестра; без них конвейера нет вовсе
  // (критерий 7 спеки 480).
  setUpAll(loadEngineSections);

  for (final name in kStorageFixtures) {
    test('$name: экспорт LX Backup и круг экспорт → импорт → конфиг', () async {
      final source = await StorageSandbox.create();
      addTearDown(source.dispose);
      await source.seed(name);
      final exported = await exportGoldenLxBackup();
      expectGolden('$name.backup.json', _withSplitIdsMasked(exported.json));

      final target = await StorageSandbox.create();
      addTearDown(target.dispose);
      await target.seed(name, storage: false);
      final parsed = await importGoldenLxBackup(exported.json);
      final rebuilt = await buildGoldenConfig(target);

      final golden = goldenFile('$name.config.json');
      final expectedConfig = golden.existsSync()
          ? jsonDecode(golden.readAsStringSync())
          : null;
      expect(expectedConfig, isNotNull,
          reason: 'нет ${golden.path}: сначала golden_config_test');

      final roundtrip = {
        'export_warnings': [for (final w in exported.warnings) warningLine(w)],
        'import_warnings': [for (final w in parsed.warnings) warningLine(w)],
        'config_diff': jsonDiff(expectedConfig, rebuilt.config),
      };
      expectGolden('$name.backup_roundtrip.json', prettyJson(roundtrip));
    });
  }
}

/// Плейсхолдер `id` части разделённого json-массива в эталоне.
const _kSplitPartId = '<split-part-id>';

/// Экспорт с `id` записей `rules[]`, заведённых делением json-массива
/// (`<имя> #N`), заменённым на [_kSplitPartId]: ключ в файле есть, значение
/// от прогона к прогону разное.
String _withSplitIdsMasked(String json) {
  final doc = jsonDecode(json) as Map<String, dynamic>;
  final rules = doc['rules'];
  if (rules is List) {
    final split = RegExp(r' #\d+$');
    for (final r in rules) {
      if (r is Map &&
          r['id'] is String &&
          r['name'] is String &&
          split.hasMatch(r['name'] as String)) {
        r['id'] = _kSplitPartId;
      }
    }
  }
  return prettyJson(doc);
}
