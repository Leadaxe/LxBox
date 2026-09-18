import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/screens/subscription_detail_screen/node_inspect_screen.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_notifications_view.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warning_row.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warnings_sheet.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/subscription_node_list.dart';
import 'package:lxbox/services/contract/contract_docs.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';
import 'package:lxbox/widgets/banner_palette.dart';

/// §479 — уведомления узла: строка в списке подписки и общий компонент
/// [NodeNotificationsView] (раздел на экране узла и шторка из списка).
///
/// Реестр грузится из `assets/contract` — зеркала в git: оно едет в APK, и
/// проверять записи имеет смысл ровно по тем текстам, которые увидит
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

  Future<void> pumpView(WidgetTester tester, List<NodeWarning> warnings) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: NodeNotificationsView(warnings)),
        ),
      ));

  /// Строка под узлом в дереве, близком к боевому: она живёт в `subtitle`
  /// ListTile'а, у которого свой onTap — проверяем, что шторку открывает
  /// именно она, а не он.
  Future<void> pumpRow(WidgetTester tester, List<NodeWarning> warnings,
          {VoidCallback? onTileTap, ThemeData? theme}) =>
      tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
          body: ListTile(
            title: const Text('node'),
            subtitle: NodeWarningRow(warnings),
            onTap: onTileTap ?? () {},
          ),
        ),
      ));

  group('строка предупреждений открывает уведомления', () {
    testWidgets('тап по строке → шторка со всеми уведомлениями',
        (tester) async {
      await pumpRow(tester, const [
        InsecureTlsWarning(),
        SectionsConflictWarning(),
      ]);
      expect(find.text('Notifications'), findsNothing);

      await tester.tap(find.byType(NodeWarningRow));
      await tester.pumpAndSettle();

      expect(find.text('Notifications'), findsOneWidget);
      // Оба уведомления, а не только actionable: строка под узлом показывала
      // одно warning'овое, info в ней только значком.
      expect(
        find.descendant(
          of: find.byType(NodeWarningsSheet),
          matching: find.textContaining('The document carries both'),
        ),
        findsOneWidget,
      );
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
      await pumpRow(tester, const [SectionsConflictWarning()],
          onTileTap: () => tileTaps++);

      await tester.tap(find.byType(NodeWarningRow));
      await tester.pumpAndSettle();

      expect(tileTaps, 0, reason: 'тап провалился на ListTile под строкой');
      expect(find.text('Notifications'), findsOneWidget);
    });

    testWidgets('строка объявлена кнопкой для screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpRow(tester, const [UnsupportedTransportWarning('quic', 'ws')]);
      expect(
        tester.getSemantics(find.byType(NodeWarningRow)),
        matchesSemantics(
          isButton: true,
          hasTapAction: true,
          label: 'Transport "quic" is not supported by sing-box; using "ws" '
              'fallback (node may fail to connect).',
        ),
      );
      handle.dispose();
    });
  });

  group('§479 — уровни в строке под узлом', () {
    const infoW = InsecureTlsWarning(); // info
    const warnW = UnsupportedTransportWarning('quic', 'ws'); // warning
    const errW = MissingFieldWarning('sni'); // error

    Iterable<Icon> icons(WidgetTester tester) => tester
        .widgetList<Icon>(find.descendant(
            of: find.byType(NodeWarningRow), matching: find.byType(Icon)));

    testWidgets('только info — строки предупреждения нет вовсе',
        (tester) async {
      await pumpRow(tester, const [infoW]);

      // Ни текста, ни значка уровня: info в списке живёт значком в строке
      // протокола, а не третьей строкой.
      expect(find.descendant(
              of: find.byType(NodeWarningRow), matching: find.byType(Text)),
          findsNothing);
      expect(icons(tester), isEmpty);
    });

    testWidgets('warning + info — значок info в КОНЦЕ строки и приглушённый',
        (tester) async {
      await pumpRow(tester, const [infoW, warnW]);

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

      // §479: порядок значков — уровень, потом info.
      final ico = icons(tester).toList();
      expect(ico.map((i) => i.icon),
          [Icons.warning_amber, Icons.info_outline]);
      // Приглушённый, а не синий уровня.
      final ctx = tester.element(find.byType(NodeWarningRow));
      expect(ico.last.color, Theme.of(ctx).colorScheme.onSurfaceVariant);
      expect(ico.last.color,
          isNot(warningSeverityColor(ctx, WarningSeverity.info)));
    });

    testWidgets('«+N more» считает только error и warning', (tester) async {
      await pumpRow(
          tester, const [infoW, warnW, errW, DeprecatedFlowWarning('x')]);
      // Два actionable → «+1 more», два info — одним значком.
      expect(find.textContaining('(+1 more)'), findsOneWidget);
    });

    testWidgets('error + warning — красный текст старшего, info-значка нет',
        (tester) async {
      await pumpRow(tester, const [warnW, errW]);

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

    testWidgets('текстом идёт ЗАГОЛОВОК кода реестра, а не полный текст',
        (tester) async {
      // §479 — источник строки — `title_<lang>` реестра: полный текст в
      // строку списка не помещался и обрывался на полуслове.
      const w = RegistryWarning(
          code: 'transport_unsupported',
          path: 'transport.type',
          params: {'transport': 'quic', 'fallback': 'ws'});
      await pumpRow(tester, const [w]);

      final raw = ContractRegistry.I.textFor('transport_unsupported')!;
      String subst(String s) => s
          .replaceAll('{path}', 'transport.type')
          .replaceAll('{transport}', 'quic')
          .replaceAll('{fallback}', 'ws');
      expect(find.text(subst(raw.titleEn)), findsOneWidget);
      // Полный текст в строку не едет — он длиннее и живёт в уведомлениях.
      expect(raw.textEn, isNot(raw.titleEn));
      expect(find.text(subst(raw.textEn)), findsNothing);
    });
  });

  group('§479 — место значка info в списке узлов', () {
    NodeSpec node(String label, List<NodeWarning> warnings) => VlessSpec(
          id: label,
          tag: label,
          label: label,
          server: 'example.com',
          port: 443,
          rawSource: '',
          uuid: '00000000-0000-0000-0000-000000000000',
          warnings: warnings,
        );

    Future<void> pumpList(WidgetTester tester, List<NodeSpec> nodes) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SubscriptionNodeList(
                nodes: nodes, loading: false, error: null),
          ),
        ));

    /// Значок в `title` строки — то есть рядом с именем.
    Finder badgeAtTitle(String label) => find.descendant(
          of: find.ancestor(
              of: find.text(label), matching: find.byType(Row)),
          matching: find.byType(NodeInfoBadge),
        );

    testWidgets('только info — значок в строке протокола, имя чистое, '
        'третьей строки нет', (tester) async {
      await pumpList(tester, [node('info-only', const [InsecureTlsWarning()])]);

      // Значок есть — но не у имени.
      expect(find.byType(NodeInfoBadge), findsOneWidget);
      expect(badgeAtTitle('info-only'), findsNothing);
      // Он стоит в одном Row со строкой протокола.
      expect(
        find.descendant(
          of: find.ancestor(
              of: find.text('vless  example.com:443'),
              matching: find.byType(Row)),
          matching: find.byType(NodeInfoBadge),
        ),
        findsOneWidget,
      );
      // Строки предупреждения под узлом нет вовсе.
      expect(find.byType(NodeWarningRow), findsNothing);
      expect(find.text('TLS certificate verification is disabled.'),
          findsNothing);
    });

    testWidgets('значок приглушён, а не синий', (tester) async {
      await pumpList(tester, [node('info-only', const [InsecureTlsWarning()])]);
      final ctx = tester.element(find.byType(NodeInfoBadge));
      final ico = tester.widget<Icon>(find.descendant(
          of: find.byType(NodeInfoBadge), matching: find.byType(Icon)));
      expect(ico.icon, Icons.info_outline);
      expect(ico.color, Theme.of(ctx).colorScheme.onSurfaceVariant);
    });

    testWidgets('зона тапа значка не меньше 24×24', (tester) async {
      // Значок 14 px — пальцем в него не попасть; подложка обязана быть
      // рекомендованного Material размера.
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: Center(child: NodeInfoBadge([InsecureTlsWarning()]))),
      ));
      final size = tester.getSize(find.byType(NodeInfoBadge));
      expect(size.width, greaterThanOrEqualTo(24));
      expect(size.height, greaterThanOrEqualTo(24));
    });

    testWidgets('тап по значку открывает уведомления и не проваливается в '
        'разбор узла', (tester) async {
      await pumpList(tester, [node('info-only', const [InsecureTlsWarning()])]);

      await tester.tap(find.byType(NodeInfoBadge));
      await tester.pumpAndSettle();

      expect(find.byType(NodeWarningsSheet), findsOneWidget);
      expect(find.byType(NodeInspectScreen), findsNothing);
    });

    testWidgets('warning + info — значок info в строке предупреждения, '
        'у имени его нет', (tester) async {
      await pumpList(tester, [
        node('mixed', const [
          InsecureTlsWarning(),
          UnsupportedTransportWarning('quic', 'ws'),
        ]),
      ]);

      expect(badgeAtTitle('mixed'), findsNothing);
      expect(
        find.descendant(
            of: find.byType(NodeWarningRow),
            matching: find.byType(NodeInfoBadge)),
        findsOneWidget,
      );

      final ico = tester
          .widgetList<Icon>(find.descendant(
              of: find.byType(NodeWarningRow), matching: find.byType(Icon)))
          .toList();
      expect(ico.map((i) => i.icon), [Icons.warning_amber, Icons.info_outline]);
    });

    testWidgets('узел без предупреждений — ни значка, ни строки',
        (tester) async {
      await pumpList(tester, [node('clean', const [])]);
      expect(find.byType(NodeInfoBadge), findsNothing);
      expect(find.byType(NodeWarningRow), findsNothing);
    });
  });

  group('§479 — шапка со счётчиками и подразделы', () {
    testWidgets('счётчики по уровням, нулевых нет', (tester) async {
      await pumpView(tester, const [
        MissingFieldWarning('sni'), // error
        UnsupportedTransportWarning('quic', 'ws'), // warning
        UnknownObfsWarning('gecko'), // warning
      ]);

      // Три записи, два уровня: 1 и 2, без «0» для info.
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      // Подзаголовков два — уровней два.
      expect(find.text('Errors'), findsOneWidget);
      expect(find.text('Warnings'), findsOneWidget);
      expect(find.text('Info'), findsNothing);
    });

    testWidgets('единственный уровень — подзаголовка нет', (tester) async {
      await pumpView(tester, const [
        UnsupportedTransportWarning('quic', 'ws'),
        UnknownObfsWarning('gecko'),
      ]);

      expect(find.text('Warnings'), findsNothing);
      expect(find.text('Errors'), findsNothing);
      // Счётчик при этом на месте.
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('три уровня — три подзаголовка в порядке error → warning → '
        'info', (tester) async {
      await pumpView(tester, const [
        InsecureTlsWarning(),
        UnsupportedTransportWarning('quic', 'ws'),
        MissingFieldWarning('sni'),
      ]);

      final headers = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .where((s) => s == 'Errors' || s == 'Warnings' || s == 'Info')
          .toList();
      expect(headers, ['Errors', 'Warnings', 'Info']);
    });

    testWidgets('узел без уведомлений — компонент пуст', (tester) async {
      await pumpView(tester, const []);
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.byType(Icon), findsNothing);
    });
  });

  group('§479 — запись уведомления', () {
    testWidgets('несколько записей — свёрнуты; тап разворачивает',
        (tester) async {
      await pumpView(tester, const [
        InsecureTlsWarning(),
        UnsupportedTransportWarning('quic', 'ws'),
      ]);

      // Свёрнуто: разбор не построен.
      expect(find.text('Why it happens'), findsNothing);
      expect(find.text('What you can do'), findsNothing);
      expect(find.text('Details'), findsNothing);

      await tester.tap(find.text('TLS certificate verification is disabled.'));
      await tester.pumpAndSettle();

      expect(find.text('Why it happens'), findsOneWidget);
      expect(find.text('What you can do'), findsOneWidget);
      expect(find.text('Details'), findsOneWidget);
      final text = ContractRegistry.I.textFor('tls_insecure')!;
      expect(find.text(text.causeEn!), findsOneWidget);
      for (final step in text.fixEn) {
        expect(find.text(step), findsOneWidget);
      }
    });

    testWidgets('единственная запись развёрнута сразу', (tester) async {
      await pumpView(tester, const [InsecureTlsWarning()]);

      expect(find.text('Why it happens'), findsOneWidget);
      expect(find.text('What you can do'), findsOneWidget);
      expect(find.text('Details'), findsOneWidget);
    });

    testWidgets('путь поля показан моноширинно', (tester) async {
      await pumpView(tester, const [
        RegistryWarning(
          code: 'reality_key_share_invalid',
          path: 'tls.reality.key_share',
          value: 'garbage',
        ),
      ]);

      final path = tester.widget<Text>(find.text('tls.reality.key_share'));
      expect(path.style?.fontFamily, 'monospace');
    });

    testWidgets('рукописное предупреждение без кода реестра — без блоков',
        (tester) async {
      await pumpView(tester, const [SectionsConflictWarning()]);

      // Заголовок на месте — он свой, из словаря UI.
      expect(find.textContaining('The document carries both'), findsOneWidget);
      // А объяснять и вести некуда: кода в реестре нет.
      expect(find.text('Details'), findsNothing);
      expect(find.text('Why it happens'), findsNothing);
      expect(find.text('What you can do'), findsNothing);
    });

    testWidgets('код вне реестра = warning и запись без блоков',
        (tester) async {
      // Санитайзер может выдать код, которого текущий синк ещё не знает:
      // уровень по умолчанию — warning (незнакомое не глушим), блоки не
      // рисуются, а заголовком остаётся сам код.
      const w = RegistryWarning(code: 'code_from_the_future', path: 'tls.foo');
      expect(w.severity, WarningSeverity.warning);

      await pumpView(tester, const [w]);

      expect(find.text('code_from_the_future'), findsOneWidget);
      expect(find.text('Why it happens'), findsNothing);
      expect(find.text('What you can do'), findsNothing);
      expect(find.text('Details'), findsNothing);
      // Значок — warning'овый.
      expect(
        tester
            .widgetList<Icon>(find.byType(Icon))
            .map((i) => i.icon)
            .contains(Icons.warning_amber),
        isTrue,
      );
    });

    testWidgets('подстановки {path}/{value} доходят до блоков', (tester) async {
      await pumpView(tester, const [
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

    testWidgets('палитра уровней — общая', (tester) async {
      await pumpView(tester, const [
        UnsupportedTransportWarning('quic', 'ws'),
        DeprecatedFlowWarning('xtls-rprx-direct'),
      ]);
      final ctx = tester.element(find.byType(NodeNotificationsView));
      final ico = tester
          .widgetList<Icon>(find.descendant(
              of: find.byType(ExpansionTile), matching: find.byType(Icon)))
          // Стрелка раскрытия тоже иконка — берём только значки уровней.
          .where((i) =>
              i.icon == Icons.warning_amber || i.icon == Icons.info_outline)
          .toList();
      // Порядок разделов — старшее выше.
      expect(ico.map((i) => i.icon),
          [Icons.warning_amber, Icons.info_outline]);
      expect(ico[0].color, warningSeverityColor(ctx, WarningSeverity.warning));
      // Внутри уведомлений info остаётся СИНИМ (приглушён он только в списке).
      expect(ico[1].color, warningSeverityColor(ctx, WarningSeverity.info));
    });
  });

  group('§479 — шторка', () {
    testWidgets('заголовок шторки — Notifications', (tester) async {
      await pumpSheet(tester, const [InsecureTlsWarning()]);
      expect(
        find.descendant(
            of: find.byType(NodeWarningsSheet), matching: find.text('Notifications')),
        findsOneWidget,
      );
      expect(find.text('Warnings'), findsNothing);
    });

    testWidgets('шторка показывает тот же компонент', (tester) async {
      await pumpSheet(tester, const [InsecureTlsWarning()]);
      expect(find.byType(NodeNotificationsView), findsOneWidget);
    });
  });

  group('язык уведомлений', () {
    testWidgets('ru → русские тексты реестра', (tester) async {
      LocaleController.I.setting = 'ru';
      await pumpView(tester, const [InsecureTlsWarning()]);

      final text = ContractRegistry.I.textFor('tls_insecure')!;
      expect(find.text(text.causeRu!), findsOneWidget);
      expect(find.text(text.causeEn!), findsNothing);
    });

    test('«Info» подзаголовка — своя форма словаря, не «Информация»', () {
      // §285 collisions: корневой `Info` занят разделом «Protocol and server
      // details» экрана узла, подзаголовку уровня нужна форма 1. Перевод
      // сверяем по самому словарю: в виджет-тесте словарь не загружен
      // (`LocaleController` тянет его через rootBundle асинхронно), и
      // `getLocalText` отдал бы английский ключ независимо от локали.
      final ru = jsonDecode(
              File('assets/l10n/ru/ui.json').readAsStringSync())
          as Map<String, dynamic>;
      final info = ru['Info'] as Map<String, dynamic>;
      expect(info['value'], 'Информация');
      expect((info['special'] as Map)['1']['value'], 'К сведению');

      final zh = jsonDecode(
              File('assets/l10n/zh/ui.json').readAsStringSync())
          as Map<String, dynamic>;
      final zhInfo = zh['Info'] as Map<String, dynamic>;
      expect((zhInfo['special'] as Map)['1']['value'], isNotEmpty);
      expect(zhInfo['special']['1']['value'], isNot(zhInfo['value']));
    });

    testWidgets('zh получает английский текст реестра', (tester) async {
      // В реестре два языка; всё, что не ru, читает en (спека §460 §2.3).
      LocaleController.I.setting = 'zh';
      await pumpView(tester, const [InsecureTlsWarning()]);

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
