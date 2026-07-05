import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/uri_utils.dart' show newUuidV4;

/// §074 — verify SocksSpec → JSON outbound → UserServer round-trip
/// preserves user-chosen tag verbatim.
///
/// Регрессия: до правки wizard persist'ил rawBody через `spec.toUri()` —
/// URI format `socks5://...#fragment`, parser восстанавливал tag из
/// fragment'а. `tag = "my-socks-out"`, `label = "My Local SOCKS"` → после
/// restart'а tag становился `"My Local SOCKS"`, routing rules ломались.
///
/// Fix: persist через `emit().map` (sing-box outbound JSON). JSON parser
/// читает entry['tag'] напрямую — exact round-trip.
void main() {
  test('SocksSpec → JSON outbound → UserServer.fromJson preserves tag', () {
    // Модельный round-trip: пользовательский tag + name. С §243 визард
    // name больше не пишет (заголовок = tag), но поле в модели живо
    // (подписки/папки) — persist-контракт UserServer.name проверяем тут.
    const userTag = 'my-socks-out';
    final spec = SocksSpec(
      id: newUuidV4(),
      tag: userTag,
      label: userTag, // §074: label = tag для lossless round-trip
      server: '127.0.0.1',
      port: 1080,
      rawUri: '',
      username: '',
      password: '',
    );
    final outboundMap = spec.emit(TemplateVars.empty).map;
    final us = UserServer(
      id: newUuidV4(),
      name: 'My Local SOCKS', // display name — UserServer.name, persisted натив'но
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.manual,
      createdAt: DateTime.utc(2026, 6, 5),
      rawBody: jsonEncode(outboundMap),
      nodes: [spec],
    );

    // Persist round-trip.
    final restored =
        ServerList.fromJson(us.toJson()) as UserServer;

    expect(restored.name, 'My Local SOCKS');
    expect(restored.origin, UserSource.manual);
    expect(restored.nodes.length, 1);
    final node = restored.nodes.first;
    expect(node, isA<SocksSpec>());
    expect(node.tag, userTag,
        reason: 'tag должен survive round-trip — иначе routing rules '
            'ссылающиеся на my-socks-out сломаются');
    final socks = node as SocksSpec;
    expect(socks.server, '127.0.0.1');
    expect(socks.port, 1080);
  });

  test('SocksSpec with credentials → round-trip preserves user/pass', () {
    final spec = SocksSpec(
      id: newUuidV4(),
      tag: 'proxy-with-auth',
      label: 'proxy-with-auth',
      server: '10.0.0.1',
      port: 2080,
      rawUri: '',
      username: 'alice',
      password: 's3cret',
    );
    final us = UserServer(
      id: newUuidV4(),
      name: 'Authenticated',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.manual,
      createdAt: DateTime.utc(2026, 6, 5),
      rawBody: jsonEncode(spec.emit(TemplateVars.empty).map),
      nodes: [spec],
    );
    final restored =
        ServerList.fromJson(us.toJson()) as UserServer;
    final socks = restored.nodes.first as SocksSpec;
    expect(socks.tag, 'proxy-with-auth');
    expect(socks.username, 'alice');
    expect(socks.password, 's3cret');
  });
}
