import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/traffic_profiler.dart';
import 'package:lxbox/screens/stats_screen/profiler_filter.dart';
import 'package:lxbox/screens/stats_screen/profiler_filters.dart';

/// §244 — тесты session-холдера фильтров профайлера (баг B4 с 4PDA: фильтр
/// слетал при переключении вкладок). Инвариант: инстансы стабильны между
/// обращениями, состояние переживает «пересоздание вкладки» (новый State
/// берёт фильтр из холдера и видит прежний выбор), appTab/liveTab независимы.
///
/// Widget-часть — изолированное поддерево (фейковая «вкладка» по паттерну
/// tab-State), БЕЗ TrafficProfiler-стриминга и platform-каналов (грабля §214:
/// testWidgets + _invoke виснут).

/// Фейковая «вкладка»: повторяет паттерн работы tab-State с session-фильтром
/// (addListener в initState, removeListener в dispose, НИКАКОГО
/// filter.dispose()). Показывает activeCount — как бейдж Filter (N).
class _FakeTab extends StatefulWidget {
  const _FakeTab({required this.filter});

  final ProfilerFilter filter;

  @override
  State<_FakeTab> createState() => _FakeTabState();
}

class _FakeTabState extends State<_FakeTab> {
  @override
  void initState() {
    super.initState();
    widget.filter.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.filter.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Text('active:${widget.filter.activeCount}',
        textDirection: TextDirection.ltr);
  }
}

void main() {
  // Session-статики живут через все тесты файла — чистим между тестами,
  // чтобы порядок выполнения не влиял.
  tearDown(() {
    ProfilerFilters.appTab.clearAll();
    ProfilerFilters.liveTab.clearAll();
  });

  group('ProfilerFilters — session-холдер (§244)', () {
    test('appTab и liveTab — разные независимые объекты', () {
      expect(identical(ProfilerFilters.appTab, ProfilerFilters.liveTab),
          isFalse);
      ProfilerFilters.liveTab.search = 'telegram';
      ProfilerFilters.liveTab.toggleKind(TrafficEventKind.dnsResolve, true);
      // App-фильтр не затронут.
      expect(ProfilerFilters.appTab.isActive, isFalse);
      expect(ProfilerFilters.appTab.search, '');
    });

    test('состояние видно «новому State» (симуляция пересоздания вкладки)',
        () {
      // «Старый State» вкладки настраивает фильтр…
      final before = ProfilerFilters.liveTab;
      before.search = 'example.com';
      before.toggleApp('com.android.chrome', true);
      before.toggleRule('ru-direct', true);
      before.includeUnattributed = true;

      // …State диспоузится (уход с вкладки), «новый State» берёт фильтр из
      // холдера заново — тот же объект с тем же состоянием.
      final after = ProfilerFilters.liveTab;
      expect(identical(before, after), isTrue);
      expect(after.search, 'example.com');
      expect(after.hasApp('com.android.chrome'), isTrue);
      expect(after.hasRule('ru-direct'), isTrue);
      expect(after.includeUnattributed, isTrue);
      expect(after.activeCount, 4);
    });
  });
}
