import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/parser_config.dart';
import 'package:lxbox/services/builder/build_config.dart';
import 'package:lxbox/services/settings_storage.dart' show VpnModeConfig;
import 'package:lxbox/services/template_loader.dart';

import '../parser/engine_test_setup.dart';

/// §629 — системный HTTP-прокси VPN-сети: настоящий шаблон через настоящий
/// buildConfig. Тумблер даёт скрытый `sysproxy-in` (http, loopback, без users)
/// и `platform.http_proxy` у `tun-in`; без TUN или выключенный — ничего.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WizardTemplate template;

  setUpAll(() async {
    final tmp = await Directory.systemTemp.createTemp('lxbox_sysproxy_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => tmp.path);
    await loadEngineSections();
    TemplateLoader.invalidate();
    template = await TemplateLoader.load();
  });

  Future<List<Map<String, dynamic>>> inbounds(VpnModeConfig m) async {
    final res = await buildConfig(
      lists: const [],
      template: template,
      settings: BuildSettings(vpnMode: m),
    );
    return (res.config['inbounds'] as List).cast<Map<String, dynamic>>();
  }

  Map<String, dynamic>? byTag(List<Map<String, dynamic>> inb, String tag) =>
      inb.where((i) => i['tag'] == tag).firstOrNull;

  const base = VpnModeConfig(
    mode: 'vpn',
    proxyProtocol: 'mixed',
    proxyPort: 2080,
    proxyListen: '127.0.0.1',
    proxyAuthEnabled: true,
    proxyUsername: 'user',
    proxyPassword: 'deadbeef',
  );

  test('по умолчанию выключено', () {
    expect(const VpnModeConfig.defaults().systemProxyEnabled, isFalse);
    expect(base.systemProxyEnabled, isFalse);
  });

  test('vpn + вкл → sysproxy-in и platform.http_proxy у tun-in', () async {
    final inb = await inbounds(base.copyWith(systemProxyEnabled: true));
    final sys = byTag(inb, 'sysproxy-in');
    expect(sys, isNotNull);
    expect(sys!['type'], 'http');
    expect(sys['listen'], '127.0.0.1');
    expect(sys['listen_port'], 2081);
    expect(sys.containsKey('users'), isFalse);

    final tun = byTag(inb, 'tun-in')!;
    final hp = (tun['platform'] as Map)['http_proxy'] as Map;
    expect(hp['enabled'], true);
    expect(hp['server'], '127.0.0.1');
    expect(hp['server_port'], 2081);
    expect(hp['server_port'], isA<int>());
  });

  test('vpn + выкл → ни инбаунда, ни platform', () async {
    final inb = await inbounds(base);
    expect(byTag(inb, 'sysproxy-in'), isNull);
    expect(byTag(inb, 'tun-in')!.containsKey('platform'), isFalse);
  });

  test('proxy + вкл → ни инбаунда, ни platform (нет TUN)', () async {
    final inb = await inbounds(
        base.copyWith(mode: 'proxy', systemProxyEnabled: true));
    expect(byTag(inb, 'sysproxy-in'), isNull);
    expect(byTag(inb, 'tun-in'), isNull);
    expect(byTag(inb, 'mixed-in'), isNotNull);
  });

  test('proxy_port=2081 → системный прокси на 2082', () async {
    final m = base.copyWith(
        mode: 'vpn_proxy', proxyPort: 2081, systemProxyEnabled: true);
    expect(m.effectiveSystemProxyPort, 2082);
    final inb = await inbounds(m);
    expect(byTag(inb, 'sysproxy-in')!['listen_port'], 2082);
    final tun = byTag(inb, 'tun-in')!;
    expect(((tun['platform'] as Map)['http_proxy'] as Map)['server_port'],
        2082);
    expect(byTag(inb, 'mixed-in')!['listen_port'], 2081);
  });

  test('mixed-in и его users не меняются', () async {
    final m = base.copyWith(mode: 'vpn_proxy');
    final off = byTag(await inbounds(m), 'mixed-in');
    final on =
        byTag(await inbounds(m.copyWith(systemProxyEnabled: true)), 'mixed-in');
    expect(on, off);
    expect(on!['users'], [
      {'username': 'user', 'password': 'deadbeef'},
    ]);
  });

  test('toJson/хранилище: ключ system_proxy_enabled', () {
    expect(base.copyWith(systemProxyEnabled: true).toJson()
        ['system_proxy_enabled'], true);
    expect(base.toJson()['system_proxy_enabled'], false);
  });
}
