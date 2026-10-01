import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/home_controller.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/home_state.dart';
import 'package:lxbox/screens/home/node_filter_view_model.dart';
import 'package:lxbox/screens/home/node_list_presenter.dart';
import 'package:lxbox/screens/home/widgets/node_list.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/subscription/auto_updater.dart';
import 'package:lxbox/widgets/node_row.dart';

/// §537 — две колонки списка узлов при ширине ≥ 600 dp (issue #134).
void main() {
  group('nodeListColumnCount — порог 599/600 dp', () {
    test('599 dp — одна колонка', () {
      expect(nodeListColumnCount(599, isManual: false), 1);
    });

    test('600 dp — две колонки (порог нестрогий)', () {
      expect(nodeListColumnCount(600, isManual: false), 2);
    });

    test('1280 dp — две колонки', () {
      expect(nodeListColumnCount(1280, isManual: false), 2);
    });

    test('§541 тумблер выключен — одна колонка на любой ширине', () {
      expect(
        nodeListColumnCount(1280, isManual: false, twoColumnsEnabled: false),
        1,
      );
      expect(nodeListColumnCount(1280, isManual: false), 2,
          reason: 'дефолт тумблера — включён');
    });

    test('ручная сортировка остаётся одноколоночной на любой ширине', () {
      expect(nodeListColumnCount(1280, isManual: true), 1);
      expect(nodeListColumnCount(600, isManual: true), 1);
    });
  });

  group('HomeNodeList — раскладка', () {
    late HomeController controller;
    late SubscriptionController subController;
    late NodeFilterViewModel filter;
    late NodeListPresenter presenter;
    final rowKeys = <String, GlobalKey>{};

    const tags = ['n1', 'n2', 'n3', 'n4', 'n5'];

    setUp(() {
      controller = HomeController();
      subController = SubscriptionController();
      filter = NodeFilterViewModel();
      presenter = NodeListPresenter(
        controller: controller,
        subController: subController,
        filter: filter,
      );
      rowKeys.clear();
    });

    tearDown(() => filter.dispose());

    Widget host({
      required double width,
      NodeSortMode sortMode = NodeSortMode.latencyAsc,
      List<String> nodes = tags,
    }) {
      final state = HomeState(
        configRaw: '{}',
        nodes: nodes,
        sortMode: sortMode,
      );
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            height: 800,
            child: Column(
              children: [
                HomeNodeList(
                  controller: controller,
                  subController: subController,
                  autoUpdater: AutoUpdater(subController),
                  filter: filter,
                  presenter: presenter,
                  state: state,
                  showEmptyGuide: false,
                  onRestoreFromBackup: () async {},
                  onTapToConnect: () {},
                  rowKeyFor: (tag) =>
                      rowKeys.putIfAbsent(tag, () => GlobalKey()),
                  onSelectServer: (_) {},
                  onViewPool: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
    }

    /// Узлы, отсортированные по позиции на экране: сверху вниз, слева направо.
    List<String> visualOrder(WidgetTester tester) {
      final rows = tester.widgetList<NodeRow>(find.byType(NodeRow)).toList();
      final placed = <(double, double, String)>[];
      for (final r in rows) {
        final finder = find.byWidget(r);
        final box = tester.getTopLeft(finder);
        placed.add((box.dy, box.dx, r.item.tag));
      }
      placed.sort((a, b) {
        final byY = a.$1.compareTo(b.$1);
        return byY != 0 ? byY : a.$2.compareTo(b.$2);
      });
      return placed.map((e) => e.$3).toList();
    }

    testWidgets('599 dp — одна колонка, все строки на своём Y', (tester) async {
      await tester.pumpWidget(host(width: 599));
      await tester.pump();

      final xs = tester
          .widgetList<NodeRow>(find.byType(NodeRow))
          .map((r) => tester.getTopLeft(find.byWidget(r)).dx)
          .toSet();
      expect(xs.length, 1, reason: 'одна колонка — один X у всех строк');
    });

    testWidgets('600 dp — две колонки, порядок построчный 1-2 / 3-4',
        (tester) async {
      await tester.pumpWidget(host(width: 600));
      await tester.pump();

      final rows = tester.widgetList<NodeRow>(find.byType(NodeRow)).toList();
      expect(rows.length, tags.length);

      final xs = rows
          .map((r) => tester.getTopLeft(find.byWidget(r)).dx)
          .toSet()
          .toList()
        ..sort();
      expect(xs.length, 2, reason: 'две колонки — ровно два X');

      // Колонки равной ширины: вторая начинается ровно на половине.
      expect(xs[1] - xs[0], closeTo(300, 1));

      // Порядок построчный: визуальный порядок == порядок displayList.
      expect(visualOrder(tester), tags);
    });

    List<double> columnXs(WidgetTester tester) => tester
        .widgetList<NodeRow>(find.byType(NodeRow))
        .map((r) => tester.getTopLeft(find.byWidget(r)).dx)
        .toSet()
        .toList();

    testWidgets('§541 1280 dp, тумблер по умолчанию — две колонки',
        (tester) async {
      expect(SettingsStorage.nodeListTwoColumns.value, isTrue);
      await tester.pumpWidget(host(width: 1280));
      await tester.pump();
      expect(columnXs(tester).length, 2);
    });

    testWidgets('§541 1280 dp, тумблер выключен — одна колонка, включение на лету',
        (tester) async {
      addTearDown(() => SettingsStorage.nodeListTwoColumns.value = true);
      SettingsStorage.nodeListTwoColumns.value = false;
      await tester.pumpWidget(host(width: 1280));
      await tester.pump();
      expect(columnXs(tester).length, 1,
          reason: 'тумблер выключен — одна колонка');

      SettingsStorage.nodeListTwoColumns.value = true;
      await tester.pump();
      expect(columnXs(tester).length, 2,
          reason: 'смена тумблера применяется без перезапуска');
    });

    testWidgets('1280 dp + ручная сортировка — одна колонка', (tester) async {
      await tester.pumpWidget(
        host(width: 1280, sortMode: NodeSortMode.manual),
      );
      await tester.pump();

      final xs = tester
          .widgetList<NodeRow>(find.byType(NodeRow))
          .map((r) => tester.getTopLeft(find.byWidget(r)).dx)
          .toSet();
      expect(xs.length, 1, reason: 'manual — drag-and-drop, только одна колонка');
    });

    testWidgets('сужение окна на лету возвращает одну колонку', (tester) async {
      await tester.pumpWidget(host(width: 900));
      await tester.pump();
      expect(
        tester
            .widgetList<NodeRow>(find.byType(NodeRow))
            .map((r) => tester.getTopLeft(find.byWidget(r)).dx)
            .toSet()
            .length,
        2,
      );

      await tester.pumpWidget(host(width: 420));
      await tester.pump();
      expect(
        tester
            .widgetList<NodeRow>(find.byType(NodeRow))
            .map((r) => tester.getTopLeft(find.byWidget(r)).dx)
            .toSet()
            .length,
        1,
      );
    });

    testWidgets('смена колонок на лету не сбрасывает скролл', (tester) async {
      final many = [for (var i = 0; i < 60; i++) 'n$i'];
      await tester.pumpWidget(host(width: 420, nodes: many));
      await tester.pump();

      final list = find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      );
      await tester.drag(list.first, const Offset(0, -900));
      await tester.pumpAndSettle();
      final viewport = tester.getRect(list.first);
      // Первый (верхний) узел во вьюпорте.
      String topVisibleTag() {
        final rows = tester
            .widgetList<NodeRow>(find.byType(NodeRow))
            .where((r) => tester.getBottomLeft(find.byWidget(r)).dy >
                viewport.top + 1)
            .toList()
          ..sort((a, b) => tester
              .getTopLeft(find.byWidget(a))
              .dy
              .compareTo(tester.getTopLeft(find.byWidget(b)).dy));
        return rows.first.item.tag;
      }

      bool isOnScreen(String tag) {
        final f = find.byWidgetPredicate(
          (w) => w is NodeRow && w.item.tag == tag,
        );
        if (f.evaluate().isEmpty) return false;
        final r = tester.getRect(f);
        return r.bottom > viewport.top && r.top < viewport.bottom;
      }

      final anchor = topVisibleTag();
      expect(anchor, isNot(many.first), reason: 'список прокручен');

      await tester.pumpWidget(host(width: 900, nodes: many));
      await tester.pump();
      expect(isOnScreen(anchor), isTrue,
          reason: 'после перехода в две колонки узел остаётся на экране');

      await tester.pumpWidget(host(width: 420, nodes: many));
      await tester.pump();
      expect(isOnScreen(anchor), isTrue,
          reason: 'и после возврата в одну колонку');
    });
  });
}
