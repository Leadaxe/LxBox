import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/memory_limit_setting.dart';

/// §271 — wire-протокол memory limit: normalize и состав значений.
void main() {
  group('MemoryLimitSetting.normalize', () {
    test('валидные wire-значения проходят как есть', () {
      for (final v in MemoryLimitSetting.values) {
        expect(MemoryLimitSetting.normalize(v), v);
      }
    });

    test('мусор / null / пустая строка → auto', () {
      expect(MemoryLimitSetting.normalize(null), MemoryLimitSetting.auto);
      expect(MemoryLimitSetting.normalize(''), MemoryLimitSetting.auto);
      expect(MemoryLimitSetting.normalize('banana'), MemoryLimitSetting.auto);
      // Число вне пресетов — не изобретаем значения, откатываемся в auto.
      expect(MemoryLimitSetting.normalize('1024'), MemoryLimitSetting.auto);
      expect(MemoryLimitSetting.normalize('OFF'), MemoryLimitSetting.auto);
    });

    test('состав значений стабилен (wire-контракт с native и бэкапом)', () {
      expect(MemoryLimitSetting.values,
          ['auto', 'off', '200', '384', '512', '768']);
    });
  });
}
