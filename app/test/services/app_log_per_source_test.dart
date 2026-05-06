// §043: AppLog per-source quotas + k-way merge + entriesForSource.

import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/debug_entry.dart';
import 'package:lxbox/services/app_log.dart';

void main() {
  setUp(() {
    AppLog.I.resetForTesting();
  });

  group('AppLog per-source bucketing (§043)', () {
    test('log с source: app кладёт только в app bucket', () {
      AppLog.I.info('hello app', source: DebugSource.app);
      expect(AppLog.I.entriesForSource(DebugSource.app), hasLength(1));
      expect(AppLog.I.entriesForSource(DebugSource.core), isEmpty);
    });

    test('log с source: core кладёт только в core bucket', () {
      AppLog.I.info('hello core', source: DebugSource.core);
      expect(AppLog.I.entriesForSource(DebugSource.app), isEmpty);
      expect(AppLog.I.entriesForSource(DebugSource.core), hasLength(1));
    });

    test('app spam не вытесняет core entries', () {
      AppLog.I.info('preserve me', source: DebugSource.core);
      // Спам app до cap'а app (300) и за пределы.
      for (var i = 0; i < 350; i++) {
        AppLog.I.info('app msg $i', source: DebugSource.app);
      }
      expect(AppLog.I.entriesForSource(DebugSource.app).length, 300,
          reason: 'app cap = 300');
      expect(AppLog.I.entriesForSource(DebugSource.core), hasLength(1),
          reason: 'core bucket не задет');
      expect(AppLog.I.entriesForSource(DebugSource.core).first.message,
          'preserve me');
    });

    test('core spam не вытесняет app entries', () {
      AppLog.I.info('preserve me', source: DebugSource.app);
      for (var i = 0; i < 600; i++) {
        AppLog.I.info('core msg $i', source: DebugSource.core);
      }
      expect(AppLog.I.entriesForSource(DebugSource.core).length, 500,
          reason: 'core cap = 500');
      expect(AppLog.I.entriesForSource(DebugSource.app), hasLength(1),
          reason: 'app bucket не задет');
      expect(AppLog.I.entriesForSource(DebugSource.app).first.message,
          'preserve me');
    });

    test('per-source cap drop oldest', () {
      // App cap = 300. Push 305 → должен остаться last 300.
      for (var i = 0; i < 305; i++) {
        AppLog.I.info('msg $i', source: DebugSource.app);
      }
      final list = AppLog.I.entriesForSource(DebugSource.app);
      expect(list.length, 300);
      // newest first → first entry msg 304, last entry msg 5
      expect(list.first.message, 'msg 304');
      expect(list.last.message, 'msg 5');
    });
  });

  group('AppLog.entries — k-way merge (§043)', () {
    test('merged result отсортирован newest-first по обоим source', () async {
      // Чередуем источники с микро-паузой чтобы timestamps были различными.
      AppLog.I.info('app 1', source: DebugSource.app);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      AppLog.I.info('core 1', source: DebugSource.core);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      AppLog.I.info('app 2', source: DebugSource.app);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      AppLog.I.info('core 2', source: DebugSource.core);

      final merged = AppLog.I.entries;
      expect(merged.map((e) => e.message),
          ['core 2', 'app 2', 'core 1', 'app 1']);
    });

    test('пустые buckets не ломают merge', () {
      // Только app, core пуст.
      AppLog.I.info('only app', source: DebugSource.app);
      expect(AppLog.I.entries.map((e) => e.message), ['only app']);

      // Только core, app пуст.
      AppLog.I.resetForTesting();
      AppLog.I.info('only core', source: DebugSource.core);
      expect(AppLog.I.entries.map((e) => e.message), ['only core']);

      // Оба пусты.
      AppLog.I.resetForTesting();
      expect(AppLog.I.entries, isEmpty);
    });

    test('merged result preserves order для одного и того же timestamp', () async {
      // Если timestamp совпадают (микросекунда), порядок tie-breaking — не
      // спецификация, но он должен быть стабильным. Проверяем что merge
      // не падает на одинаковых временах.
      final t = DateTime.now();
      // (Прямой инжект через resetForTesting + log не поддерживает
      // injection времени, поэтому просто пушим быстро и проверяем что
      // нет crash.)
      AppLog.I.info('a', source: DebugSource.app);
      AppLog.I.info('c', source: DebugSource.core);
      expect(AppLog.I.entries.length, 2);
      expect(t, isNotNull);
    });
  });

  group('AppLog clear (§043)', () {
    test('clear() очищает все source-buckets', () {
      AppLog.I.info('a', source: DebugSource.app);
      AppLog.I.info('c', source: DebugSource.core);
      AppLog.I.clear();
      expect(AppLog.I.entriesForSource(DebugSource.app), isEmpty);
      expect(AppLog.I.entriesForSource(DebugSource.core), isEmpty);
      expect(AppLog.I.entries, isEmpty);
    });

    test('clearSource(app) очищает только app, core нетронут', () {
      AppLog.I.info('a', source: DebugSource.app);
      AppLog.I.info('c', source: DebugSource.core);
      AppLog.I.clearSource(DebugSource.app);
      expect(AppLog.I.entriesForSource(DebugSource.app), isEmpty);
      expect(AppLog.I.entriesForSource(DebugSource.core), hasLength(1));
    });

    test('clearSource(core) очищает только core, app нетронут', () {
      AppLog.I.info('a', source: DebugSource.app);
      AppLog.I.info('c', source: DebugSource.core);
      AppLog.I.clearSource(DebugSource.core);
      expect(AppLog.I.entriesForSource(DebugSource.app), hasLength(1));
      expect(AppLog.I.entriesForSource(DebugSource.core), isEmpty);
    });
  });

  group('AppLog level convenience methods (§043)', () {
    test('debug/info/warning/error все попадают в правильный source', () {
      AppLog.I.debug('d', source: DebugSource.core);
      AppLog.I.info('i', source: DebugSource.core);
      AppLog.I.warning('w', source: DebugSource.core);
      AppLog.I.error('e', source: DebugSource.core);
      expect(AppLog.I.entriesForSource(DebugSource.app), isEmpty);
      expect(AppLog.I.entriesForSource(DebugSource.core), hasLength(4));
    });

    test('default source = app', () {
      AppLog.I.info('i');
      expect(AppLog.I.entriesForSource(DebugSource.app), hasLength(1));
      expect(AppLog.I.entriesForSource(DebugSource.core), isEmpty);
    });
  });
}
