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

  group('service client in VpnPlugin (745)', () {
    test('CoreSession.client is allowed only on an openconnect line', () {
      expect(
        vpnPluginServiceClientUse(
          'private fun openConnectControl(): OpenConnectControl? = '
          'CoreSession.client',
        ),
        isNull,
      );
      expect(
        vpnPluginServiceClientUse('val cc = CoreSession.client'),
        isNotNull,
      );
      expect(
        vpnPluginServiceClientUse('CoreSession.client?.taildropDelete(t, n)'),
        isNotNull,
      );
    });

    test('UiCoreSession and CoreSession.isUp are not the service client', () {
      expect(
        vpnPluginServiceClientUse('val cc = UiCoreSession.client'),
        isNull,
      );
      expect(vpnPluginServiceClientUse('UiCoreSession.ensure()'), isNull);
      expect(vpnPluginServiceClientUse('if (CoreSession.isUp) {'), isNull);
    });

    test('the ServiceCommandClient type is not allowed at all', () {
      expect(
        vpnPluginServiceClientUse(
          'fun openConnectHelper(cc: ServiceCommandClient) {}',
        ),
        isNotNull,
      );
    });

    test('a comment does not hide or cause a violation', () {
      final code = stripComments([
        'val cc = CoreSession.client // openconnect',
        '// CoreSession.client',
      ]);
      expect(vpnPluginServiceClientUse(code[0]), isNotNull);
      expect(vpnPluginServiceClientUse(code[1]), isNull);
    });
  });

  group('UiSinks members (745)', () {
    test('every member on the line is listed', () {
      expect(uiSinksMembers('if (UiSinks.coreLogSink == null) return'), [
        'coreLogSink',
      ]);
      expect(uiSinksMembers('UiSinks.ccStatusSink = UiSinks.ccGroupsSink'), [
        'ccStatusSink',
        'ccGroupsSink',
      ]);
      expect(uiSinksMembers('object UiSinks {'), isEmpty);
      expect(uiSinksMembers('MyUiSinks.x'), isEmpty);
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
