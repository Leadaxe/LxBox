import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warning_row.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warnings_sheet.dart';
import 'package:lxbox/services/contract/contract_docs.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/widgets/banner_palette.dart';

/// §460 W2b — карточка предупреждений узла (раздел 8.2 спеки).
///
/// Реестр грузится из `assets/contract` — зеркала в git: оно едет в APK, и
/// проверять карточку имеет смысл ровно по тем текстам, которые увидит
/// пользователь. Копии контракта (`contract/`, gitignored) тесты здесь не
/// касаются.
const _registryRoot = 'assets/contract';

void main() {
  setUpAll(() async {
    await ContractRegistry.I.loadFromDirectory(_registryRoot);
  });

  tearDown(() {
    LocaleController.I.setting = 'system';
  });

  Future<void> pumpSheet(WidgetTester tester, List<NodeWarning> warnings) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(body: NodeWarningsSheet(warnings)),
      ));

  /// Строка под узлом в дереве, близком к боевому: она живёт в `subtitle`
  /// ListTile'а, у которого свой onTap — проверяем, что шторку открывает
  /// именно она, а не он.
  Future<void> pumpRow(WidgetTester tester, List<NodeWarning> warnings,
          {VoidCallback? onTileTap,
          bool compact = false,
          ThemeData? theme}) =>
      tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
          body: ListTile(
            title: const Text('node'),
            subtitle: NodeWarningRow(warnings, compact: compact),
            onTap: onTileTap ?? () {},
          ),
        ),
      ));

  group('строка предупреждений открывает шторку', () {
    testWidgets('тап по строке → лист со всеми предупреждениями',
        (tester) async {
      await pumpRow(tester, const [
        InsecureTlsWarning(),
        SectionsConflictWarning(),
      ]);
      expect(find.text('Warnings'), findsNothing);

      await tester.tap(find.byType(NodeWarningRow));
      await tester.pumpAndSettle();

      expect(find.text('Warnings'), findsOneWidget);
      // Оба предупреждения, а не только первое: строка под узлом показывала
      // одно и «+1 more». Ищем внутри шторки — строка под ней осталась на
      // месте и своё предупреждение тоже показывает.
      final inSheet = find.descendant(
        of: find.byType(NodeWarningsSheet),
        matching: find.textContaining('The document carries both'),
      );
      expect(inSheet, findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(NodeWarningsSheet),
          matching: find.text('TLS certificate verification is disabled.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('тап по строке не срабатывает как тап по строке узла',
        (tester) async {
      var tileTaps = 0;
      await pumpRow(tester, const [InsecureTlsWarning()],
          onTileTap: () => tileTaps++);

      await tester.tap(find.byType(NodeWarningRow));
      await tester.pumpAndSettle();

      expect(tileTaps, 0, reason: 'тап провалился на ListTile под строкой');
      expect(find.text('Warnings'), findsOneWidget);
    });

    testWidgets('строка объявлена кнопкой для screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpRow(tester, const [InsecureTlsWarning()]);
      expect(
        tester.getSemantics(find.byType(NodeWarningRow)),
        matchesSemantics(
          isButton: true,
          hasTapAction: true,
          label: 'TLS certificate verification is disabled.',
        ),
      );
      handle.dispose();
    });
  });

  group('§471 — уровни в строке под узлом', () {
    const infoW = InsecureTlsWarning(); // info
    const warnW = UnsupportedTransportWarning('quic', 'ws'); // warning
    const errW = MissingFieldWarning('sni'); // error

    Iterable<Icon> icons(WidgetTester tester) => tester
        .widgetList<Icon>(find.descendant(
            of: find.byType(NodeWarningRow), matching: find.byType(Icon)));

    testWidgets('только info в компактном режиме — значок без текста, тап '
        'открывает шторку', (tester) async {
      await pumpRow(tester, const [infoW], compact: true);

      // Текста нет вовсе: строка схлопнута до значка.
      expect(find.descendant(
              of: find.byType(NodeWarningRow), matching: find.byType(Text)),
          findsNothing);
      final ico = icons(tester).toList();
      expect(ico, hasLength(1));
      expect(ico.single.icon, Icons.info_outline);

      await tester.tap(find.byType(NodeWarningRow));
      await tester.pumpAndSettle();
      expect(find.text('Warnings'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(NodeWarningsSheet),
          matching: find.text('TLS certificate verification is disabled.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('значок info без текста читается скринридером', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpRow(tester, const [infoW], compact: true);
      expect(
        tester.getSemantics(find.byType(NodeWarningRow)),
        matchesSemantics(
          isButton: true,
          hasTapAction: true,
          label: 'TLS certificate verification is disabled.',
        ),
      );
      handle.dispose();
    });

    testWidgets('warning + info — текст warning, «+N more» без info, синий '
        'значок в конце', (tester) async {
      await pumpRow(tester, const [infoW, warnW], compact: true);

      // Текст — warning'а и без счётчика: actionable ровно одно.
      expect(find.textContaining('is not supported by sing-box'),
          findsOneWidget);
      expect(find.textContaining('+1 more'), findsNothing);
      expect(
          find.descendant(
              of: find.byType(NodeWarningRow),
              matching:
                  find.text('TLS certificate verification is disabled.')),
          findsNothing);

      final ico = icons(tester).toList();
      expect(ico.map((i) => i.icon),
          [Icons.warning_amber, Icons.info_outline]);
      expect(ico.last.color,
          warningSeverityColor(tester.element(find.byType(NodeWarningRow)),
              WarningSeverity.info));
    });

    testWidgets('«+N more» считает только error и warning', (tester) async {
      await pumpRow(tester, const [infoW, warnW, errW, DeprecatedFlowWarning('x')],
          compact: true);
      // Два actionable → «+1 more», два info — одним значком.
      expect(find.textContaining('(+1 more)'), findsOneWidget);
    });

    testWidgets('error + warning — красный текст старшего, как раньше',
        (tester) async {
      await pumpRow(tester, const [warnW, errW], compact: true);

      final ico = icons(tester).toList();
      expect(ico, hasLength(1), reason: 'info-значка тут быть не должно');
      expect(ico.single.icon, Icons.error_outline);

      final ctx = tester.element(find.byType(NodeWarningRow));
      expect(ico.single.color,
          warningSeverityColor(ctx, WarningSeverity.error));
      expect(find.textContaining('Required field "sni" is missing.'),
          findsOneWidget);
      expect(find.textContaining('(+1 more)'), findsOneWidget);
    });

    testWidgets('полный режим (экран узла) — текст info виден и синий',
        (tester) async {
      await pumpRow(tester, const [infoW]);

      final text = tester.widget<Text>(find.descendant(
          of: find.byType(NodeWarningRow),
          matching: find.text('TLS certificate verification is disabled.')));
      final ctx = tester.element(find.byType(NodeWarningRow));
      expect(text.style?.color, warningSeverityColor(ctx, WarningSeverity.info));
      expect(icons(tester).single.icon, Icons.info_outline);
    });
  });

  group('§471 — общая палитра уровней', () {
    late BuildContext lightCtx;
    late BuildContext darkCtx;

    testWidgets('цвета и значки берутся из одного места', (tester) async {
      // Обе темы — в одном дереве: контекст из предыдущего pumpWidget'а
      // переехал бы на новую тему и обе ветки дали бы один цвет.
      await tester.pumpWidget(MaterialApp(
        home: Column(children: [
          Theme(
            data: ThemeData(brightness: Brightness.light),
            child: Builder(builder: (c) {
              lightCtx = c;
              return const SizedBox.shrink();
            }),
          ),
          Theme(
            data: ThemeData(brightness: Brightness.dark),
            child: Builder(builder: (c) {
              darkCtx = c;
              return const SizedBox.shrink();
            }),
          ),
        ]),
      ));

      // Значки — по таблице спеки, одни в обеих темах.
      for (final ctx in [lightCtx, darkCtx]) {
        expect(warningSeverityStyle(ctx, WarningSeverity.error).$2,
            Icons.error_outline);
        expect(warningSeverityStyle(ctx, WarningSeverity.warning).$2,
            Icons.warning_amber);
        expect(warningSeverityStyle(ctx, WarningSeverity.info).$2,
            Icons.info_outline);
      }

      // Цвет info — синий, warning — жёлтый, и в темах он РАЗНЫЙ: серый
      // `onSurfaceVariant` и плоский `Colors.orange` были бы одинаковы.
      expect(warningSeverityColor(lightCtx, WarningSeverity.info),
          Colors.blue.shade700);
      expect(warningSeverityColor(darkCtx, WarningSeverity.info),
          Colors.blue.shade300);
      expect(warningSeverityColor(lightCtx, WarningSeverity.warning),
          Colors.amber.shade800);
      expect(warningSeverityColor(darkCtx, WarningSeverity.warning),
          Colors.amber.shade300);
      // error — семантический токен темы.
      expect(warningSeverityColor(lightCtx, WarningSeverity.error),
          Theme.of(lightCtx).colorScheme.error);
    });

    testWidgets('шторка красит записи той же палитрой', (tester) async {
      // Две записи, а не три: ListView строит только видимые, и карточка с
      // Why/What to do высокая — третья не доехала бы до дерева.
      await pumpSheet(tester, const [
        UnsupportedTransportWarning('quic', 'ws'),
        DeprecatedFlowWarning('xtls-rprx-direct'),
      ]);
      final ctx = tester.element(find.byType(NodeWarningsSheet));
      final ico = tester
          .widgetList<Icon>(find.descendant(
              of: find.byType(NodeWarningsSheet), matching: find.byType(Icon)))
          // «Learn more» тоже несёт иконку — берём только значки уровней.
          .where((i) => i.icon != Icons.open_in_new)
          .toList();
      // Порядок сортировки — старшее выше.
      expect(ico.map((i) => i.icon),
          [Icons.warning_amber, Icons.info_outline]);
      expect(ico[0].color, warningSeverityColor(ctx, WarningSeverity.warning));
      expect(ico[1].color, warningSeverityColor(ctx, WarningSeverity.info));
    });
  });

  group('запись карточки', () {
    testWidgets('код реестра → Why, What to do и ссылка', (tester) async {
      await pumpSheet(tester, const [InsecureTlsWarning()]);

      expect(find.text('Why'), findsOneWidget);
      expect(find.text('What to do'), findsOneWidget);
      expect(find.text('Learn more'), findsOneWidget);

      // Тексты — из реестра дословно, а не из словаря приложения.
      final text = ContractRegistry.I.textFor('tls_insecure')!;
      expect(find.text(text.causeEn!), findsOneWidget);
      for (final step in text.fixEn) {
        expect(find.text(step), findsOneWidget);
      }
    });

    testWidgets('рукописное предупреждение без кода реестра — без ссылки',
        (tester) async {
      await pumpSheet(tester, const [SectionsConflictWarning()]);

      // Текст самого предупреждения на месте — он свой, из словаря UI.
      expect(find.textContaining('The document carries both'), findsOneWidget);
      // А объяснять и вести некуда: кода в реестре нет.
      expect(find.text('Learn more'), findsNothing);
      expect(find.text('Why'), findsNothing);
      expect(find.text('What to do'), findsNothing);
    });

    testWidgets('код вне реестра → запись без Why/What to do/ссылки',
        (tester) async {
      // Санитайзер может выдать код, которого текущий синк ещё не знает:
      // блоки не рисуются, а строка предупреждения остаётся — кодом.
      await pumpSheet(tester, const [
        RegistryWarning(code: 'code_from_the_future', path: 'tls.foo'),
      ]);

      expect(find.text('code_from_the_future'), findsOneWidget);
      expect(find.text('Why'), findsNothing);
      expect(find.text('What to do'), findsNothing);
      expect(find.text('Learn more'), findsNothing);
    });

    testWidgets('подстановки {path}/{value} доходят до Why и What to do',
        (tester) async {
      // reality_key_share_invalid — код с параметром {value} в тексте
      // исправления; карточка обязана подставлять его так же, как строка.
      await pumpSheet(tester, const [
        RegistryWarning(
          code: 'reality_key_share_invalid',
          path: 'tls.reality.key_share',
          value: 'garbage',
        ),
      ]);

      final raw = ContractRegistry.I.textFor('reality_key_share_invalid')!;
      for (final step in raw.fixEn) {
        final expected = step
            .replaceAll('{path}', 'tls.reality.key_share')
            .replaceAll('{value}', 'garbage');
        expect(find.text(expected), findsOneWidget);
        if (step != expected) {
          expect(find.text(step), findsNothing,
              reason: 'плейсхолдер остался неподставленным');
        }
      }
    });

    testWidgets('несколько предупреждений — все записи в списке',
        (tester) async {
      await pumpSheet(tester, const [
        InsecureTlsWarning(),
        SectionsConflictWarning(),
        RegistryWarning(code: 'ss_method_legacy', params: {'method': 'rc4-md5'}),
      ]);

      expect(find.text('TLS certificate verification is disabled.'),
          findsOneWidget);
      expect(find.textContaining('The document carries both'), findsOneWidget);
      // Ссылок ровно две: у двух записей есть код, который знает реестр.
      expect(find.text('Learn more'), findsNWidgets(2));
    });
  });

  group('язык карточки', () {
    testWidgets('ru → русские тексты реестра', (tester) async {
      LocaleController.I.setting = 'ru';
      await pumpSheet(tester, const [InsecureTlsWarning()]);

      final text = ContractRegistry.I.textFor('tls_insecure')!;
      expect(find.text(text.causeRu!), findsOneWidget);
      expect(find.text(text.causeEn!), findsNothing);
    });

    testWidgets('zh получает английский текст реестра', (tester) async {
      // В реестре два языка; всё, что не ru, читает en (спека §2.3).
      LocaleController.I.setting = 'zh';
      await pumpSheet(tester, const [InsecureTlsWarning()]);

      final text = ContractRegistry.I.textFor('tls_insecure')!;
      expect(find.text(text.causeEn!), findsOneWidget);
      expect(find.text(text.causeRu!), findsNothing);
    });
  });

  group('адрес страницы', () {
    test('ссылка собрана по коду и ведёт в main нашего репозитория', () {
      final url = contractWarningDocUrl('tls_insecure');
      expect(
          url,
          'https://github.com/Leadaxe/LxBox/blob/main/docs/contract/'
          'warnings.md#tls_insecure');
    });

    test('якорь — сам код, без нормализации', () {
      // Коды реестра — snake_case; ссылка обязана вести на них дословно,
      // иначе якорь не совпадёт с `<a id>` страницы.
      expect(contractWarningDocUrl('reality_key_share_invalid'),
          endsWith('#reality_key_share_invalid'));
    });
  });
}
