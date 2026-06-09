import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/home_state.dart';
import 'package:lxbox/screens/home/node_filter_view_model.dart';
import 'package:lxbox/screens/home/node_list_presenter.dart';

/// §096 — presenter-level тест detour pool-фильтра (бинарный) + контракт
/// «control-узлы НИКОГДА не отсеиваются pool'ом». Покрывает wiring
/// `splitNodes` → `ConfigNode.isDetour` / `isControlTag`, который unit-тест
/// `detourPoolPasses` (pure bool) не трогает (closes §096 review HIGH-finding).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A ходит через B → B = detour-таргет (isDetour); A/C — payload non-detour.
  // auto/direct — control (по proxiesJson.type). Z — отсутствует в configModel.
  final configRaw = jsonEncode({
    'outbounds': [
      {'tag': 'A', 'type': 'vless', 'detour': 'B'},
      {'tag': 'B', 'type': 'vless'},
      {'tag': 'C', 'type': 'trojan'},
      {'tag': 'auto', 'type': 'urltest'},
      {'tag': 'direct', 'type': 'direct'},
    ],
  });
  const proxiesJson = <String, dynamic>{
    'proxies': {
      'A': {'type': 'vless'},
      'B': {'type': 'vless'},
      'C': {'type': 'trojan'},
      'auto': {'type': 'urltest'},
      'direct': {'type': 'direct'},
    },
  };
  const tags = ['A', 'B', 'C', 'auto', 'direct', 'Z'];

  late NodeFilterViewModel filter;
  late NodeListPresenter presenter;
  late HomeState state;

  setUp(() {
    filter = NodeFilterViewModel();
    presenter = NodeListPresenter(
      controller: HomeController(),
      subController: SubscriptionController(),
      filter: filter,
    );
    state = HomeState(
      configRaw: configRaw,
      proxiesJson: proxiesJson,
      nodes: tags, // для computeListData (viewSortedNodes → sortedNodes)
    );
  });

  tearDown(() => filter.dispose());

  test('sanity: B — detour-таргет, A/C — нет, Z отсутствует', () {
    expect(state.configModel['B']!.isDetour, true);
    expect(state.configModel['A']!.isDetour, false);
    expect(state.configModel['C']!.isDetour, false);
    expect(state.configModel['Z'], isNull);
  });

  test('старт (фильтр выкл): показаны ВСЕ, включая detour B', () {
    expect(filter.detourEnabled, false);
    final (matching, nonMatching) = presenter.splitNodes(tags, state);
    // нет match-фильтра + detour выкл → весь pool в matching.
    expect(matching, containsAll(['A', 'B', 'C', 'auto', 'direct', 'Z']));
    expect(nonMatching, isEmpty);
  });

  test('checkbox on (! on): скрыть detour — B убран, остальное видно', () {
    filter.setDetourEnabled(true);
    final (matching, _) = presenter.splitNodes(tags, state);
    expect(matching, containsAll(['A', 'C', 'auto', 'direct', 'Z']));
    expect(matching, isNot(contains('B')), reason: 'detour B скрыт');
  });

  test('checkbox on + ! off: только detour — B + control, A/C/Z скрыты', () {
    filter.setDetourEnabled(true);
    filter.toggleDetourHide(); // hide → only-detour
    final (matching, _) = presenter.splitNodes(tags, state);
    expect(matching, contains('B'), reason: 'detour-нода видна');
    expect(matching, containsAll(['auto', 'direct']),
        reason: 'control-узлы не отсеиваются pool-ом');
    expect(matching, isNot(contains('A')));
    expect(matching, isNot(contains('C')));
    expect(matching, isNot(contains('Z')),
        reason: 'нет в configModel → non-detour (?? false) → скрыт в only-detour');
  });

  test('control-узлы видны во ВСЕХ detour-режимах (никогда не drop)', () {
    // фильтр выкл (показать всё)
    expect(presenter.splitNodes(tags, state).$1, containsAll(['auto', 'direct']));
    filter.setDetourEnabled(true); // скрыть detour
    expect(presenter.splitNodes(tags, state).$1, containsAll(['auto', 'direct']));
    filter.toggleDetourHide(); // только detour
    expect(presenter.splitNodes(tags, state).$1, containsAll(['auto', 'direct']));
  });

  test('computeListData (старт): displayList включает detour B', () {
    final data = presenter.computeListData(state);
    expect(data.displayList, contains('B'), reason: 'старт = показать всё');
    expect(data.matchingSet, containsAll(['auto', 'direct']));
  });
}
