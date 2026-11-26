import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/contract/registry_form.dart';
import 'package:lxbox/services/tls/cert_pin_fetcher.dart';
import 'package:lxbox/widgets/openconnect_form.dart';

import '../contract_paths.dart';

/// Кнопка «Fetch from server» варианта «Pinned fingerprint»: диалог с
/// данными сертификата, «Use» пишет отпечаток в `tls.peer_fingerprint`.
class _FakeFetcher implements CertPinFetcher {
  // Создаётся в теле testWidgets: Completer из setUp живёт в настоящей зоне,
  // и его завершение не доходит до кадров FakeAsync.
  late Completer<CertPinInfo> next;
  final calls = <(String, String?)>[];

  @override
  Future<CertPinInfo> fetch(String server, {String? serverName}) {
    calls.add((server, serverName));
    return next.future;
  }
}

const _pin = 'pin-sha256:+VQgO8BfZcupR2G08jGN4CToJsOx69uWRi6QGbPywfI=';

final _info = CertPinInfo(
  subject: 'fw.example.com',
  issuer: 'Example Issuing CA',
  notAfter: DateTime.utc(2027, 5, 28),
  pin: _pin,
);

void main() {
  setUpAll(loadTestRegistry);

  late _FakeFetcher fetcher;
  late List<Map<String, dynamic>> emitted;

  Future<void> pump(WidgetTester tester, Map<String, dynamic> body) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) => OpenConnectForm(
                body: body,
                certPinFetcher: fetcher,
                onChanged: (b) {
                  emitted.add(b);
                  setState(() => body = b);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> body0() => {
    'type': 'openconnect',
    'tag': 'oc',
    'server': 'https://fw.example.com:42319',
    'tls': {
      'server_name': 'sni.example.com',
      'peer_fingerprint': ['sha256:abcd'],
    },
  };

  setUp(() {
    fetcher = _FakeFetcher();
    emitted = [];
  });

  // TextButton.icon — подкласс TextButton, byType его не видит.
  Finder button() => find.ancestor(
    of: find.text('Fetch from server'),
    matching: find.byWidgetPredicate((w) => w is TextButton),
  );

  Future<void> tapButton(WidgetTester tester) async {
    await tester.ensureVisible(button());
    await tester.tap(button());
  }

  testWidgets('диалог с данными → Use → отпечаток в tls.peer_fingerprint', (
    tester,
  ) async {
    fetcher.next = Completer();
    await pump(tester, body0());
    expect(button(), findsOneWidget);
    await tapButton(tester);
    await tester.pump();
    expect(fetcher.calls, [('https://fw.example.com:42319', 'sni.example.com')]);
    // Во время запроса кнопка неактивна, индикатор крутится.
    expect(tester.widget<TextButton>(button()).onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    fetcher.next.complete(_info);
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Pin this certificate?'), findsOneWidget);
    expect(find.text('fw.example.com'), findsOneWidget);
    expect(find.text('Example Issuing CA'), findsOneWidget);
    expect(find.text('2027-05-28'), findsOneWidget);
    expect(find.text(_pin), findsWidgets);

    await tester.tap(find.widgetWithText(TextButton, 'Use'));
    await tester.pumpAndSettle();
    expect(emitted, isNotEmpty);
    final last = emitted.last;
    expect(formValueAt(last, 'tls.peer_fingerprint'), [_pin]);
    expect(formValueAt(last, 'tls.server_name'), 'sni.example.com');
    expect(formValueAt(last, 'server'), 'https://fw.example.com:42319');
    // Поле ввода варианта показывает новое значение.
    expect(
      find.descendant(
        of: find.byType(TextFormField),
        matching: find.text(_pin),
      ),
      findsOneWidget,
    );
    expect(tester.widget<TextButton>(button()).onPressed, isNotNull);
  });

  testWidgets('Cancel — тело не меняется', (tester) async {
    fetcher.next = Completer();
    await pump(tester, body0());
    fetcher.next.complete(_info);
    await tapButton(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(emitted, isEmpty);
    expect(find.text('Pin this certificate?'), findsNothing);
  });

  testWidgets('ошибка fetcher — текст у кнопки, диалога нет', (tester) async {
    fetcher.next = Completer();
    await pump(tester, body0());
    // Ошибка — после нажатия: у Future уже есть слушатель.
    await tapButton(tester);
    await tester.pump();
    fetcher.next.completeError(const CertPinException(CertPinError.timeout));
    await tester.pumpAndSettle();
    expect(find.text('No response from the server'), findsOneWidget);
    expect(find.text('Pin this certificate?'), findsNothing);
    expect(emitted, isEmpty);

    // Повторное нажатие сбрасывает прежнюю ошибку.
    fetcher.next = Completer();
    await tapButton(tester);
    await tester.pump();
    expect(find.text('No response from the server'), findsNothing);
    fetcher.next.completeError(const CertPinException(CertPinError.notTls));
    await tester.pumpAndSettle();
    expect(find.text('No TLS on this address'), findsOneWidget);
  });
}
