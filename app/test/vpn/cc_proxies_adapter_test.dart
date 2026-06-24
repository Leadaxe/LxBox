import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/clash_api_client.dart';
import 'package:lxbox/vpn/cc_channel.dart';
import 'package:lxbox/vpn/cc_proxies_adapter.dart';

/// §122 Фаза 1a — синтез Clash-`proxiesJson` из `CcGroup`-снапшота.
/// Главная цель теста: убедиться, что существующие `ClashApiClient`-хелперы
/// (источник истины для node-list / presenter) корректно читают синтезированную
/// форму — без этого главный экран не покажет группы/ноды.

CcGroup _group({
  required String tag,
  required String type,
  required String selected,
  required List<CcOutbound> items,
  bool selectable = true,
}) =>
    CcGroup(
      tag: tag,
      type: type,
      selectable: selectable,
      selected: selected,
      isExpand: false,
      items: items,
    );

CcOutbound _node(String tag, String type) => CcOutbound(
      tag: tag,
      type: type,
      urlTestDelay: 0,
      urlTestTime: 0,
    );

void main() {
  group('CcProxiesAdapter.fromGroups', () {
    // Реалистичный снапшот: один selector (vpn-1) + один urltest (✨auto),
    // ноды двух протоколов. Регистр type как у нативного getType() — lowercase.
    final groups = [
      _group(
        tag: 'vpn-1',
        type: 'selector', // нативный sing-box-тип (lowercase)
        selected: '🇫🇮 Финляндия',
        items: [
          _node('🇫🇮 Финляндия', 'vless'),
          _node('🇩🇪 Германия', 'trojan'),
          _node('✨auto', 'urltest'),
        ],
      ),
      _group(
        tag: '✨auto',
        type: 'urltest',
        selected: '🇩🇪 Германия',
        items: [
          _node('🇫🇮 Финляндия', 'vless'),
          _node('🇩🇪 Германия', 'trojan'),
        ],
      ),
    ];

    final proxies = CcProxiesAdapter.fromGroups(groups);

    test('обёрнут в {proxies: {...}}', () {
      expect(proxies['proxies'], isA<Map<String, dynamic>>());
    });

    test('selectorGroupTags видит selector-группу (нормализован к Selector)', () {
      final selectors = ClashApiClient.selectorGroupTags(proxies);
      expect(selectors, contains('vpn-1'));
      // urltest НЕ должен попасть в selector-dropdown.
      expect(selectors, isNot(contains('✨auto')));
    });

    test('proxyEntry отдаёт type/now/all для selector-группы', () {
      final e = ClashApiClient.proxyEntry(proxies, 'vpn-1');
      expect(e, isNotNull);
      expect(e!['type'], 'Selector');
      expect(e['now'], '🇫🇮 Финляндия');
      expect(e['all'], ['🇫🇮 Финляндия', '🇩🇪 Германия', '✨auto']);
    });

    test('urltestNow возвращает selected для urltest-группы', () {
      expect(ClashApiClient.urltestNow(proxies, '✨auto'), '🇩🇪 Германия');
      // selector-группа — НЕ urltest → null.
      expect(ClashApiClient.urltestNow(proxies, 'vpn-1'), isNull);
    });

    test('плоские ноды присутствуют со своим протокол-типом', () {
      final pmap = proxies['proxies'] as Map<String, dynamic>;
      expect(pmap['🇫🇮 Финляндия'], isNotNull);
      expect((pmap['🇫🇮 Финляндия'] as Map)['type'], 'vless');
      expect((pmap['🇩🇪 Германия'] as Map)['type'], 'trojan');
    });

    test('urltest-член группы (✨auto) сохраняет тип группы, а не перетёрт нодой',
        () {
      // ✨auto входит в vpn-1 как item (urltest), и сам — группа верхнего уровня.
      // Запись верхнего уровня (Selector/URLTest норм.) приоритетна над
      // putIfAbsent плоского члена — тип должен быть URLTest, не 'urltest'.
      final e = ClashApiClient.proxyEntry(proxies, '✨auto');
      expect(e!['type'], 'URLTest');
    });

    test('пустой снапшот → пустой proxies, хелперы не падают', () {
      final empty = CcProxiesAdapter.fromGroups(const []);
      expect((empty['proxies'] as Map), isEmpty);
      expect(ClashApiClient.selectorGroupTags(empty), isEmpty);
      expect(ClashApiClient.urltestNow(empty, 'x'), isNull);
      expect(ClashApiClient.proxyEntry(empty, 'x'), isNull);
    });
  });
}
