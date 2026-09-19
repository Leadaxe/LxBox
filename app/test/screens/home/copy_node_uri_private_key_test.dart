import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/screens/home/node_actions.dart';

import '../../parser/engine_test_setup.dart';

/// §466 — «Copy URI» у узла, чья ссылка несёт приватный ключ, спрашивает
/// подтверждение (§463 здесь отказывал наотрез). Проверяем обе ветки диалога,
/// какие узлы его вызывают и что у остальных копирование как было.
void main() {
  // §480 W7 — эмит ссылки исполняет секции реестра; рукописного `toUri` у
  // схем не осталось.
  setUpAll(loadEngineSections);

  late String? clipboard;

  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  UserServer listWith(List<NodeSpec> nodes) => UserServer(
        id: 'list-1',
        name: 'list-1',
        enabled: true,
        tagPrefix: '',
        detourPolicy: DetourPolicy.defaults,
        nodes: nodes,
      );

  SubscriptionController controllerWith(NodeSpec node) {
    final c = SubscriptionController();
    c.debugSetEntries([SubscriptionEntry(list: listWith([node]))]);
    return c;
  }

  /// Экран с одной кнопкой, дёргающей `copyNodeUri` — диалогу нужен Navigator,
  /// снэкбару Scaffold.
  Future<void> pumpAndTap(WidgetTester tester, SubscriptionController c,
      String tag) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => copyNodeUri(context, tag, c),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  SshSpec ssh({String privateKey = '', String password = ''}) => SshSpec(
        id: 'n1',
        tag: 'ssh-1',
        label: 'ssh-1',
        server: '10.0.0.1',
        port: 22,
        rawSource: '',
        user: 'root',
        password: password,
        privateKey: privateKey,
      );

  WireguardSpec wg() => WireguardSpec(
        id: 'n1',
        tag: 'wg-1',
        label: 'wg-1',
        server: '10.0.0.2',
        port: 51820,
        rawSource: '',
        privateKey: 'cHJpdmF0ZUtleUJhc2U2NA==',
        localAddresses: const ['10.2.0.2/32'],
        peers: const [
          WireguardPeer(
            publicKey: 'cHVibGljS2V5QmFzZTY0',
            endpointHost: '10.0.0.2',
            endpointPort: 51820,
          ),
        ],
      );

  MasqueSpec masque() => MasqueSpec(
        id: 'n1',
        tag: 'masque-1',
        label: 'masque-1',
        server: '10.0.0.3',
        port: 443,
        rawSource: '',
        privateKeyDer: 'cHJpdgo=',
        publicKeyDer: 'cHViCg==',
        localAddresses: const ['172.16.0.2/32'],
      );

  VlessSpec vless() => VlessSpec(
        id: 'n1',
        tag: 'vless-1',
        label: 'vless-1',
        server: '10.0.0.4',
        port: 443,
        rawSource: '',
        uuid: '11111111-2222-3333-4444-555555555555',
      );

  group('геттер linkCarriesPrivateKey', () {
    test('true у SSH с ключом, false у SSH только с паролем', () {
      expect(ssh(privateKey: '-----BEGIN-----').linkCarriesPrivateKey, isTrue);
      expect(ssh(password: 'p').linkCarriesPrivateKey, isFalse);
    });

    test('true у WireGuard (в т.ч. AWG — тот же класс)', () {
      expect(wg().linkCarriesPrivateKey, isTrue);
    });

    test('true у MASQUE с приватником', () {
      expect(masque().linkCarriesPrivateKey, isTrue);
    });

    test('false у vless — UUID ключом не считается', () {
      expect(vless().linkCarriesPrivateKey, isFalse);
    });

    test('ключ действительно попадает в ссылку', () {
      expect(ssh(privateKey: 'KEY').toUri(), contains('private_key=KEY'));
      expect(wg().toUri(), contains('cHJpdmF0ZUtleUJhc2U2NA'));
      expect(masque().toUri(), contains('cHJpdg'));
    });
  });

  group('copyNodeUri', () {
    testWidgets('SSH с ключом: диалог, Cancel — буфер пуст', (tester) async {
      final node = ssh(privateKey: '-----BEGIN-----');
      await pumpAndTap(tester, controllerWith(node), 'ssh-1');

      expect(find.text('Link contains a private key'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(clipboard, isNull);
      expect(find.text('URI copied'), findsNothing);
    });

    testWidgets('SSH с ключом: Copy anyway — в буфере toUri()',
        (tester) async {
      final node = ssh(privateKey: '-----BEGIN-----');
      await pumpAndTap(tester, controllerWith(node), 'ssh-1');

      await tester.tap(find.text('Copy anyway'));
      await tester.pumpAndSettle();

      expect(clipboard, node.toUri());
      expect(find.text('URI copied'), findsOneWidget);
    });

    testWidgets('тап мимо диалога — ничего не копируется', (tester) async {
      await pumpAndTap(
          tester, controllerWith(ssh(privateKey: 'K')), 'ssh-1');

      // Barrier: тап в верхний угол, вне AlertDialog.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('Link contains a private key'), findsNothing);
      expect(clipboard, isNull);
    });

    testWidgets('WireGuard-узел — тоже диалог', (tester) async {
      await pumpAndTap(tester, controllerWith(wg()), 'wg-1');
      expect(find.text('Link contains a private key'), findsOneWidget);
    });

    testWidgets('MASQUE-узел — тоже диалог', (tester) async {
      await pumpAndTap(tester, controllerWith(masque()), 'masque-1');
      expect(find.text('Link contains a private key'), findsOneWidget);
    });

    testWidgets('vless — копирование без диалога', (tester) async {
      final node = vless();
      await pumpAndTap(tester, controllerWith(node), 'vless-1');

      expect(find.text('Link contains a private key'), findsNothing);
      expect(clipboard, node.toUri());
      expect(find.text('URI copied'), findsOneWidget);
    });

    testWidgets('SSH с паролем без ключа — без диалога', (tester) async {
      final node = ssh(password: 'secret');
      await pumpAndTap(tester, controllerWith(node), 'ssh-1');

      expect(find.text('Link contains a private key'), findsNothing);
      expect(clipboard, node.toUri());
    });

    testWidgets('тег без узла — сообщение, буфер не трогаем', (tester) async {
      await pumpAndTap(tester, controllerWith(vless()), 'no-such-tag');

      expect(find.text('No source URI for this node'), findsOneWidget);
      expect(clipboard, isNull);
    });
  });
}
