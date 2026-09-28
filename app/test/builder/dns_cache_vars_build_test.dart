import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/template_loader.dart';

import '../parser/engine_test_setup.dart';

/// §580 — кэш DNS: три переменные шаблона (TEMPLATE_LANG §6.8) доходят до
/// `dns.cache_capacity`, `dns.optimistic`, `experimental.cache_file.store_dns`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WizardTemplate template;

  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('lxbox_dnscache_');
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

  ({Object? capacity, Object? optimistic, Object? storeDns}) cacheOf(
      Map<String, dynamic> config) {
    final dns = config['dns'] as Map;
    final cacheFile =
        ((config['experimental'] as Map)['cache_file'] as Map);
    return (
      capacity: dns['cache_capacity'],
      optimistic: dns['optimistic'],
      storeDns: cacheFile['store_dns'],
    );
  }

  test('шаблон объявляет три переменные с нормой контракта', () {
    final byName = {for (final v in template.vars) v.name: v};
    expect(byName['dns_cache_capacity']?.type, 'int');
    expect(byName['dns_cache_capacity']?.defaultValue, '4000');
    expect(byName['dns_optimistic']?.type, 'bool');
    expect(byName['dns_optimistic']?.defaultValue, 'true');
    expect(byName['dns_store_cache']?.type, 'bool');
    expect(byName['dns_store_cache']?.defaultValue, 'true');
  });

  test('состояние без переменных — значения по умолчанию', () async {
    final c = cacheOf(await build(const {}));
    expect(c.capacity, 4000);
    expect(c.optimistic, true);
    expect(c.storeDns, true);
  });

  test('изменённые значения попадают в конфиг', () async {
    final c = cacheOf(await build(const {
      'dns_cache_capacity': '8192',
      'dns_optimistic': 'false',
      'dns_store_cache': 'false',
    }));
    expect(c.capacity, 8192);
    expect(c.optimistic, false);
    expect(c.storeDns, false);
  });

  test('границы включительно', () async {
    expect(cacheOf(await build(const {'dns_cache_capacity': '1024'})).capacity,
        1024);
    expect(
        cacheOf(await build(const {'dns_cache_capacity': '65535'})).capacity,
        65535);
  });

  for (final bad in const ['1023', '65536', '0', '-5', 'abc']) {
    test('вне границ ($bad) не попадает в конфиг — действует 4000', () async {
      final c = cacheOf(await build({'dns_cache_capacity': bad}));
      expect(c.capacity, 4000);
    });
  }

  test('varIntInBounds', () {
    expect(varIntInBounds('dns_cache_capacity', '1024'), isTrue);
    expect(varIntInBounds('dns_cache_capacity', ' 65535 '), isTrue);
    expect(varIntInBounds('dns_cache_capacity', '1023'), isFalse);
    expect(varIntInBounds('dns_cache_capacity', ''), isFalse);
    expect(varIntInBounds('tun_mtu', '99999'), isTrue);
  });
}
