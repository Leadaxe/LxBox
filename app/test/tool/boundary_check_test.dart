import 'package:flutter_test/flutter_test.dart';

// §742 C — self-test чистых функций разбора сторожа границ
// (tool/arch/src/boundary_scan.dart).

import '../../tool/arch/src/boundary_scan.dart';

void main() {
  group('layer of import', () {
    test('relative and package paths resolve to the same layer', () {
      expect(
        layerOf(resolveImport('lib/services/a.dart', '../screens/x.dart')),
        'screens',
      );
      expect(
        layerOf(
          resolveImport(
            'lib/services/debug/h/t.dart',
            '../../../screens/n/s.dart',
          ),
        ),
        'screens',
      );
      expect(
        layerOf(
          resolveImport('lib/vpn/a.dart', 'package:lxbox/widgets/w.dart'),
        ),
        'widgets',
      );
      expect(layerOf(resolveImport('lib/vpn/a.dart', 'b.dart')), 'vpn');
      expect(layerOf('lib/main.dart'), isNull);
      expect(resolveImport('lib/vpn/a.dart', 'dart:io'), isNull);
      expect(
        resolveImport('lib/vpn/a.dart', 'package:flutter/material.dart'),
        isNull,
      );
    });

    test('import/export/part lines are parsed, others are not', () {
      expect(importTarget("import '../a.dart' as a;"), '../a.dart');
      expect(
        importTarget('export "package:lxbox/x.dart";'),
        'package:lxbox/x.dart',
      );
      expect(importTarget("part 'x.g.dart';"), 'x.g.dart');
      expect(importTarget("final s = 'import x';"), isNull);
    });
  });

  group('channel literal', () {
    bool lit(List<String> l) => isChannelLiteral(stripComments(l), 0);

    test('literal name is a violation', () {
      expect(lit(["const MethodChannel('com.leadaxe.lxbox/vpn')"]), isTrue);
      expect(lit(['EventChannel("x")']), isTrue);
      expect(lit(['EventChannel(', "  'x/y',", ')']), isTrue);
    });

    test('constants and interpolation are not', () {
      expect(lit(['MethodChannel(PlatformChannels.methods)']), isFalse);
      expect(lit([r"MethodChannel('${PlatformChannels.p}$viewId')"]), isFalse);
      expect(
        lit(['EventChannel(', '  PlatformChannels.coreLog,', ')']),
        isFalse,
      );
    });
  });

  group('service side in a window-side file (747)', () {
    test('service-side objects are violations', () {
      expect(uiServiceSideUse('val cc = CoreSession.client'), isNotNull);
      expect(uiServiceSideUse('if (CoreSession.isUp) {'), isNotNull);
      expect(uiServiceSideUse('BootReceiver.hasTun(context)'), isNotNull);
      expect(uiServiceSideUse('NativeCache.isVpnDesired(ctx)'), isNotNull);
      expect(uiServiceSideUse('AutomationCache.prefs(context)'), isNotNull);
      expect(uiServiceSideUse('ConfigManager.load()'), isNotNull);
      expect(uiServiceSideUse('BoxService.coreLogsVerbose = true'), isNotNull);
      expect(uiServiceSideUse('BgMethods.handle(ctx, m, a)'), isNotNull);
      expect(
        uiServiceSideUse('fun helper(cc: ServiceCommandClient) {}'),
        isNotNull,
      );
      expect(
        uiServiceSideUse('Taildrop.send(ctx, tag, id, n, items)'),
        isNotNull,
      );
      expect(uiServiceSideUse('TaildropClip.state(context)'), isNotNull);
      expect(uiServiceSideUse('TaildropServiceFiles.stats()'), isNotNull);
    });

    test('window-side names that only look similar are not', () {
      expect(uiServiceSideUse('val cc = MyCoreSession.client'), isNull);
      expect(uiServiceSideUse('ConfigFile.write(context, config)'), isNull);
      expect(
        uiServiceSideUse('BgClient.forward(ctx, "taildropSave", a, r)'),
        isNull,
      );
      // Типы libbox, которыми пользуется клиент ядра окна.
      expect(
        uiServiceSideUse('import io.nekohasekai.libbox.TaildropInbox'),
        isNull,
      );
      expect(
        uiServiceSideUse(
          'val sub = AtomicReference<TaildropInboxSubscription?>(null)',
        ),
        isNull,
      );
      expect(uiServiceSideUse('"ccTaildropSave" -> {'), isNull);
    });

    test('BoxVpnService gives constants only', () {
      expect(
        uiServiceSideUse('IntentFilter(BoxVpnService.BROADCAST_STATUS)'),
        isNull,
      );
      expect(
        uiServiceSideUse('intent.getStringExtra(BoxVpnService.EXTRA_STATUS)'),
        isNull,
      );
      expect(uiServiceSideUse('BoxVpnService.start(context)'), isNotNull);
      expect(uiServiceSideUse('BoxVpnService.stopAwait(context)'), isNotNull);
      expect(uiServiceSideUse('if (BoxVpnService.live != null) {'), isNotNull);
      expect(
        uiServiceSideUse('Intent(context, BoxVpnService::class.java)'),
        isNotNull,
      );
      expect(
        uiServiceSideUse(
          'f(BoxVpnService.EXTRA_STATUS); BoxVpnService.reload(context)',
        ),
        isNotNull,
      );
    });

    test('a comment does not hide or cause a violation', () {
      final code = stripComments([
        'val cc = CoreSession.client // BgClient',
        '// CoreSession.client',
      ]);
      expect(uiServiceSideUse(code[0]), isNotNull);
      expect(uiServiceSideUse(code[1]), isNull);
    });
  });

  group('manifest processes (747)', () {
    test('every component needs :ui or :bg', () {
      const xml = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <application android:name=".App">
    <activity
        android:name=".MainActivity"
        android:process=":ui"
        android:exported="true">
      <intent-filter><action android:name="android.intent.action.MAIN"/></intent-filter>
    </activity>
    <service android:name=".Svc" android:process=":bg" />
    <receiver android:name=".NoProcess" android:exported="false" />
    <provider
        android:name=".Wrong"
        android:process=":other"
        android:authorities="x" />
    <activity-alias android:name=".Alias" android:targetActivity=".MainActivity" />
  </application>
</manifest>
''';
      final v = manifestProcessViolations(xml);
      expect(v, hasLength(2));
      expect(v[0], contains('.NoProcess'));
      expect(v[0], contains('нет android:process'));
      expect(v[1], contains('.Wrong'));
      expect(v[1], contains(':other'));
    });

    test('a commented-out component and an alias are not counted', () {
      const xml = '''
<application>
  <!-- <service android:name=".Old" /> -->
  <activity-alias android:name=".A" android:targetActivity=".M" />
  <service android:name=".S" android:process=":bg" />
</application>
''';
      expect(manifestProcessViolations(xml), isEmpty);
    });
  });

  group('no core in the window process (747)', () {
    test('libbox imports, Libbox calls and ensureLibbox are violations', () {
      expect(
        uiCoreUse('import io.nekohasekai.libbox.CommandClient'),
        isNotNull,
      );
      expect(uiCoreUse('import io.nekohasekai.libbox.*'), isNotNull);
      expect(
        uiCoreUse('result.success(io.nekohasekai.libbox.Libbox.version())'),
        isNotNull,
      );
      expect(uiCoreUse('val v = Libbox.checkConfig(text)'), isNotNull);
      expect(uiCoreUse('BoxApplication.ensureLibbox()'), isNotNull);
    });

    test('ordinary window code is not', () {
      expect(uiCoreUse('toBg(call, result, long = true)'), isNull);
      expect(uiCoreUse('"getCoreVersion", "checkConfig" -> forward()'), isNull);
      expect(uiCoreUse('val myLibbox = 1'), isNull);
      final code = stripComments(['// Libbox.setup is never called here']);
      expect(uiCoreUse(code[0]), isNull);
    });

    test('the screen client and the probe are service-side names', () {
      expect(uiServiceSideUse('ScreenCoreSession.ensure()'), isNotNull);
      expect(uiServiceSideUse('val cc: BoxCommandClient? = null'), isNotNull);
      expect(uiServiceSideUse('StreamSinks.ccStatusSink = sink'), isNotNull);
      expect(uiServiceSideUse('ProbeSession.start(config)'), isNotNull);
      expect(uiServiceSideUse('PProfClient.fetch(path, 5000)'), isNotNull);
      expect(uiServiceSideUse('L10n.str(ctx, id)'), isNotNull);
      expect(uiServiceSideUse('UiHold.sync(context)'), isNotNull);
      expect(uiServiceSideUse('AssistantCore.overview(ctx, index)'), isNotNull);
      expect(uiServiceSideUse('AssistantBridge.call(ctx, m, p, b)'), isNotNull);
      expect(uiServiceSideUse('UiCalls.onAck(id)'), isNotNull);
    });
  });

  group('comments', () {
    test('comment lines and trailing comments are dropped, lines kept', () {
      final out = stripComments([
        '/// MethodChannel("x")',
        '// BoxService.commandClient',
        ' * VpnPlugin',
        '/** doc',
        ' VpnPlugin */ val a = 1 // VpnPlugin',
        "val u = 'http://x' // c",
      ]);
      expect(out.length, 6);
      expect(out[0].trim(), isEmpty);
      expect(out[1].trim(), isEmpty);
      expect(out[3].trim(), isEmpty);
      expect(out[4].contains('VpnPlugin'), isFalse);
      expect(out[4].contains('val a = 1'), isTrue);
      expect(out[5].contains('http://x'), isTrue);
    });
  });
}
