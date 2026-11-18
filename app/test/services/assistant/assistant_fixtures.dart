// §750 — общие узлы и источники для тестов ассистента.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';

WireguardSpec wgNode(String tag, {bool awg = false}) => WireguardSpec(
      id: 'id-$tag',
      tag: tag,
      label: tag,
      server: '192.0.2.1',
      port: 51820,
      rawSource: '',
      privateKey: 'cHJpdmF0ZUtleUJhc2U2NA==',
      localAddresses: const ['10.2.0.2/32'],
      peers: const [
        WireguardPeer(
          publicKey: 'cHVibGljS2V5QmFzZTY0',
          endpointHost: '192.0.2.1',
          endpointPort: 51820,
        ),
      ],
      awg: awg ? const Awg({'jc': 4}) : null,
    );

UnknownTypeSpec unknownNode(String tag, String type) => UnknownTypeSpec(
      id: 'id-$tag',
      tag: tag,
      label: tag,
      type: type,
      body: {'type': type},
    );

TailscaleSpec tsNode(String tag) =>
    TailscaleSpec(id: 'id-$tag', tag: tag, label: tag);

UserServer userServer(String id, NodeSpec node, {bool enabled = true}) =>
    UserServer(
      id: id,
      name: '',
      enabled: enabled,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      nodes: [node],
    );

FolderServers folder(String id, String name, List<FolderMember> members,
        {bool enabled = true, String tagPrefix = ''}) =>
    FolderServers(
      id: id,
      name: name,
      enabled: enabled,
      tagPrefix: tagPrefix,
      detourPolicy: DetourPolicy.defaults,
      members: members,
    );

FolderMember member(NodeSpec node, {bool enabled = true}) =>
    FolderMember(raw: 'x', node: node, enabled: enabled);

SubscriptionServers subscription(String id, List<NodeSpec> nodes,
        {String tagPrefix = 'Sub',
        Map<String, DateTime> disabled = const {},
        bool enabled = true}) =>
    SubscriptionServers(
      id: id,
      name: 'Sub $id',
      enabled: enabled,
      tagPrefix: tagPrefix,
      detourPolicy: DetourPolicy.defaults,
      url: 'https://example.com/$id',
      nodes: nodes,
      disabledHashes: disabled,
    );

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.tempRoot);
  final String tempRoot;
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

/// Реальный SettingsStorage во временном каталоге (как в
/// directions_handler_test). Снимается через addTearDown.
Future<void> setUpTempStorage() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = await Directory.systemTemp.createTemp('assistant_');
  await Directory('${dir.path}/docs').create();
  await Directory('${dir.path}/support').create();
  final prev = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  SettingsStorage.resetCacheForTesting();
  addTearDown(() async {
    PathProviderPlatform.instance = prev;
    SettingsStorage.resetCacheForTesting();
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });
}
