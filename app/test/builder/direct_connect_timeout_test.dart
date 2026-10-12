import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/template_loader.dart';

import '../parser/engine_test_setup.dart';

/// §616 — `connect_timeout` у `direct-out` из переменной шаблона
/// `direct_connect_timeout` (секция `network`, дефолт 15s вместо 5s ядра).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WizardTemplate template;

  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('lxbox_direct_ct_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => tmp.path);
    await loadEngineSections();
    TemplateLoader.invalidate();
    template = await TemplateLoader.load();
  });

  Future<Map<String, dynamic>> build(Map<String, String> vars) async {
    final res = await buildConfig(
      lists: const [],
      template: template,
      settings: BuildSettings(userVars: vars),
    );
    return res.config;
  }

  Map directOut(Map<String, dynamic> config) => (config['outbounds'] as List)
      .cast<Map>()
      .singleWhere((o) => o['tag'] == 'direct-out');

  test('шаблон: переменная в секции network, дефолт 15s, пресеты', () {
    final v = template.vars.singleWhere((v) => v.name == 'direct_connect_timeout');
    final network = template.varSections.singleWhere((s) => s.id == 'network');
    expect(v.section, network.title);
    expect(v.type, 'text');
    expect(v.optionsOpen, isTrue);
    expect(v.defaultValue, '15s');
    expect(v.options.map((o) => o.value).toList(),
        ['5s', '15s', '20s', '25s', '30s', '45s', '1m', '2m']);
  });

  test('дефолт: direct-out.connect_timeout == 15s', () async {
    expect(directOut(await build(const {}))['connect_timeout'], '15s');
  });

  test('переопределение: 2m доходит до direct-out', () async {
    final c = await build(const {'direct_connect_timeout': '2m'});
    expect(directOut(c)['connect_timeout'], '2m');
  });

  test('значение вне пресетов (options_open) проходит как есть', () async {
    final c = await build(const {'direct_connect_timeout': '1m30s'});
    expect(directOut(c)['connect_timeout'], '1m30s');
  });

  test('прочие outbound-ы поле не получают', () async {
    final c = await build(const {});
    for (final o in (c['outbounds'] as List).cast<Map>()) {
      if (o['tag'] == 'direct-out') continue;
      expect(o.containsKey('connect_timeout'), isFalse, reason: '${o['tag']}');
    }
  });
}
