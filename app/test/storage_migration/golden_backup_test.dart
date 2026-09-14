import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'golden_harness.dart';

// §439 волна 0 — LX Backup 1.0 (писатель §438) из фикстуры хранения и круг
// «экспорт → импорт в пустое хранение → сборка конфига».
//
// Эталоны:
//   • `golden/<name>.backup.json` — файл экспорта; `exported_at` и
//     `exported_by.version` нормализованы;
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
  for (final name in kStorageFixtures) {
    test('$name: экспорт LX Backup и круг экспорт → импорт → конфиг', () async {
      final source = await StorageSandbox.create();
      addTearDown(source.dispose);
      await source.seed(name);
      final exported = await exportGoldenLxBackup();
      expectGolden('$name.backup.json', exported.json);

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
