import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/template_loader.dart';

import '../parser/engine_test_setup.dart';

/// §691 — «Bypass the tunnel»: var `tun_route_exclude` доходит до
/// `tun.route_exclude_address`; пустое — ключа нет; адрес TUN снимается.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WizardTemplate template;

  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('lxbox_tunexcl_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => tmp.path);
    await loadEngineSections();
    TemplateLoader.invalidate();
    template = await TemplateLoader.load();
  });

  Future<({Map<String, dynamic> tun, List<String> warnings})> build(
      Map<String, String> vars) async {
    final res = await buildConfig(
      lists: const [],
      template: template,
      settings: BuildSettings(userVars: vars),
    );
    final tun = (res.config['inbounds'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((i) => i['type'] == 'tun');
    return (tun: tun, warnings: res.emitWarnings);
  }

  test('шаблон объявляет переменную', () {
    final v = template.vars.firstWhere((v) => v.name == 'tun_route_exclude');
    expect(v.type, 'text_list');
    expect(v.defaultValue, '');
    expect(v.optionValues, contains('192.168.0.0/16'));
  });

  test('пусто — ключа нет', () async {
    final r = await build(const {});
    expect(r.tun.containsKey('route_exclude_address'), isFalse);
  });

  test('список строк — в route_exclude_address, адрес TUN снят', () async {
    final r = await build(const {
      'tun_route_exclude': '192.168.0.0/16\nfd12:3456::/48\n172.16.0.0/12',
    });
    expect(r.tun['route_exclude_address'], ['192.168.0.0/16', 'fd12:3456::/48']);
    expect(r.warnings.where((w) => w.contains('172.16.0.0/12')), hasLength(1));
  });
}
