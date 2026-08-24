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
      expect(vm.showNonMatching, true);
      // §096 — detour: старт = фильтр выкл → показать всё (точку не зажигает).
      expect(vm.detourEnabled, false);
      expect(vm.detourHide, true); // `!` дефолт on, но фильтр выкл → неважен
      expect(vm.detourActive, false);
      expect(vm.detourOnly, false);
      expect(vm.panelExpanded, false);
      expect(vm.regexInvert, false);
      expect(vm.regexValid, true);
      expect(vm.activeRegex, isNull);
      expect(vm.enabledProtocols, isEmpty);
      expect(vm.protocolsInvert, false);
      expect(vm.enabledSubscriptions, isEmpty);
      expect(vm.subscriptionsInvert, false);
      expect(vm.pingEnabled, false);
      // §095 — поле предзаполнено реальным «200», но disabled → не активно.
      expect(vm.pingController.text, '200');
      expect(vm.activeMaxPingMs, isNull);
      expect(vm.isActive, false);
      expect(vm.hasActiveFilters, false);
    });
  });

  group('toggles notify', () {
    test('togglePanel', () {
      vm.togglePanel();
      expect(vm.panelExpanded, true);
      expect(notifications, 1);
    });
    test('setDetourEnabled / setShowNonMatching', () {
      vm.setDetourEnabled(true);
      vm.setShowNonMatching(false);
      expect(vm.detourEnabled, true);
      expect(vm.detourActive, true);
      expect(vm.showNonMatching, false);
      expect(vm.nonMatchingHidden, true);
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
    test('§096 toggleProtocolsInvert / toggleSubscriptionsInvert', () {
      vm.toggleProtocolsInvert();
      expect(vm.protocolsInvert, true);
      vm.toggleSubscriptionsInvert();
      expect(vm.subscriptionsInvert, true);
      vm.toggleProtocolsInvert();
      expect(vm.protocolsInvert, false);
      expect(notifications, 3);
    });
  });

  group('detour (§096 — чекбокс-enable + !)', () {
    test('старт — фильтр выкл → показать всё', () {
      expect(vm.detourEnabled, false);
      expect(vm.detourActive, false);
      expect(vm.detourOnly, false);
      expect(vm.detourPoolPasses(true), true, reason: 'detour показан');
      expect(vm.detourPoolPasses(false), true, reason: 'non-detour показан');
      expect(vm.settingsActive, false);
      expect(vm.hasActiveFilters, false);
    });
    test('checkbox on (! on, дефолт) → скрыть detour', () {
      vm.setDetourEnabled(true);
      expect(vm.detourActive, true);
      expect(vm.detourOnly, false);
      expect(vm.detourPoolPasses(true), false, reason: 'detour скрыт');
      expect(vm.detourPoolPasses(false), true, reason: 'non-detour виден');
      expect(vm.settingsActive, true);
      expect(vm.hasActiveFilters, true);
    });
    test('checkbox on + ! off → только detour', () {
      vm.setDetourEnabled(true);
      vm.toggleDetourHide();
      expect(vm.detourOnly, true);
      expect(vm.detourPoolPasses(true), true, reason: 'detour виден');
      expect(vm.detourPoolPasses(false), false, reason: 'non-detour отсеян');
    });
    test('checkbox off → ! неважен, всё проходит', () {
      vm.toggleDetourHide(); // hide=false, но фильтр выкл
      expect(vm.detourEnabled, false);
      expect(vm.detourPoolPasses(true), true);
      expect(vm.detourPoolPasses(false), true);
      expect(vm.detourActive, false);
    });
  });

  group('regex', () {
    test('onRegexChanged компилирует (debounced)', () async {
      vm.onRegexChanged('Moscow');
      await Future.delayed(const Duration(milliseconds: 350));
      expect(vm.regexValid, true);
      expect(vm.activeRegex, isNotNull);
      expect(vm.activeRegex!.hasMatch('Moscow Node'), true);
      expect(vm.regexActive, true);
      expect(vm.isActive, true);
    });

    test('invalid regex → valid=false, compiled=null', () async {
      vm.onRegexChanged('[invalid(');
      await Future.delayed(const Duration(milliseconds: 350));
      expect(vm.regexValid, false);
      expect(vm.activeRegex, isNull);
      expect(vm.regexActive, false);
    });

    test('§096 toggleRegexInvert не выключает regex', () async {
      vm.onRegexChanged('RU');
      await Future.delayed(const Duration(milliseconds: 350));
      expect(vm.regexInvert, false);
      vm.toggleRegexInvert();
      expect(vm.regexInvert, true);
      expect(vm.activeRegex, isNotNull, reason: 'invert ≠ disable');
      vm.toggleRegexInvert();
      expect(vm.regexInvert, false);
    });

    test('clearRegex сбрасывает всё', () async {
      vm.onRegexChanged('X');
      await Future.delayed(const Duration(milliseconds: 350));
      vm.toggleRegexInvert();
      vm.clearRegex();
      expect(vm.regexController.text, '');
      expect(vm.regexInvert, false);
      expect(vm.activeRegex, isNull);
      expect(vm.regexActive, false);
    });

    test('onEmojiChipTap append OR-pattern', () async {
      vm.onEmojiChipTap('🇷🇺');
      expect(vm.regexController.text, '🇷🇺');
      vm.onEmojiChipTap('🇺🇸');
      expect(vm.regexController.text, '🇷🇺|🇺🇸');
    });
  });

  group('ping', () {
    test('§095 дефолт 200 disabled → не активен; чекбокс включает на 200', () {
      expect(vm.pingController.text, '200');
      expect(vm.pingEnabled, false);
      expect(vm.activeMaxPingMs, isNull, reason: 'disabled by default');
      vm.setPingEnabled(true);
      expect(vm.activeMaxPingMs, 200, reason: 'значение уже было 200');
    });
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

  group('per-direction memory (syncDirection)', () {
    test('фильтр Направления A восстанавливается после A→B→A', () {
      // войти в Направление A
      vm.syncDirection('A');
      vm.toggleProtocol('vless');
      vm.toggleSubscription('sub-1');
      // переключиться на B → A-фильтры сохранены, B чистый
      vm.syncDirection('B');
      expect(vm.enabledProtocols, isEmpty);
      expect(vm.enabledSubscriptions, isEmpty);
      // настроить B
      vm.toggleProtocol('trojan');
      // вернуться в A → восстановлено
      vm.syncDirection('A');
      expect(vm.enabledProtocols, {'vless'});
      expect(vm.enabledSubscriptions, {'sub-1'});
      // снова B → trojan
      vm.syncDirection('B');
      expect(vm.enabledProtocols, {'trojan'});
    });

    test('пустое Направление не плодит запись + same-direction no-op', () {
      vm.syncDirection('A');
      final before = notifications;
      vm.syncDirection('A'); // no-op
      expect(notifications, before);
    });

    test('§095 дефолтный ping (200, disabled) переживает смену Направления', () {
      vm.syncDirection('A');
      expect(vm.pingController.text, '200');
      vm.syncDirection('B'); // capture A нормализует дефолт → '' (no orphan)
      expect(vm.pingController.text, '200');
      vm.syncDirection('A'); // restore A → пусто → дефолтное «200»
      expect(vm.pingController.text, '200');
      expect(vm.pingEnabled, false);
    });

    test('detour/show-non-matching глобальны (не per-direction)', () {
      vm.syncDirection('A');
      vm.setDetourEnabled(true); // → скрыть detour
      vm.syncDirection('B');
      // глобальный флаг не сбрасывается при смене Направления
      expect(vm.detourEnabled, true);
      expect(vm.detourActive, true);
    });

    test('§096 protocol/subscription invert — per-direction', () {
      vm.syncDirection('A');
      vm.toggleProtocol('vless');
      vm.toggleProtocolsInvert();
      vm.toggleSubscriptionsInvert();
      vm.syncDirection('B');
      expect(vm.protocolsInvert, false, reason: 'B чистый');
      expect(vm.subscriptionsInvert, false);
      vm.syncDirection('A');
      expect(vm.protocolsInvert, true, reason: 'A восстановлен');
      expect(vm.subscriptionsInvert, true);
      expect(vm.enabledProtocols, {'vless'});
    });

    test('§103 variants (+invert) — per-direction', () {
      vm.syncDirection('A');
      vm.toggleVariant('xhttp');
      vm.toggleVariant('Reality');
      vm.toggleVariantsInvert();
      expect(vm.variantActive, true);
      expect(vm.isActive, true);
      vm.syncDirection('B');
      expect(vm.enabledVariants, isEmpty, reason: 'B чистый');
      expect(vm.variantsInvert, false);
      expect(vm.variantActive, false);
      vm.syncDirection('A');
      expect(vm.enabledVariants, {'xhttp', 'Reality'},
          reason: 'A восстановлен');
      expect(vm.variantsInvert, true);
    });

    test('§103 toggleVariant — add/remove симметричен', () {
      vm.toggleVariant('tcp');
      expect(vm.enabledVariants, {'tcp'});
      vm.toggleVariant('tcp');
      expect(vm.enabledVariants, isEmpty);
      expect(vm.variantActive, false);
    });
  });
}
