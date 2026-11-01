import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/screens/subscription_detail_screen/node_inspect_screen.dart';
import 'package:lxbox/widgets/node_diagnostics_tab.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_notifications_view.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warning_row.dart';
import 'package:lxbox/screens/subscription_detail_screen/widgets/node_warnings_sheet.dart';
import 'package:lxbox/services/contract/contract_docs.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/l10n/locale_controller.dart';

/// §479 — уведомления узла: строка в списке подписки и общий компонент
/// [NodeNotificationsView] (раздел на экране узла и шторка из списка).
///
/// Реестр грузится из `assets/contract` — зеркала в git: оно едет в APK, и
/// проверять записи имеет смысл ровно по тем текстам, которые увидит
/// пользователь. Копии контракта (`contract/`, gitignored) тесты здесь не
/// касаются.
const _registryRoot = 'assets/contract';

// §485 — живые коды реестра вместо снятых рукописных классов-образцов.
const _infoTls = RegistryWarning(
  code: 'tls_insecure',
  path: 'tls.insecure',
  value: 'true',
);
const _warnTransport = RegistryWarning(
  code: 'transport_unsupported',
  path: 'transport.type',
  params: {'transport': 'quic', 'fallback': 'ws'},
);

void main() {
  setUpAll(() async {
    await ContractRegistry.I.loadFromDirectory(_registryRoot);
  });

  tearDown(() {
    LocaleController.I.setting = 'system';
  });

  tearDownAll(ContractRegistry.I.resetForTesting);

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
        _infoTls,
        DetourToGroupWarning('grp'),
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
          matching: find.textContaining('grp'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(NodeWarningsSheet),
          matching: find.text(
              ContractRegistry.I.textFor('tls_insecure')!.titleEn),
        ),
        findsOneWidget,
      );
    });

    testWidgets('тап по строке не срабатывает как тап по строке узла',
        (tester) async {
      var tileTaps = 0;
      await pumpRow(tester, const [DetourToGroupWarning('grp')],
          onTileTap: () => tileTaps++);

      await tester.tap(find.byType(NodeWarningRow));
      await tester.pumpAndSettle();

      expect(tileTaps, 0, reason: 'тап провалился на ListTile под строкой');
      expect(find.text('Notifications'), findsOneWidget);
    });
  });

  group('§479 — запись уведомления', () {
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
  });

  group('§572 — группировка по коду', () {
    // Узел VLESS·xhttp·Reality из Xray-JSON: по коду на каждое непрочитанное
    // поле (`_unknownWarning` движка — имя и в path, и в params.query_name).
    const paths = [
      'streamSettings.finalmask.tcp.0.type',
      'streamSettings.finalmask.tcp.0.settings.delay',
      'streamSettings.finalmask.udp',
      'streamSettings.sockopt.tcpFastOpen',
      'streamSettings.xhttpSettings.extra',
      'streamSettings.xhttpSettings.noGRPCHeader',
      'streamSettings.tcpSettings',
    ];
    final unknownFields = [
      for (final p in paths)
        RegistryWarning(
          code: 'json_field_unknown',
          path: p,
          value: '',
          params: {'query_name': p},
        ),
    ];
    const countKey = ValueKey('notification-group-count-info-json_field_unknown');
    ValueKey<String> rowKey(int i) =>
        ValueKey('notification-group-row-info-json_field_unknown-$i');

    testWidgets('семь записей одного кода → одна плитка, число, строки, '
        'один разбор', (tester) async {
      await pumpView(tester, unknownFields);

      expect(find.byType(ExpansionTile), findsOneWidget);
      expect(
          tester.widget<Text>(find.byKey(countKey)).data, '${paths.length}');
      // Единственная плитка — развёрнута сразу.
      for (var i = 0; i < paths.length; i++) {
        final row = tester.widget<Text>(find.byKey(rowKey(i)));
        expect(row.data, paths[i], reason: 'порядок записей — исходный');
        expect(row.style?.fontFamily, 'monospace');
      }
      expect(find.text('What happened'), findsOneWidget);
      expect(find.text('Why it happens'), findsOneWidget);
      expect(find.text('What you can do'), findsOneWidget);
      expect(find.text('Details'), findsOneWidget);
    });

    testWidgets('один код на разных уровнях в группу не сливается',
        (tester) async {
      // `unknown_node_type` — per-app код (§585): класс даёт info, а
      // RegistryWarning того же кода вне реестра — warning по умолчанию.
      const inReg = RegistryWarning(code: 'unknown_node_type', path: 'x');
      expect(inReg.severity, WarningSeverity.warning);
      await pumpView(tester, const [
        UnknownNodeTypeWarning('openvpn-client'),
        inReg,
      ]);

      expect(find.byType(ExpansionTile), findsNWidgets(2));
      expect(
          find.byKey(
              const ValueKey('notification-group-count-info-unknown_node_type')),
          findsNothing);
      expect(
          find.byKey(const ValueKey(
              'notification-group-count-warning-unknown_node_type')),
          findsNothing);
      expect(find.text('Warnings'), findsOneWidget);
      expect(find.text('Info'), findsOneWidget);
    });
  });

  group('язык уведомлений', () {
    testWidgets('ru → русские тексты реестра', (tester) async {
      LocaleController.I.setting = 'ru';
      await pumpView(tester, const [_infoTls]);

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
      await pumpView(tester, const [_infoTls]);

      final text = ContractRegistry.I.textFor('tls_insecure')!;
      expect(find.text(text.causeEn!), findsOneWidget);
      expect(find.text(text.causeRu!), findsNothing);
    });
  });

  group('§501 — уведомления во вкладке Diagnostics', () {
    setUp(() => LocaleController.I.setting = 'en');

    bool isInViewport(WidgetTester tester, Finder finder, double height) {
      final rect = tester.getRect(finder);
      return rect.top >= 0 && rect.top < height;
    }

    NodeSpec inspectNode(List<NodeWarning> warnings) => VlessSpec(
          id: 'n1',
          tag: 'n1',
          label: 'n1',
          server: 'example.com',
          port: 443,
          rawSource: '',
          uuid: '00000000-0000-0000-0000-000000000000',
          warnings: warnings,
        );

    Future<void> pumpInspect(WidgetTester tester, NodeSpec node) =>
        tester.pumpWidget(MaterialApp(
          home: NodeInspectScreen(node: node),
        ));

    Future<void> openDiagnosticsTab(WidgetTester tester) async {
      await tester.tap(find.text('Diagnostics'));
      await tester.pumpAndSettle();
    }

    testWidgets('переход на Diagnostics с уведомлениями — прокрутка к секции',
        (tester) async {
      const viewportHeight = 480.0;
      tester.view.physicalSize = const Size(360, viewportHeight);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(MaterialApp(
        home: NodeInspectScreen(
          node: inspectNode(const [_warnTransport]),
          initialTab: NodeInspectTab.diagnostics,
        ),
      ));
      await tester.pumpAndSettle();

      final notif = find.descendant(
        of: find.byType(NodeDiagnosticsTab),
        matching: find.text('Notifications'),
      );
      expect(notif, findsOneWidget);
      expect(isInViewport(tester, notif, viewportHeight), isTrue);
    });

    testWidgets('обычное открытие Diagnostics — без автопрокрутки к уведомлениям',
        (tester) async {
      const viewportHeight = 480.0;
      tester.view.physicalSize = const Size(360, viewportHeight);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await pumpInspect(tester, inspectNode(const [_warnTransport]));
      await openDiagnosticsTab(tester);

      final run = find.text('Run');
      expect(isInViewport(tester, run, viewportHeight), isTrue);
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
  });
}
