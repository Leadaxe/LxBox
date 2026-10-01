// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/builder/core_chain_capability.dart'
    show kCoreBuildTags;
import 'package:lxbox/services/contract/body_sanitizer.dart';
import 'package:lxbox/services/contract/node_core_gate.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

/// §586 — перечень типов endpoint берётся из реестра (`kind` записи
/// протокола); `openvpn-client` — тип реестра без описания полей
/// (`fields_unchecked`): принимается из любого источника, без предупреждений,
/// тело как написано, в конфиге — `endpoints[]`.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

void main() {
  late Directory tempDir;

  setUpAll(loadEngineSections);

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('endpoint_types_');
    await Directory('${tempDir.path}/docs').create();
    await Directory('${tempDir.path}/support').create();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    SettingsStorage.resetCacheForTesting();
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } on FileSystemException {
      // Файлы кэша могут быть ещё открыты — не мешает тесту.
    }
  });

  // Учётка и адрес — заглушки.
  const body = '''
{
  "type": "openvpn-client",
  "tag": "ovpn",
  "mode": "tls",
  "network": "udp",
  "servers": [{"server": "vpn.example.com", "server_port": 1194}],
  "username": "user",
  "password": "pass",
  "tls": {"enabled": true, "server_name": "vpn.example.com"},
  "x_future_key": 1
}''';

  Map<String, dynamic> expectedBody() =>
      Map<String, dynamic>.from(jsonDecode(body) as Map)..remove('tag');

  void expectVerbatimEndpoint(NodeSpec node) {
    expect(node, isA<UnknownTypeSpec>());
    expect(node.protocol, 'openvpn-client');
    expect(node.warnings, isEmpty);
    final entry = node.emitRaw(TemplateVars.empty);
    expect(entry, isA<Endpoint>());
    final map = entry.map;
    final want = expectedBody();
    for (final k in want.keys) {
      expect(map[k], want[k], reason: k);
    }
  }

  test('реестр: kind задаёт раздел конфига', () {
    final reg = ContractRegistry.I;
    expect(reg.isEndpointType('openvpn-client'), isTrue);
    expect(reg.isEndpointType('wireguard'), isTrue);
    expect(reg.isEndpointType('tailscale'), isTrue);
    expect(reg.isEndpointType('vless'), isFalse);
    expect(reg.isEndpointType('future-proto'), isFalse);
    expect(reg.isUncheckedType('openvpn-client'), isTrue);
    expect(reg.isUncheckedType('vless'), isFalse);
  });

  test('своя запись: узел без предупреждений, в конфиге — endpoints',
      () async {
    final c = SubscriptionController();
    await c.addFromInput(body);
    expect(c.lastError, isNull);
    final list = c.entries.single.list as UserServer;
    expect(sourceKindOf(list.rawBody), 'singbox_outbound');
    final node = list.nodes.single;
    expect(node.warnings.whereType<UnknownNodeTypeWarning>(), isEmpty);
    expectVerbatimEndpoint(node);
  });

  test('документ со смесью типов: оба узла, openvpn-client без предупреждений',
      () {
    const doc = '{"outbounds": [{"type": "trojan", "tag": "t",'
        ' "server": "b.example.com", "server_port": 443, "password": "pass"}],'
        ' "endpoints": [$body]}';
    final nodes = parseAll(decode(doc), own: true);
    expect(nodes, hasLength(2));
    expect(nodes.whereType<TrojanSpec>(), hasLength(1));
    expectVerbatimEndpoint(nodes.whereType<UnknownTypeSpec>().single);
  });

  test('подписка: узел создаётся, тело как написано', () {
    final dropped = <NodeWarning>[];
    final nodes = parseAll(decode('{"endpoints": [$body]}'), dropped: dropped);
    expect(dropped, isEmpty);
    expectVerbatimEndpoint(nodes.single);
  });

  test('санитайзер сборки тело не трогает и кодов не даёт', () {
    final map = expectedBody();
    final res = RegistrySanitizer.sanitize(map,
        scheme: 'openvpn-client', coreVersion: '1.14.2-lx.6');
    expect(res.warnings, isEmpty);
    expect(res.body, map);
  });

  test('гейт ядра: без with_openvpn — снят кодом, с тегом — годен', () {
    final b = expectedBody();
    final r = nodeCoreRefusal(
        'openvpn-client', b, const CoreInfo(tags: {'with_quic'}));
    expect(r?.code, 'openvpn_core_unsupported');
    expect(
        nodeCoreRefusal('openvpn-client', b, const CoreInfo(tags: kCoreBuildTags)),
        isNull);
  });

  test('тип вне реестра по-прежнему: предупреждение, outbounds', () {
    const raw = '{"type": "future-proto", "tag": "f",'
        ' "server": "vpn.example.com", "server_port": 1}';
    final node = parseAll(decode(raw), own: true).single;
    expect(node.warnings.whereType<UnknownNodeTypeWarning>(), hasLength(1));
    expect(node.emitRaw(TemplateVars.empty), isA<Outbound>());
  });
}
