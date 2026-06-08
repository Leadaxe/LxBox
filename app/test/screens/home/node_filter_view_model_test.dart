import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/home/node_filter_view_model.dart';

/// §085 R3 — unit tests для NodeFilterViewModel (извлечён из home_screen).
/// Раньше эта логика жила в _HomeScreenState и была не покрыта тестами.
void main() {
  late NodeFilterViewModel vm;
  late int notifications;

  setUp(() {
    vm = NodeFilterViewModel();
    notifications = 0;
    vm.addListener(() => notifications++);
  });

  tearDown(() => vm.dispose());

  group('defaults', () {
    test('чистое состояние', () {
      expect(vm.showDetour, true);
      expect(vm.showNonMatching, true);
      expect(vm.panelExpanded, false);
      expect(vm.regexEnabled, false);
      expect(vm.regexInvert, false);
      expect(vm.regexValid, true);
      expect(vm.activeRegex, isNull);
      expect(vm.enabledProtocols, isEmpty);
      expect(vm.enabledSubscriptions, isEmpty);
      expect(vm.pingEnabled, false);
      expect(vm.activeMaxPingMs, isNull);
      expect(vm.isActive, false);
    });
  });

  group('toggles notify', () {
    test('togglePanel', () {
      vm.togglePanel();
      expect(vm.panelExpanded, true);
      expect(notifications, 1);
    });
    test('setShowDetour / setShowNonMatching', () {
      vm.setShowDetour(false);
      vm.setShowNonMatching(false);
      expect(vm.showDetour, false);
      expect(vm.showNonMatching, false);
      expect(notifications, 2);
    });
    test('toggleProtocol add/remove', () {
      vm.toggleProtocol('vless');
      expect(vm.enabledProtocols, {'vless'});
      expect(vm.isActive, true);
      vm.toggleProtocol('vless');
      expect(vm.enabledProtocols, isEmpty);
      expect(notifications, 2);
    });
    test('toggleSubscription add/remove', () {
      vm.toggleSubscription('sub-1');
      expect(vm.enabledSubscriptions, {'sub-1'});
      expect(vm.isActive, true);
      vm.toggleSubscription('sub-1');
      expect(vm.enabledSubscriptions, isEmpty);
    });
  });

  group('regex', () {
    test('onRegexChanged компилирует + enable (debounced)', () async {
      vm.onRegexChanged('Moscow');
      await Future.delayed(const Duration(milliseconds: 350));
      expect(vm.regexEnabled, true);
      expect(vm.regexValid, true);
      expect(vm.activeRegex, isNotNull);
      expect(vm.activeRegex!.hasMatch('Moscow Node'), true);
      expect(vm.isActive, true);
    });

    test('invalid regex → valid=false, compiled=null', () async {
      vm.onRegexChanged('[invalid(');
      await Future.delayed(const Duration(milliseconds: 350));
      expect(vm.regexValid, false);
      expect(vm.activeRegex, isNull);
    });

    test('setRegexEnabled gate: compiled но disabled → activeRegex null', () async {
      vm.onRegexChanged('RU');
      await Future.delayed(const Duration(milliseconds: 350));
      expect(vm.activeRegex, isNotNull);
      vm.setRegexEnabled(false);
      expect(vm.activeRegex, isNull, reason: 'disabled gate');
    });

    test('clearRegex сбрасывает всё', () async {
      vm.onRegexChanged('X');
      await Future.delayed(const Duration(milliseconds: 350));
      vm.setRegexInvert(true);
      vm.clearRegex();
      expect(vm.regexController.text, '');
      expect(vm.regexEnabled, false);
      expect(vm.regexInvert, false);
      expect(vm.activeRegex, isNull);
    });

    test('onEmojiChipTap append OR-pattern', () async {
      vm.onEmojiChipTap('🇷🇺');
      expect(vm.regexController.text, '🇷🇺');
      vm.onEmojiChipTap('🇺🇸');
      expect(vm.regexController.text, '🇷🇺|🇺🇸');
    });
  });

  group('ping', () {
    test('onPingChanged parse + enable (debounced)', () async {
      vm.onPingChanged('200');
      await Future.delayed(const Duration(milliseconds: 350));
      expect(vm.pingEnabled, true);
      expect(vm.activeMaxPingMs, 200);
    });
    test('invalid / zero → null', () async {
      vm.onPingChanged('abc');
      await Future.delayed(const Duration(milliseconds: 350));
      expect(vm.activeMaxPingMs, isNull);
    });
    test('setPingEnabled gate', () async {
      vm.onPingChanged('100');
      await Future.delayed(const Duration(milliseconds: 350));
      expect(vm.activeMaxPingMs, 100);
      vm.setPingEnabled(false);
      expect(vm.activeMaxPingMs, isNull);
    });
    test('clearPing сбрасывает', () async {
      vm.onPingChanged('100');
      await Future.delayed(const Duration(milliseconds: 350));
      vm.clearPing();
      expect(vm.pingController.text, '');
      expect(vm.pingEnabled, false);
      expect(vm.activeMaxPingMs, isNull);
    });
  });

  group('per-channel memory (syncChannel)', () {
    test('фильтр канала A восстанавливается после A→B→A', () {
      // войти в канал A
      vm.syncChannel('A');
      vm.toggleProtocol('vless');
      vm.toggleSubscription('sub-1');
      // переключиться на B → A-фильтры сохранены, B чистый
      vm.syncChannel('B');
      expect(vm.enabledProtocols, isEmpty);
      expect(vm.enabledSubscriptions, isEmpty);
      // настроить B
      vm.toggleProtocol('trojan');
      // вернуться в A → восстановлено
      vm.syncChannel('A');
      expect(vm.enabledProtocols, {'vless'});
      expect(vm.enabledSubscriptions, {'sub-1'});
      // снова B → trojan
      vm.syncChannel('B');
      expect(vm.enabledProtocols, {'trojan'});
    });

    test('пустой канал не плодит запись + same-channel no-op', () {
      vm.syncChannel('A');
      final before = notifications;
      vm.syncChannel('A'); // no-op
      expect(notifications, before);
    });

    test('show-detour/show-non-matching глобальны (не per-channel)', () {
      vm.syncChannel('A');
      vm.setShowDetour(false);
      vm.syncChannel('B');
      // глобальный флаг не сбрасывается при смене канала
      expect(vm.showDetour, false);
    });
  });
}
