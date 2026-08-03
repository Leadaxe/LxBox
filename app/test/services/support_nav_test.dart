import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/support/support_nav.dart';

/// §357 — парсер `lxbox://action:payload` и резолвабельность действий.
void main() {
  group('SupportLinkAction.parse', () {
    test('route: экран и экран/вкладка', () {
      final a = SupportLinkAction.parse('lxbox://route:dns')!;
      expect(a.action, 'route');
      expect(a.payload, 'dns');
      expect(routeSegments(a), ['dns']);

      final b = SupportLinkAction.parse('lxbox://route:debug/profiling')!;
      expect(routeSegments(b), ['debug', 'profiling']);
    });

    test('payload — целый URI со своим ://, query и фрагментом', () {
      const uri =
          'vless://uuid@154.83.246.52:443?flow=xtls-rprx-vision&sni=x#%F0%9F%87%B3%F0%9F%87%B1';
      final a = SupportLinkAction.parse('lxbox://add:$uri')!;
      expect(a.action, 'add');
      expect(a.payload, uri, reason: 'всё после первого ":" — сырой payload');
    });

    test('не-lxbox и битые → null', () {
      expect(SupportLinkAction.parse('https://github.com/x'), isNull);
      expect(SupportLinkAction.parse('lxbox://route'), isNull,
          reason: 'нет разделителя действия');
      expect(SupportLinkAction.parse('lxbox://route:'), isNull,
          reason: 'пустой payload');
      expect(SupportLinkAction.parse('lxbox://:dns'), isNull,
          reason: 'пустое действие');
      expect(SupportLinkAction.parse(''), isNull);
    });
  });

  group('isResolvableSupportAction', () {
    test('route: все экраны реестра резолвятся', () {
      for (final s in kSupportRouteScreens) {
        expect(
            isResolvableSupportAction(SupportLinkAction.parse('lxbox://route:$s')!),
            true,
            reason: s);
      }
    });

    test('route: неизвестный экран / add: пустой / чужое действие → false', () {
      expect(
          isResolvableSupportAction(
              SupportLinkAction.parse('lxbox://route:teleport')!),
          false);
      expect(
          isResolvableSupportAction(SupportLinkAction.parse('lxbox://add: ')!),
          false);
      expect(
          isResolvableSupportAction(
              SupportLinkAction.parse('lxbox://teleport:mars')!),
          false,
          reason: 'forward-compat: будущие действия старые версии прячут');
    });

    test('route: вкладка не влияет на резолвабельность', () {
      expect(
          isResolvableSupportAction(
              SupportLinkAction.parse('lxbox://route:debug/whatever')!),
          true,
          reason: 'неизвестная вкладка деградирует к дефолтной на экране');
    });
  });
}
