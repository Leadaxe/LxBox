import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/vpn_settings/vpn_settings_facade.dart';

/// §293 — VpnSettingsFacade.applyVpnMode: три инварианта, которые раньше нёс
/// только UI, а Debug пропускал (реальная дивергенция stale has_tun).
void main() {
  late Directory tmp;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const methodsChannel = MethodChannel('com.leadaxe.lxbox/methods');
  final hasTunCalls = <bool>[];

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_vpnfacade_');
    hasTunCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method.startsWith('getApplicationDocuments')) return tmp.path;
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodsChannel, (call) async {
      if (call.method == 'setHasTun') {
        hasTunCalls.add((call.arguments as Map)['enabled'] as bool);
        return true; // BoxVpnClient.setHasTun ожидает bool-ответ
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
    // База: vpn-режим (hasTun=true).
    await SettingsStorage.setVpnMode(const VpnModeConfig.defaults());
    hasTunCalls.clear(); // сбросить шум базового setup
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodsChannel, null);
  });

  test('mode → proxy: зеркалит setHasTun(false) (ЧИНИТ дивергенцию Debug)', () async {
    // vpn (hasTun=true) → proxy (hasTun=false): native has_tun обязан флипнуть.
    final result = await VpnSettingsFacade.applyVpnMode(
        const VpnModeConfig.defaults().copyWith(mode: 'proxy'));
    expect(result.mode, 'proxy');
    expect(hasTunCalls, [false]); // раньше Debug этого НЕ делал
  });

  test('mode не сменился: setHasTun НЕ зовётся', () async {
    // vpn→vpn: hasTun не меняется → без native-пуша.
    await VpnSettingsFacade.applyVpnMode(
        const VpnModeConfig.defaults().copyWith(proxyPort: 3000));
    expect(hasTunCalls, isEmpty);
  });

  test('proxy→vpn: setHasTun(true)', () async {
    await SettingsStorage.setVpnMode(
        const VpnModeConfig.defaults().copyWith(mode: 'proxy'));
    hasTunCalls.clear();
    await VpnSettingsFacade.applyVpnMode(
        const VpnModeConfig.defaults().copyWith(mode: 'vpn'));
    expect(hasTunCalls, [true]);
  });

  test('auth-on + пустой пароль (proxy) → генерит пароль', () async {
    final result = await VpnSettingsFacade.applyVpnMode(
      const VpnModeConfig.defaults().copyWith(
        mode: 'proxy',
        proxyAuthEnabled: true,
        proxyPassword: '',
      ),
    );
    expect(result.proxyPassword, isNotEmpty);
    // Персистнулся с паролем.
    final saved = await SettingsStorage.getVpnMode();
    expect(saved.proxyPassword, result.proxyPassword);
  });

  test('пароль уже задан → НЕ перегенеривается', () async {
    final result = await VpnSettingsFacade.applyVpnMode(
      const VpnModeConfig.defaults().copyWith(
        mode: 'proxy',
        proxyAuthEnabled: true,
        proxyPassword: 'my-secret',
      ),
    );
    expect(result.proxyPassword, 'my-secret');
  });

  test('non-loopback listen форсит effectiveAuth → пароль генерится', () async {
    final result = await VpnSettingsFacade.applyVpnMode(
      const VpnModeConfig.defaults().copyWith(
        mode: 'proxy',
        proxyListen: '0.0.0.0',
        proxyAuthEnabled: false, // но effectiveAuth форсит on
        proxyPassword: '',
      ),
    );
    expect(result.proxyPassword, isNotEmpty);
  });

  test('loadVpnMode passthrough', () async {
    await SettingsStorage.setVpnMode(
        const VpnModeConfig.defaults().copyWith(proxyPort: 4321));
    final loaded = await VpnSettingsFacade.loadVpnMode();
    expect(loaded.proxyPort, 4321);
  });
}
