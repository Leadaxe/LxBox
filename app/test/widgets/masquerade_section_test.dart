import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/wireguard/masquerade_source.dart';
import 'package:lxbox/widgets/masquerade_fields.dart';

/// §623 — секция Masquerade вкладки Settings узла WireGuard/AmneziaWG.
/// Запись в источник проверяет `masquerade_source_test.dart`; здесь —
/// только виджет, без экрана узла и без моста к ядру.
void main() {
  final saved = <Masquerade>[];

  Future<void> pump(
    WidgetTester tester, {
    Masquerade initial = Masquerade.off,
    String? reason,
    bool readOnly = false,
    bool sipBlocked = false,
    bool sourceDirty = false,
  }) async {
    saved.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MasqueradeSection(
              initial: initial,
              unavailableReason: reason,
              readOnly: readOnly,
              sipBlocked: sipBlocked,
              sourceDirty: sourceDirty,
              onSave: (m) async => saved.add(m),
            ),
          ),
        ),
      ),
    );
  }

  final saveButton = find.byKey(const ValueKey('masquerade-save'));
  final domainField = find.byKey(const ValueKey('masquerade-domain'));

  bool saveEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(saveButton).onPressed != null;

  Future<void> pickProtocol(WidgetTester tester, String label) async {
    await tester.tap(
      find.byKey(
        ValueKey(
          'masquerade-ip-${tester.widget<MasqueradeFields>(find.byType(MasqueradeFields)).ip}',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('explicit i1: fields disabled, reason shown, no Save', (
    tester,
  ) async {
    await pump(tester, reason: 'I1 wins');
    expect(
      find.byKey(const ValueKey('masquerade-unavailable')),
      findsOneWidget,
    );
    expect(find.text('I1 wins'), findsOneWidget);
    expect(saveButton, findsNothing);
    expect(
      tester.widget<MasqueradeFields>(find.byType(MasqueradeFields)).enabled,
      isFalse,
    );
  });

  testWidgets('i2 set: the sip item is disabled', (tester) async {
    await pump(tester, sipBlocked: true);
    await tester.tap(find.byKey(const ValueKey('masquerade-ip-')));
    await tester.pumpAndSettle();
    final sip = tester
        .widgetList<DropdownMenuItem<String>>(
          find.byType(DropdownMenuItem<String>),
        )
        .where((i) => i.value == 'sip');
    expect(sip, isNotEmpty);
    expect(sip.every((i) => !i.enabled), isTrue);
    final quicItems = tester
        .widgetList<DropdownMenuItem<String>>(
          find.byType(DropdownMenuItem<String>),
        )
        .where((i) => i.value == 'quic');
    expect(quicItems.every((i) => i.enabled), isTrue);
  });

  testWidgets('quic with an empty domain: Save disabled', (tester) async {
    await pump(tester);
    await pickProtocol(tester, 'QUIC');
    expect(domainField, findsOneWidget);
    expect(saveEnabled(tester), isFalse);
    expect(find.text('Domain is required for QUIC.'), findsOneWidget);

    await tester.enterText(
      find.descendant(of: domainField, matching: find.byType(TextField)),
      'www.example.org',
    );
    await tester.pumpAndSettle();
    expect(saveEnabled(tester), isTrue);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
    expect(saved, [const Masquerade(ip: 'quic', id: 'www.example.org')]);
  });

  testWidgets('stun: the domain field is hidden', (tester) async {
    await pump(
      tester,
      initial: const Masquerade(ip: 'dns', id: 'mask.example.net'),
    );
    expect(domainField, findsOneWidget);
    await pickProtocol(tester, 'STUN');
    expect(domainField, findsNothing);
    expect(saveEnabled(tester), isTrue);
  });

  testWidgets('subscription node: no Save', (tester) async {
    await pump(
      tester,
      readOnly: true,
      initial: const Masquerade(ip: 'quic', id: 'a.example', ib: 'chrome'),
    );
    expect(saveButton, findsNothing);
    expect(domainField, findsOneWidget);
    expect(
      tester.widget<MasqueradeFields>(find.byType(MasqueradeFields)).enabled,
      isFalse,
    );
  });

  testWidgets('unsaved Source edit: Save disabled with a note', (tester) async {
    await pump(tester, sourceDirty: true);
    await pickProtocol(tester, 'STUN');
    expect(saveEnabled(tester), isFalse);
    expect(find.text('Source has unsaved changes.'), findsOneWidget);
  });
}
