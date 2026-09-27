import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/services/dns/tailscale_endpoint_options.dart';

import '../parser/engine_test_setup.dart';

/// §435/§575 — опции `endpoint` формы DNS-сервера `tailscale`: перечень
/// включённых узлов Tailscale источников, чистая функция над
/// `List<ServerList>`, без storage.
void main() {
  // §480 W7 — эмит ссылки исполняет секции реестра; рукописного `toUri` у
  // схем не осталось.
  setUpAll(loadEngineSections);

  TailscaleSpec ts(String tag) => TailscaleSpec(
        id: 'ts-$tag',
        tag: tag,
        label: tag,
        body: const {'auth_key': 'tskey'},
      );

  SocksSpec socks(String tag) => SocksSpec(
        id: 'socks-$tag',
        tag: tag,
        label: tag,
        server: '10.0.0.1',
        port: 1080,
        rawSource: 'socks://10.0.0.1:1080#$tag',
      );

  UserServer user(
    NodeSpec node, {
    bool enabled = true,
    String prefix = '',
    bool withNodes = true,
  }) =>
      UserServer(
        id: 'u-${node.tag}',
        name: '',
        enabled: enabled,
        tagPrefix: prefix,
        detourPolicy: DetourPolicy.defaults,
        origin: UserSource.manual,
        rawBody: node.toUri(),
        nodes: withNodes ? [node] : const [],
      );

  FolderServers folder(List<FolderMember> members,
          {bool enabled = true, String prefix = ''}) =>
      FolderServers(
        id: 'f-${members.length}',
        name: 'F',
        enabled: enabled,
        tagPrefix: prefix,
        detourPolicy: DetourPolicy.defaults,
        members: members,
      );

  List<String> tags(List<TailscaleEndpointOption> o) =>
      [for (final x in o) x.tag];

  test('пустой вход → пустой перечень', () {
    expect(collectTailscaleEndpointOptions(const []), isEmpty);
  });

  test('свой сервер Tailscale — опция; не-Tailscale — нет', () {
    final r = collectTailscaleEndpointOptions([
      user(ts('home-ts')),
      user(socks('proxy')),
    ]);
    expect(tags(r), ['home-ts']);
    expect(r.single.enabled, isTrue);
  });

  test('tag_prefix папки входит в отображаемый тег', () {
    final r = collectTailscaleEndpointOptions([
      folder([FolderMember(raw: ts('home-ts').toUri())], prefix: 'P'),
    ]);
    expect(tags(r), ['P home-ts']);
  });

  test('выключенные источник, член и папка в перечень не входят', () {
    final r = collectTailscaleEndpointOptions([
      user(ts('off-user'), enabled: false),
      folder([
        FolderMember(raw: ts('off-member').toUri(), enabled: false),
        FolderMember(raw: ts('on-member').toUri()),
      ]),
      folder([FolderMember(raw: ts('in-off-folder').toUri())],
          enabled: false),
    ]);
    expect(tags(r), ['on-member']);
  });

  test('узел без распарсенного NodeSpec пропускается', () {
    final r = collectTailscaleEndpointOptions([
      user(ts('ghost'), withNodes: false),
      folder([FolderMember(raw: 'not a node')]),
    ]);
    expect(r, isEmpty);
  });

  test('дубль тега — одна опция', () {
    final r = collectTailscaleEndpointOptions([
      user(ts('dup')),
      user(ts('dup')),
    ]);
    expect(tags(r), ['dup']);
  });

  test('узел подписки Tailscale — опция', () {
    final sub = SubscriptionServers(
      id: 's1',
      name: 'S',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      url: 'https://example.com/sub',
      nodes: [ts('sub-ts')],
    );
    expect(tags(collectTailscaleEndpointOptions([sub])), ['sub-ts']);
  });

  test('финальный тег последней сборки побеждает отображаемый', () {
    final node = ts('home-ts');
    final r = collectTailscaleEndpointOptions(
      [user(node)],
      lastEmittedTagMap: {'home-ts-1': node},
    );
    expect(tags(r), ['home-ts-1']);
  });
}
