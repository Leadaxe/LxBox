import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warning_row.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warnings_sheet.dart';
import 'package:lxbox/services/contract/contract_docs.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';

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
      {VoidCallback? onTileTap}) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListTile(
            title: const Text('node'),
            subtitle: NodeWarningRow(warnings),
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
