import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/template_loader.dart';

import '../parser/engine_test_setup.dart';

/// §606 — 016-DPI_HARDENING P17: переменная шаблона `certificate_store`
/// доходит до `certificate.store` итогового конфига; умолчание — `system`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WizardTemplate template;

  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('lxbox_certstore_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => tmp.path);
    await loadEngineSections();
    TemplateLoader.invalidate();
    template = await TemplateLoader.load();
  });

  Future<Object?> storeOf(Map<String, String> vars) async {
    final res = await buildConfig(
      lists: const [],
      template: template,
      settings: BuildSettings(userVars: vars),
    );
    return (res.config['certificate'] as Map?)?['store'];
  }

  test('шаблон объявляет certificate_store с умолчанием system', () {
    final v = template.vars.firstWhere((v) => v.name == 'certificate_store');
    expect(v.defaultValue, 'system');
  });

  test('без переменной — system', () async {
    expect(await storeOf(const {}), 'system');
  });

  test('mozilla и chrome попадают в certificate.store', () async {
    expect(await storeOf(const {'certificate_store': 'mozilla'}), 'mozilla');
    expect(await storeOf(const {'certificate_store': 'chrome'}), 'chrome');
  });
}
