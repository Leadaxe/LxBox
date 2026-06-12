import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/home_state.dart';
import 'package:lxbox/screens/home/widgets/app_banner.dart';

/// §116 — `activeBanners` это чистая проекция состояния → список плашек.
/// Тестируем маппинг каждого guard'а и взаимные исключения.
void main() {
  final actions = BannerActions(
    onRebuild: () {},
    onConfirmStop: () {},
    onClearError: () {},
  );

  Set<String> keys(
    HomeState s, {
    bool configDirty = false,
    bool busy = false,
  }) =>
      activeBanners(s, configDirty: configDirty, busy: busy, actions: actions)
          .map((b) => b.key)
          .toSet();

  AppBanner byKey(
    HomeState s,
    String key, {
    bool configDirty = false,
    bool busy = false,
  }) =>
      activeBanners(s, configDirty: configDirty, busy: busy, actions: actions)
          .firstWhere((b) => b.key == key);

  group('§116 activeBanners', () {
    test('пустое состояние → нет плашек', () {
      expect(keys(HomeState()), isEmpty);
    });

    test('configDirty && !busy → settings_changed', () {
      expect(keys(HomeState(), configDirty: true), {'settings_changed'});
    });

    test('configDirty && busy → плашки нет (idle-guard)', () {
      expect(keys(HomeState(), configDirty: true, busy: true), isEmpty);
    });

    test('tunnelUp + configChangedNeedRestart + !configDirty → restart', () {
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configChangedNeedRestart: true,
      );
      expect(keys(s), {'restart'});
    });

    test('restart НЕ показывается при configDirty (сначала Apply)', () {
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configChangedNeedRestart: true,
      );
      // configDirty=true перебивает restart → только settings_changed.
      expect(keys(s, configDirty: true), {'settings_changed'});
    });

    test('restart НЕ показывается при выключенном туннеле', () {
      final s = HomeState(configChangedNeedRestart: true);
      expect(keys(s), isEmpty);
    });

    test('configLoadError → config_load_error (error-палитра, рестарт-иконка)',
        () {
      final s = HomeState(configLoadError: true);
      expect(keys(s), {'config_load_error'});
      final b = byKey(s, 'config_load_error');
      expect(b.palette, BannerPalette.error);
      expect(b.autoDismiss, isNull, reason: 'persistent до загрузки');
      expect(b.onTap, isNotNull, reason: 'тап = рестарт');
    });

    test('lastError → last_error, transient 15с + onDismiss', () {
      final s = HomeState(lastError: 'boom');
      final b = byKey(s, 'last_error');
      expect(b.message, 'boom');
      expect(b.autoDismiss, const Duration(seconds: 15));
      expect(b.onDismiss, isNotNull);
      expect(b.palette, BannerPalette.error);
    });

    test('несколько условий → стабильный порядок', () {
      final s = HomeState(
        tunnel: TunnelStatus.connected,
        configChangedNeedRestart: true,
        configLoadError: true,
        lastError: 'boom',
      );
      final list = activeBanners(s,
          configDirty: false, busy: false, actions: actions);
      expect(list.map((b) => b.key).toList(),
          ['restart', 'config_load_error', 'last_error']);
    });
  });
}
