// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/subscriptions_screen/widgets/parse_input_error_banner.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/ui_msg.dart';
import 'package:lxbox/services/debug/context.dart';
import 'package:lxbox/services/debug/contract/errors.dart';
import 'package:lxbox/services/debug/debug_registry.dart';
import 'package:lxbox/services/debug/handlers/subs.dart';
import 'package:lxbox/services/debug/transport/request.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

void main() {
  setUpAll(loadEngineSections);

  late Directory tempDir;
  late SubscriptionController controller;

  const priv = 'cccccccccccccccccccccccccccccccccccccccccA=';
  const pub = 'ddddddddddddddddddddddddddddddddddddddddddA=';
  const testPriv = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=';
  const testPub = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbA=';
  final badCidrUri =
      'wireguard://$priv@198.51.100.13:51820?publickey=$pub&address=1.2.3.4%2F64&mtu=1280#wg-bad-cidr';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('parse_input_rej_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
    controller = SubscriptionController();
    await controller.init();
    DebugRegistry.I.sub = controller;
  });

  tearDown(() async {
    DebugRegistry.I.sub = null;
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  group('§500 — addFromInput отказ с причиной', () {
    test('негодный CIDR в wireguard:// — type_invalid, address', () async {
      await controller.addFromInput(badCidrUri);
      expect(controller.entries, isEmpty);
      expect(controller.lastError, isA<ParseInputRejectedMsg>());
      final err = controller.lastError! as ParseInputRejectedMsg;
      expect(err.key, ErrKey.couldNotParseDirectLink);
      expect(err.sourceLabel, 'wg-bad-cidr');
      expect(err.dropped, hasLength(1));
      final w = err.dropped.single as RegistryWarning;
      expect(w.code, 'type_invalid');
      expect(w.path, 'address');
      expect(w.value, '[1.2.3.4/64]');
      expect(err.render(), 'Could not parse direct link');
      expect(err.renderEn(), 'Could not parse direct link');
    });

    test('vless без server — field_missing', () async {
      await controller.addFromInput(
          'vless://11111111-2222-3333-4444-555555555555@:443');
      expect(controller.entries, isEmpty);
      final err = controller.lastError! as ParseInputRejectedMsg;
      expect(err.key, ErrKey.couldNotParseDirectLink);
      expect(err.sourceLabel, 'vless');
      final w = err.dropped.single as RegistryWarning;
      expect(w.code, 'field_missing');
      expect(w.path, 'server');
    });

    test('мусорная строка — прежнее сообщение без причины', () async {
      await controller.addFromInput('это не конфиг');
      expect(controller.entries, isEmpty);
      final err = controller.lastError;
      expect(err, isNotNull);
      expect(
          err is ParseInputRejectedMsg && err.hasDropped, isFalse);
    });

    test('[Peer] без Endpoint — invalidWireguardConfig + field_missing', () async {
      const text = '[Interface]\n'
          'PrivateKey = $testPriv\n'
          'Address = 10.0.0.2/32\n'
          '\n'
          '[Peer]\n'
          'PublicKey = $testPub\n'
          'AllowedIPs = 0.0.0.0/0\n';
      await controller.addFromInput(text);
      expect(controller.entries, isEmpty);
      final err = controller.lastError! as ParseInputRejectedMsg;
      expect(err.key, ErrKey.invalidWireguardConfig);
      expect(err.sourceLabel, 'wireguard');
      final w = err.dropped.single as RegistryWarning;
      expect(w.code, 'field_missing');
      expect(w.path, 'peers[].address');
    });

    test('JSON outbound без порта — noValidOutboundsInJson + причина', () async {
      await controller.addFromInput(jsonEncode({
        'remarks': 'no-port',
        'outbounds': [
          {
            'tag': 'proxy',
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'h.example',
                  'users': [
                    {'id': '11111111-2222-3333-4444-555555555555'},
                  ],
                },
              ],
            },
            'streamSettings': {'network': 'tcp', 'security': 'none'},
          },
        ],
      }));
      expect(controller.entries, isEmpty);
      final err = controller.lastError! as ParseInputRejectedMsg;
      expect(err.key, ErrKey.noValidOutboundsInJson);
      expect(err.dropped, isNotEmpty);
      expect((err.dropped.first as RegistryWarning).code, 'field_missing');
    });
  });

  group('POST /subs — dropped в теле ошибки', () {
    test('отказ с причиной несёт dropped[]', () async {
      final req = DebugRequest.forTest(
        method: 'POST',
        path: '/subs',
        query: const {},
        body: utf8.encode(jsonEncode({'input': badCidrUri})),
      );
      final ctx = DebugContext(
        registry: DebugRegistry.I,
        appStartedAt: DateTime.utc(2026, 9, 19),
      );

      final err = await subsHandler(req, ctx).then<DebugError>(
        (_) => throw StateError('expected BadRequest'),
        onError: (e) => e as DebugError,
      );
      expect(err, isA<BadRequest>());
      final body = err.toJson();
      expect(body['dropped'], isList);
      final drop = (body['dropped'] as List).single as Map;
      expect(drop['code'], 'type_invalid');
      expect(drop['path'], 'address');
      expect(drop['value'], '[1.2.3.4/64]');
      expect(drop['title_en'], isNotEmpty);
    });
  });

  group('ParseInputErrorBanner', () {
    const badReason = RegistryWarning(
      code: 'type_invalid',
      path: 'address',
      value: '1.2.3.4/64',
    );

    testWidgets('без причины — одна строка, тап не открывает шторку',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ParseInputErrorBanner(
            const ErrMsg(ErrKey.couldNotParseDirectLink),
          ),
        ),
      ));

      expect(find.text('Could not parse direct link'), findsOneWidget);
      await tester.tap(find.text('Could not parse direct link'));
      await tester.pumpAndSettle();
      expect(find.text('Notifications'), findsNothing);
    });

    testWidgets('с причиной — одна строка, тап открывает Notifications',
        (tester) async {
      final msg = ParseInputRejectedMsg(
        ErrKey.couldNotParseDirectLink,
        dropped: const [badReason],
        sourceLabel: 'wg-bad-cidr',
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ParseInputErrorBanner(msg),
        ),
      ));

      expect(find.text('Could not parse direct link'), findsOneWidget);
      expect(find.textContaining('address ='), findsNothing);

      await tester.tap(find.text('Could not parse direct link'));
      await tester.pumpAndSettle();
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('wg-bad-cidr'), findsOneWidget);
      expect(find.text('What happened'), findsOneWidget);
    });
  });
}
