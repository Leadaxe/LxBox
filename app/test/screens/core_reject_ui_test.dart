import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/core_reject_verdict.dart';
import 'package:lxbox/models/home_state.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/home/core_reject_ui.dart';
import 'package:lxbox/screens/home/widgets/app_banner.dart';
import 'package:lxbox/screens/subscription_detail_screen/node_inspect_screen.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_notifications_view.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/core_reject/core_reject_guard.dart';
import 'package:lxbox/services/core_reject/core_reject_state.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';

/// Фича 478 — рендер того, что человек видит: плашка «N servers disabled»
/// (кнопка Show открывает список выключенных) и диалог предела кругов
/// (Stop / Keep checking).
///
/// Рендером, а не проекцией: проекцию `activeBanners` закрывает
/// `app_banner_test.dart`, а здесь вопрос другой — доходят ли тексты и
/// действия до экрана. Реестр грузится из `assets/contract` (зеркало в git,
/// едет в APK): шторка узла резолвит `core_rejected` по нему.
///
/// Последняя группа — отмена цикла: кнопку Start отдельно не пумпаем (ей
/// нужны живые контроллеры главного экрана), проверяется связка, в которую
/// она упирается.
const _registryRoot = 'assets/contract';

void main() {
  setUpAll(() async {
    await ContractRegistry.I.loadFromDirectory(_registryRoot);
  });

  tearDown(() {
    LocaleController.I.setting = 'system';
  });

  tearDownAll(ContractRegistry.I.resetForTesting);

  const one = DisabledNode(tag: 'Frankfurt', reason: 'parse encryption: bad');
  const three = [
    DisabledNode(tag: 'Frankfurt', reason: 'parse encryption: bad'),
    DisabledNode(tag: 'Berlin', reason: 'unknown method: rc4-md5'),
    DisabledNode(tag: 'Praha', reason: 'bad key'),
  ];

  VlessSpec inspectNode({String tag = 'Frankfurt'}) => VlessSpec(
        id: tag,
        tag: tag,
        label: tag,
        server: 'example.com',
        port: 443,
        rawSource: '',
        uuid: '00000000-0000-0000-0000-000000000000',
        warnings: [
          StoredWarning.coreRejected('parse encryption: bad').toWarning(),
        ],
      );

  SubscriptionController subWithNode(VlessSpec node,
      {required String emittedTag}) {
    final sub = SubscriptionController();
    sub.debugSetEntries([
      SubscriptionEntry(
        list: SubscriptionServers(
          id: 'sub-1',
          name: 'sub',
          enabled: true,
          tagPrefix: '',
          detourPolicy: DetourPolicy.defaults,
          url: 'https://example.com/sub',
          nodes: [node],
        ),
      ),
    ]);
    sub.debugSetLastEmittedTagMap({emittedTag: node});
    return sub;
  }

  group('плашка «N servers disabled»', () {
    /// Плашка в том же дереве, что на главном экране: проекция
    /// `activeBanners` → `BannerStack`.
    Future<void> pumpBanner(
      WidgetTester tester,
      List<DisabledNode> nodes, {
      SubscriptionController? subController,
      VoidCallback? onShow,
      VoidCallback? onDismiss,
    }) {
      final sub = subController ?? SubscriptionController();
      return tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => BannerStack(
              banners: activeBanners(
                HomeState(),
                configDirty: false,
                busy: false,
                coreRejected: nodes,
                actions: BannerActions(
                  onRebuild: () {},
                  onConfirmStop: () {},
                  onClearError: () {},
                  onShareCrash: () {},
                  onDismissCrash: () {},
                  onShowCoreRejected: onShow ??
                      () => showCoreRejectList(ctx, nodes,
                          subController: sub),
                  onDismissCoreRejected: onDismiss ?? () {},
                ),
              ),
            ),
          ),
        ),
      ));
    }

    testWidgets('число выключенных первым словом, имена в тексте, кнопка Show',
        (tester) async {
      await pumpBanner(tester, three);

      expect(find.text('3 servers disabled'), findsOneWidget);
      expect(find.textContaining('Frankfurt, Berlin, Praha'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Show'), findsOneWidget);
    });

    testWidgets('один узел — «1 server disabled», текст «it», без хвоста',
        (tester) async {
      await pumpBanner(tester, const [one]);

      expect(find.text('1 server disabled'), findsOneWidget);
      expect(find.textContaining('The core rejected it'), findsOneWidget);
      expect(find.textContaining('Frankfurt'), findsOneWidget);
      expect(find.textContaining('more'), findsNothing,
          reason: 'хвост «+N more» появляется только после трёх имён');
    });

    testWidgets('больше трёх имён — хвост «+N more»', (tester) async {
      await pumpBanner(tester, const [
        ...three,
        DisabledNode(tag: 'Wien', reason: 'bad'),
        DisabledNode(tag: 'Riga', reason: 'bad'),
      ]);

      expect(find.textContaining('Frankfurt, Berlin, Praha +2 more'),
          findsOneWidget);
      expect(find.textContaining('Wien'), findsNothing);
    });

    testWidgets('Show открывает список выключенных', (tester) async {
      await pumpBanner(tester, three);
      await tester.tap(find.widgetWithText(TextButton, 'Show'));
      await tester.pumpAndSettle();

      // Шторка: заголовок тот же, что у плашки, плюс строка на каждый узел
      // с дословным текстом ядра.
      expect(find.text('3 servers disabled'), findsNWidgets(2));
      expect(find.widgetWithText(ListTile, 'Frankfurt'), findsOneWidget);
      expect(find.text('parse encryption: bad'), findsOneWidget);
    });

    testWidgets('крестик зовёт dismiss — закрывается сообщение, не решение',
        (tester) async {
      var dismissed = 0;
      await pumpBanner(tester, three, onDismiss: () => dismissed++);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(dismissed, 1);
    });
  });

  group('диалог предела кругов', () {
    /// Открывает диалог; ответ дописывается в [into], когда человек ответил.
    Future<void> pumpPrompt(
      WidgetTester tester,
      List<CoreRejectPrompt> into,
    ) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async =>
                  into.add(await showCoreRejectPrompt(ctx, 10)),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('тексты владельца: заголовок, вопрос и цена остановки',
        (tester) async {
      await pumpPrompt(tester, []);

      expect(find.text('10 servers disabled — there may be more'),
          findsOneWidget);
      expect(find.textContaining('Keep checking the rest?'), findsOneWidget);
      expect(find.textContaining('the VPN will not start'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Stop checking'), findsOneWidget);
      expect(
          find.widgetWithText(FilledButton, 'Keep checking'), findsOneWidget);
    });

    testWidgets('Stop checking → stop, диалог закрыт', (tester) async {
      final answers = <CoreRejectPrompt>[];
      await pumpPrompt(tester, answers);
      await tester.tap(find.widgetWithText(TextButton, 'Stop checking'));
      await tester.pumpAndSettle();

      expect(answers, [CoreRejectPrompt.stop]);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('Keep checking → keepChecking', (tester) async {
      final answers = <CoreRejectPrompt>[];
      await pumpPrompt(tester, answers);
      await tester.tap(find.widgetWithText(FilledButton, 'Keep checking'));
      await tester.pumpAndSettle();

      expect(answers, [CoreRejectPrompt.keepChecking]);
    });

    testWidgets('закрытие мимо кнопок читается как Stop', (tester) async {
      final answers = <CoreRejectPrompt>[];
      await pumpPrompt(tester, answers);
      // Тап по барьеру — то же, что системная «назад»: молчание не согласие
      // на долгую проверку.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(answers, [CoreRejectPrompt.stop]);
    });
  });

  // Отмена: кнопка Start в фазе цикла рисуется по `checking` и зовёт
  // `cancelRun()`. Рендер самой кнопки требует живых контроллеров главного
  // экрана, поэтому здесь проверяется то, во что она упирается — связка
  // состояния с автоматом.
  group('отмена прогона', () {
    setUp(CoreRejectState.I.resetForTest);
    tearDown(CoreRejectState.I.resetForTest);

    test('кнопка видна по фазе цикла, а не по наличию связки', () {
      final s = CoreRejectState.I;
      expect(s.checking, false);
      s.onProgress(CoreRejectPhase.checking, 1);
      expect(s.checking, true);
      s.onProgress(CoreRejectPhase.awaitingPrompt, 1);
      expect(s.checking, true, reason: 'висящий вопрос — часть цикла');
      s.onProgress(CoreRejectPhase.finalStart, 1);
      expect(s.checking, false);
    });

    test('cancelRun зовёт cancel автомата; без прогона — false', () {
      final s = CoreRejectState.I;
      expect(s.cancelRun(), false, reason: 'отменять нечего');

      var cancels = 0;
      s.bindCancel(() => cancels++);
      expect(s.cancelRun(), true);
      expect(cancels, 1);
    });

    test('отмена поверх висящего вопроса отвечает за человека Stop', () async {
      final s = CoreRejectState.I;
      s.bindCancel(() {});
      final pending = s.askPrompt(10);
      expect(s.promptPending, true);

      s.cancelRun();
      expect(s.promptPending, false);
      expect(await pending, CoreRejectPrompt.stop);
    });

    test('finish рвёт связку — завершённый прогон не отменяют', () {
      final s = CoreRejectState.I;
      s.bindCancel(() {});
      s.finish(const CoreRejectRun(outcome: CoreRejectOutcome.stoppedByUser));
      expect(s.cancellable, false);
      expect(s.cancelRun(), false);
    });

    test('beginRun скрывает плашку прошлого прогона', () {
      final s = CoreRejectState.I;
      s.finish(const CoreRejectRun(
        outcome: CoreRejectOutcome.startedWithDisabled,
        disabled: [DisabledNode(tag: 'n1', reason: 'bad')],
      ));
      expect(s.bannerVisible, isTrue);
      s.beginRun();
      expect(s.bannerVisible, isFalse);
    });
  });

  group('§498 — лист выключенных', () {
    test('заголовок: 1 server disabled / 2 servers disabled', () {
      expect(coreRejectBannerTitle(1), '1 server disabled');
      expect(coreRejectBannerTitle(2), '2 servers disabled');
    });

    Future<void> pumpList(
      WidgetTester tester,
      List<DisabledNode> nodes,
      SubscriptionController sub,
    ) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showCoreRejectList(ctx, nodes,
                  subController: sub),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('тап по строке открывает детали на вкладке Diagnostics',
        (tester) async {
      final node = inspectNode();
      final sub = subWithNode(node, emittedTag: 'Frankfurt');
      await pumpList(tester, const [one], sub);

      await tester.tap(find.widgetWithText(ListTile, 'Frankfurt'));
      await tester.pumpAndSettle();

      expect(find.byType(NodeInspectScreen), findsOneWidget);
      expect(find.byType(NodeNotificationsView), findsOneWidget);
      expect(find.text('The core rejected this server'), findsOneWidget);
    });

    testWidgets('удалённый узел — строка неактивна, без шеврона', (tester) async {
      final sub = SubscriptionController();
      await pumpList(tester, const [one], sub);

      final tile =
          tester.widget<ListTile>(find.widgetWithText(ListTile, 'Frankfurt'));
      expect(tile.enabled, isFalse);
      expect(tile.trailing, isNull);
    });

    testWidgets('заголовок листа: 1 и 2', (tester) async {
      final sub = SubscriptionController();
      await pumpList(tester, const [one], sub);
      expect(find.text('1 server disabled'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await pumpList(
        tester,
        const [
          one,
          DisabledNode(tag: 'Berlin', reason: 'bad'),
        ],
        sub,
      );
      expect(find.text('2 servers disabled'), findsOneWidget);
    });

    testWidgets('хоп цепочки открывает владельца на Diagnostics',
        (tester) async {
      final hop = inspectNode(tag: 'hop-link');
      final owner = withChained(inspectNode(tag: 'Main'), hop);
      final sub = SubscriptionController();
      sub.debugSetEntries([
        SubscriptionEntry(
          list: SubscriptionServers(
            id: 'sub-1',
            name: 'sub',
            enabled: true,
            tagPrefix: '',
            detourPolicy: DetourPolicy.defaults,
            url: 'https://example.com/sub',
            nodes: [owner],
          ),
        ),
      ]);
      sub.debugSetLastEmittedTagMap({'hop-link': hop});
      await pumpList(
        tester,
        const [DisabledNode(tag: 'hop-link', reason: 'parse encryption: bad')],
        sub,
      );

      await tester.tap(find.widgetWithText(ListTile, 'hop-link'));
      await tester.pumpAndSettle();

      expect(find.byType(NodeInspectScreen), findsOneWidget);
      final screen =
          tester.widget<NodeInspectScreen>(find.byType(NodeInspectScreen));
      expect(screen.node.tag, 'Main');
      expect(find.byType(NodeNotificationsView), findsOneWidget);
    });
  });
}
