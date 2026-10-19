// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/tls_policy.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/widgets/tls_policy_tiles.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

// §665 — нотис о наследовании фрагментации у узла: показан, когда
// `fragment`/`record_fragment` включены уровнем выше, а не своим флагом.
void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('tls_tiles_notice_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  String subtitleOf(WidgetTester tester, String key) {
    final tile = tester.widget<ListTile>(find.byKey(ValueKey('tls-$key')));
    return (tile.subtitle! as Text).data!;
  }

  final notice = find.byKey(const ValueKey('tls-inherit-notice'));

  Future<void> pumpTiles(
    WidgetTester tester, {
    required TlsPolicy policy,
    TlsPolicy inherited = TlsPolicy.none,
    TlsLevel inheritedLevel = TlsLevel.global,
  }) async {
    await tester.runAsync(() async {
      await SettingsStorage.setVar('tls_mixed_case_sni', 'true');
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TlsPolicyTiles(
          policy: policy,
          inherited: inherited,
          inheritedLevel: inheritedLevel,
          inheritNotice: true,
          onChanged: (_) {},
        ),
      ),
    ));
    // Глобальные vars читаются асинхронно — ждать подписи «On — global»
    // у поля, которого нотис не касается.
    for (var i = 0;
        i < 300 &&
            subtitleOf(tester, 'mixed_case_sni') != 'Default (On — global)';
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(subtitleOf(tester, 'mixed_case_sni'), 'Default (On — global)');
  }

  testWidgets('true с папки → нотис с уровнем folder', (tester) async {
    await pumpTiles(
      tester,
      policy: TlsPolicy.none,
      inherited: const TlsPolicy(recordFragment: true),
      inheritedLevel: TlsLevel.folder,
    );
    expect(notice, findsOneWidget);
    final text = tester
        .widget<Text>(find.descendant(of: notice, matching: find.byType(Text)))
        .data!;
    expect(text, contains('folder'));
  });

  testWidgets('своё true → нотиса нет', (tester) async {
    await pumpTiles(
      tester,
      policy: const TlsPolicy(fragment: true, recordFragment: true),
      inherited: const TlsPolicy(recordFragment: true),
      inheritedLevel: TlsLevel.folder,
    );
    expect(notice, findsNothing);
  });

  testWidgets('всё null или false → нотиса нет', (tester) async {
    await pumpTiles(tester, policy: TlsPolicy.none);
    expect(notice, findsNothing);

    await pumpTiles(
      tester,
      policy: const TlsPolicy(fragment: false),
      inherited: const TlsPolicy(fragment: true, recordFragment: false),
      inheritedLevel: TlsLevel.folder,
    );
    expect(notice, findsNothing);
  });
}
