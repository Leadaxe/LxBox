import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/home_state.dart';
import 'package:lxbox/screens/home/core_reject_ui.dart';
import 'package:lxbox/screens/home/widgets/app_banner.dart';
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

  const one = DisabledNode(tag: 'Frankfurt', reason: 'parse encryption: bad');
  const three = [
    DisabledNode(tag: 'Frankfurt', reason: 'parse encryption: bad'),
    DisabledNode(tag: 'Berlin', reason: 'unknown method: rc4-md5'),
    DisabledNode(tag: 'Praha', reason: 'bad key'),
  ];

  group('плашка «N servers disabled»', () {
    /// Плашка в том же дереве, что на главном экране: проекция
    /// `activeBanners` → `BannerStack`.
    Future<void> pumpBanner(
      WidgetTester tester,
      List<DisabledNode> nodes, {
      VoidCallback? onShow,
      VoidCallback? onDismiss,
    }) =>
        tester.pumpWidget(MaterialApp(
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
                    onShowCoreRejected:
                        onShow ?? () => showCoreRejectList(ctx, nodes),
                    onDismissCoreRejected: onDismiss ?? () {},
                  ),
                ),
              ),
            ),
          ),
        ));

    testWidgets('число выключенных первым словом, имена в тексте, кнопка Show',
        (tester) async {
      await pumpBanner(tester, three);

      expect(find.text('3 servers disabled'), findsOneWidget);
      expect(find.textContaining('Frankfurt, Berlin, Praha'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Show'), findsOneWidget);
    });

    testWidgets('один узел — текст «it», хвоста «+N more» нет', (tester) async {
      await pumpBanner(tester, const [one]);

      // Без словаря plural отдаёт английский ключ как есть — у EN отдельных
      // форм нет by design (`get_local_text.dart`), и проверять здесь надо
      // не форму числа, а что имя одного узла дошло целиком и без хвоста.
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
  });
}
