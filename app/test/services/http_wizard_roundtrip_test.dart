import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/server_list.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/tls_spec.dart';
import 'package:lxbox/services/parser/uri_utils.dart' show newUuidV4;

/// §222 — verify HttpSpec → JSON outbound → UserServer round-trip
/// preserves user-chosen tag verbatim (тот же lossless-путь, что SOCKS §074:
/// rawBody = sing-box JSON, parseSingboxEntry читает tag напрямую).
void main() {
  test('HttpSpec → JSON outbound → UserServer.fromJson preserves tag', () {
    const userTag = 'my-http-out';
    final spec = HttpSpec(
      id: newUuidV4(),
      tag: userTag,
      label: userTag,
      server: '127.0.0.1',
      port: 8080,
      rawUri: '',
    );
    final us = UserServer(
      id: newUuidV4(),
      name: 'My HTTP proxy',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.manual,
      createdAt: DateTime.utc(2026, 7, 2),
      rawBody: jsonEncode(spec.emit(TemplateVars.empty).map),
      nodes: [spec],
    );

    final restored = ServerList.fromJson(us.toJson()) as UserServer;

    expect(restored.name, 'My HTTP proxy');
    expect(restored.origin, UserSource.manual);
    expect(restored.nodes.length, 1);
    final node = restored.nodes.first;
    expect(node, isA<HttpSpec>());
    expect(node.tag, userTag,
        reason: 'tag должен survive round-trip — иначе routing rules '
            'ссылающиеся на my-http-out сломаются');
    final http = node as HttpSpec;
    expect(http.server, '127.0.0.1');
    expect(http.port, 8080);
    expect(http.tls.enabled, isFalse);
  });

  test('HttpSpec c auth + TLS → round-trip preserves user/pass/tls', () {
    final spec = HttpSpec(
      id: newUuidV4(),
      tag: 'corp-https-out',
      label: 'corp-https-out',
      server: 'proxy.corp.example',
      port: 8443,
      rawUri: '',
      username: 'alice',
      password: 's3cret',
      tls: const TlsSpec(enabled: true, serverName: 'proxy.corp.example'),
    );
    final us = UserServer(
      id: newUuidV4(),
      name: 'Corp HTTPS',
      enabled: true,
      tagPrefix: '',
      detourPolicy: DetourPolicy.defaults,
      origin: UserSource.manual,
      createdAt: DateTime.utc(2026, 7, 2),
      rawBody: jsonEncode(spec.emit(TemplateVars.empty).map),
      nodes: [spec],
    );
    final restored = ServerList.fromJson(us.toJson()) as UserServer;
    final http = restored.nodes.first as HttpSpec;
    expect(http.tag, 'corp-https-out');
    expect(http.username, 'alice');
    expect(http.password, 's3cret');
    expect(http.tls.enabled, isTrue);
    expect(http.tls.serverName, 'proxy.corp.example');
  });
}
