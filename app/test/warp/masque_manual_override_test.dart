// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/warp/masque_account.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../contract_paths.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

/// §015-P11 — ручной override MASQUE IP:port из визарда уходит только в узел,
/// кеш (`masque_account`) держит канонический server/port регистрации.
/// Пустое поле IP в визарде = сервер из регистрации (не тестируется здесь,
/// это ветка без override — см. `hasServerOverride` в addMasque).
///
/// `reuse: true` (дефолт) + уже закешированный аккаунт → addMasque НЕ идёт
/// в сеть (registerMasque не вызывается), что и позволяет проверить кеш без
/// мока WarpClient.
void main() {
  late Directory tempDir;

  setUpAll(() async {
    await loadTestRegistry();
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('masque_override_');
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

  // Реальные DER-значения из test/parser/masque_pipeline_invariants_test.dart
  // (`_warpAccount`) — нужны, чтобы `toMasqueUri` → `parseLinkViaPipeline`
  // прошли без RegistryWarning.invalidMasqueConfig.
  const cached = MasqueAccount(
    privKeyDer: 'MHcCAQEEIB5oxGzgOdLvTY2aAbRsyJslxnlvPpOzLR076h3cgsnc'
        'oAoGCCqGSM49AwEHoUQDQgAEDQBTbtpEikpJDklVHdnMhgIR8YatYDJLUILDQWGd'
        'wBbqaLiKKiuawVQz6MIaHr0I/4mNM/TfUUnoENKv9qZEWw==',
    serverPubDer: 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEDQBTbtpEikpJDklVHd'
        'nMhgIR8YatYDJLUILDQWGdwBbqaLiKKiuawVQz6MIaHr0I/4mNM/TfUUnoENKv9q'
        'ZEWw==',
    clientV4: '172.16.0.2/32',
    clientV6: '2606:4700:110:8a1b:c0de:cafe:babe:1234/128',
    server: '162.159.198.1',
    port: 443,
    deviceId: 'dev123',
    token: 'secret-token',
    createdAt: '2026-07-02T00:00:00Z',
  );

  test('manual IP:port override не попадает в кеш аккаунта', () async {
    await SettingsStorage.setMasqueAccount(cached);

    final c = SubscriptionController();
    final account = await c.addMasque(
      server: '203.0.113.9',
      port: 4433,
    );

    expect(c.lastError, isNull);
    expect(account, isNotNull);
    // Возвращённый объект (идёт в узел) несёт override.
    expect(account!.server, '203.0.113.9');
    expect(account.port, 4433);

    // Кеш — канонический server/port регистрации, БЕЗ override.
    final persisted = await SettingsStorage.getMasqueAccount();
    expect(persisted, isNotNull);
    expect(persisted!.server, cached.server);
    expect(persisted.port, cached.port);
  });
}
