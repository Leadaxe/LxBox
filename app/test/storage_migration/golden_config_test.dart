import 'package:flutter_test/flutter_test.dart';

import '../parser/engine_test_setup.dart';
import 'golden_harness.dart';

// §439 волна 0 — `config.json` из фикстуры хранения текущим билдером.
//
// Эталон `golden/<name>.config.json` сверяется байт в байт; каждая следующая
// волна 439 (граница хранения, форма 1.0, миграция) обязана оставить его
// зелёным. `golden/<name>.config_warnings.json` — предупреждения той же
// сборки: исчезнувший heal или новый дроп виден сразу.
//
// Нормализация (описана в golden_harness.dart): версия ядра и корень
// Tailscale фиксированы, временный каталог в путях кэша `.srs` заменён на
// `<sandbox>`. Вторая сборка из того же хранения (после сброса кэшей и
// записей первой сборки на диск) обязана дать те же байты: так ловится
// недетерминированность билдера.

void main() {
  // §480 — узлы хранения пересобираются конвейером, исполняющим секции
  // реестра; без загрузки секций сборка даёт пустой состав.
  setUpAll(loadEngineSections);

  for (final name in kStorageFixtures) {
    test('$name: config.json совпадает с эталоном', () async {
      final box = await StorageSandbox.create();
      addTearDown(box.dispose);
      await box.seed(name);

      final first = await buildGoldenConfig(box);
      final second = await buildGoldenConfig(box);
      expect(second.configJson, first.configJson,
          reason: 'две сборки одного хранения разошлись:\n'
              '${jsonDiff(first.config, second.config).join('\n')}');
      expect(second.warnings, first.warnings);

      expectGolden('$name.config.json', first.configJson);
      expectGolden('$name.config_warnings.json', prettyJson(first.warnings));
    });
  }
}
