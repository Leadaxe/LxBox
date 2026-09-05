import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/settings_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lxbox_tun_direct_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => tmp.path);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    SettingsStorage.resetCacheForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    await tmp.delete(recursive: true);
  });

  Future<BuildResult> build(String appsMode, String vpnMode) => buildConfig(
    lists: [],
    template: WizardTemplate.fromJson(
      jsonDecode(File('assets/wizard_template.json').readAsStringSync())
          as Map<String, dynamic>,
    ),
    settings: BuildSettings(
      tunApps: TunAppsConfig(mode: appsMode, packages: ['com.example']),
      vpnMode: const VpnModeConfig.defaults().copyWith(mode: vpnMode),
      routeFinal: 'direct-out',
      customRules: [
        CustomRuleInline(
          name: 'Reject selected app',
          packages: ['com.example'],
          outbound: kOutboundReject,
        ),
      ],
    ),
  );

  for (final vpnMode in ['vpn', 'vpn_proxy', 'proxy']) {
    test(
      'full builder ($vpnMode): direct after DNS, then switch back',
      () async {
        final direct = await build('direct', vpnMode);
        expect(
          direct.validation.isOk,
          isTrue,
          reason: direct.validation.issues.join('\n'),
        );
        final rules = (direct.config['route']['rules'] as List).cast<Map>();
        final bypass = rules.where((r) => r['package_name'] != null).toList();
        final tuns = (direct.config['inbounds'] as List).cast<Map>().where(
          (i) => i['type'] == 'tun',
        );
        if (vpnMode == 'proxy') {
          expect(tuns, isEmpty);
          expect(bypass, isEmpty);
        } else {
          expect(tuns.single.containsKey('include_package'), isFalse);
          expect(tuns.single.containsKey('exclude_package'), isFalse);
          expect(bypass.single['outbound'], 'direct-out');
          expect(bypass.single['inbound'], [tuns.single['tag']]);
          final directIndex = rules.indexOf(bypass.single);
          expect(
            rules.indexWhere((r) => r['action'] == 'hijack-dns'),
            allOf(greaterThanOrEqualTo(0), lessThan(directIndex)),
          );
          expect(
            rules.indexWhere((r) => r['action'] == 'reject'),
            greaterThan(directIndex),
          );
        }

        for (final mode in ['off', 'deny']) {
          final next = await build(mode, vpnMode);
          expect(
            next.validation.isOk,
            isTrue,
            reason: next.validation.issues.join('\n'),
          );
          expect(
            (next.config['route']['rules'] as List).where(
              (r) => (r as Map).containsKey('package_name'),
            ),
            isEmpty,
          );
          expect(next.config['dns'], direct.config['dns']);
          if (vpnMode != 'proxy') {
            final tun =
                (next.config['inbounds'] as List).firstWhere(
                      (i) => i['type'] == 'tun',
                    )
                    as Map;
            expect(
              tun['exclude_package'],
              mode == 'deny' ? ['com.example'] : null,
            );
          }
        }
      },
    );
  }
}
