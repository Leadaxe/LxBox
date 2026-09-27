// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/codec/source_record.dart';
import 'package:lxbox/models/emit_context.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/builder/rule_set_registry.dart';
import 'package:lxbox/services/builder/server_list_build.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/json_comments.dart';
import 'package:lxbox/services/parser/parse_all.dart';
import 'package:lxbox/services/probe/probe_config.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../parser/engine_test_setup.dart';

/// §585 — узел sing-box незнакомого приложению типа (`openvpn-client`)
/// принимается своей записью; тело уходит в ядро как написано.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationSupportPath() async => '$tempRoot/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$tempRoot/docs';
}

class _Ctx extends EmitContext {
  final entries = <SingboxEntry>[];
  final _seen = <String>{};

  @override
  TemplateVars get vars => TemplateVars.empty;

  @override
  String allocateTag(String baseTag) {
    var t = baseTag;
    var i = 1;
    while (!_seen.add(t)) {
      t = '$baseTag-${i++}';
    }
    return t;
  }

  @override
  void addEntry(SingboxEntry entry) => entries.add(entry);

  @override
  void warn(String line) {}

  @override
  void addToSelectorTagList(SingboxEntry entry) {}

  @override
  void addToAutoList(SingboxEntry entry) {}

  @override
  final RuleSetRegistry ruleSets =
      RuleSetRegistry(initialRuleSets: const [], initialRules: const []);
}

void main() {
  late Directory tempDir;
  setUpAll(loadEngineSections);

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('unknown_type_');
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

  // Учётка и адрес — заглушки, не данные владельца.
  const body = '''
{
  "type": "openvpn-client",
  "tag": "ovpn-out",
  "server": "vpn.example.org",
  "server_port": 443,
  "network": "udp",
  "username": "test-user",
  "password": "test-pass",
  "detour": "warp-out",
  "tls": { "certificate_path": "/sdcard/certs/x.crt" }
}''';

  const commented = '''
{
  "type": "openvpn-client",
  "tag": "ovpn-out",
  "server": "vpn.example.org", // United States Central
  /* block comment */
  "server_port": 443,
  "username": "test-user",
  "password": "https://not-a-comment"
}''';

  Map<String, dynamic> built(UserServer s) {
    final ctx = _Ctx();
    s.build(ctx);
    return ctx.entries.last.map;
  }

  test('вставка тела незнакомого типа: запись с голым телом, предупреждение',
      () async {
    final c = SubscriptionController();
    await c.addFromInput(body);
    expect(c.lastError, isNull);
    final list = c.entries.single.list as UserServer;
    expect(sourceKindOf(list.rawBody), 'singbox_outbound');
    final node = list.nodes.single;
    expect(node, isA<UnknownTypeSpec>());
    expect(node.protocol, 'openvpn-client');
    expect(node.warnings.whereType<UnknownNodeTypeWarning>(), hasLength(1));
    expect(node.warnings.whereType<UnknownNodeTypeWarning>().single.severity,
        WarningSeverity.info);
    // Знак по умолчанию дописан в тег, как у прочих узлов.
    expect(node.tag, isNot('ovpn-out'));
    expect(node.tag, endsWith('ovpn-out'));
  });

  test('в конфиге тело дословное, место — endpoints', () async {
    final c = SubscriptionController();
    await c.addFromInput(body);
    final list = c.entries.single.list as UserServer;
    final ctx = _Ctx();
    list.build(ctx);
    final entry = ctx.entries.last;
    expect(entry, isA<Endpoint>());
    final map = entry.map;
    final expected = Map<String, dynamic>.from(jsonDecode(body) as Map)
      ..remove('detour')
      ..remove('tag');
    for (final k in expected.keys) {
      expect(map[k], expected[k], reason: k);
    }
    expect(map.containsKey('detour'), isFalse);
  });

  test('незнакомый тип вне перечня endpoint-типов ядра — outbounds', () {
    const raw = '{"type": "future-proto", "tag": "f", "server": "h.example",'
        ' "server_port": 1, "x": {"y": 1}}';
    final s = UserServer(
      id: 's',
      name: '',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      rawBody: raw,
      nodes: parseAll(decode(raw), own: true),
    );
    expect(s.nodes.single, isA<UnknownTypeSpec>());
    final ctx = _Ctx();
    s.build(ctx);
    expect(ctx.entries.last, isA<Outbound>());
    expect(built(s)['x'], {'y': 1});
  });

  test('проба строит тело узла незнакомого типа', () {
    final nodes = parseAll(decode(body), own: true);
    final probe = buildProbeConfig(nodes);
    expect(probe.brokenByIndex, isEmpty);
    expect(probe.configJson, contains('openvpn-client'));
  });

  test('тело без type по-прежнему отклоняется', () async {
    final c = SubscriptionController();
    await c.addFromInput('{"tag": "x", "server": "h.example", '
        '"server_port": 443}');
    expect(c.lastError, isNotNull);
    expect(c.entries, isEmpty);
  });

  test('служебные типы и группы узла не создают', () async {
    for (final t in ['direct', 'block', 'dns', 'selector', 'urltest']) {
      final c = SubscriptionController();
      await c.addFromInput('{"type": "$t", "tag": "x"}');
      expect(c.entries, isEmpty, reason: t);
      expect(
          parseAll(decode('{"type": "$t", "tag": "x"}'), own: true)
              .whereType<UnknownTypeSpec>(),
          isEmpty,
          reason: t);
    }
  });

  test('известный тип с негодной формой по-прежнему отбрасывается', () {
    expect(
        parseAll(decode('{"type": "vless", "tag": "v"}'), own: true), isEmpty);
  });

  test('вход с комментариями принимается, источник без комментариев',
      () async {
    final c = SubscriptionController();
    await c.addFromInput(commented);
    expect(c.lastError, isNull);
    expect(c.lastCommentsRemoved, isTrue);
    final list = c.entries.single.list as UserServer;
    expect(list.rawBody, isNot(contains('United States')));
    expect(list.rawBody, isNot(contains('block comment')));
    expect(sourceKindOf(list.rawBody), 'singbox_outbound');
    final src = jsonDecode(list.nodes.single.rawSource) as Map;
    expect(src['password'], 'https://not-a-comment');
  });

  test('без комментариев флаг не ставится', () async {
    final c = SubscriptionController();
    await c.addFromInput(body);
    expect(c.lastCommentsRemoved, isFalse);
  });

  test('uncommentedJson: строгий JSON и не-JSON не трогает', () {
    expect(uncommentedJson('{"a": "//x"}'), isNull);
    expect(uncommentedJson('vless://u@h:1#t // x'), isNull);
    expect(uncommentedJson('{"a": 1 // c\n}'), '{"a": 1\n}');
  });

  test('узел подписки незнакомого типа по-прежнему не создаётся', () {
    final dropped = <NodeWarning>[];
    final nodes = parseAll(decode(body), dropped: dropped);
    expect(nodes, isEmpty);
    expect(dropped, isNotEmpty);
    // Документ подписки из двух узлов: незнакомый отброшен, известный жив.
    const doc = '{"outbounds": ['
        '{"type": "openvpn-client", "tag": "o", "server": "a.example",'
        ' "server_port": 1},'
        '{"type": "trojan", "tag": "t", "server": "b.example",'
        ' "server_port": 443, "password": "p"}]}';
    final sub = parseAll(decode(doc));
    expect(sub, hasLength(1));
    expect(sub.single, isA<TrojanSpec>());
  });
}
