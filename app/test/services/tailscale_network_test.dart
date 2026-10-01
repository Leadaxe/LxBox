import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/home_state.dart';
import 'package:lxbox/services/debug/serializers/home_state.dart';
import 'package:lxbox/services/tailscale_network.dart';
import 'package:lxbox/vpn/cc_channel.dart';

/// Задача 581 — разбор состояния, exit node, запись в тело, порядок
/// устройств, сводка Debug API.
void main() {
  Map<String, Object> peer(
    String id,
    String name, {
    bool online = true,
    bool exitOption = false,
    bool exitNode = false,
    List<String> ips = const [],
  }) =>
      {
        'stable_id': id,
        'host_name': name,
        'dns_name': '$name.tail1234.ts.net.',
        'os': 'linux',
        'online': online,
        'exit_node': exitNode,
        'exit_node_option': exitOption,
        'sharee_node': false,
        'expired': false,
        'key_expiry': 1790000000,
        'last_seen': 0,
        'ips': ips,
      };

  final message = [
    {
      'tag': 'ts-home',
      'backend_state': 'Running',
      'state_text': 'running',
      'auth_url': '',
      'network_name': 'alice@example.com',
      'magic_dns_suffix': 'tail1234.ts.net',
      'key_auth': true,
      'self': peer('self', 'phone', ips: ['100.64.0.1', 'fd7a::1']),
      'exit_node': peer('n2', 'gw', exitOption: true, exitNode: true,
          ips: ['100.64.0.2']),
      'user_groups': [
        {
          'user_id': 1,
          'login_name': 'alice@example.com',
          'display_name': 'Alice',
          'peers': [
            peer('n2', 'gw', exitOption: true, exitNode: true,
                ips: ['100.64.0.2', 'fd7a::2']),
            peer('n3', 'laptop', online: false, ips: ['100.64.0.3']),
          ],
        },
        {
          'user_id': 2,
          'login_name': 'bob@example.com',
          'display_name': '',
          'peers': [peer('n4', 'nas', ips: ['100.64.0.4'])],
        },
      ],
    },
    {'tag': '', 'backend_state': 'Running'},
  ];

  group('разбор сообщения канала', () {
    final list = CcTailscaleStatus.listFrom(message);

    test('узел, свой узел, устройства, группы', () {
      expect(list, hasLength(1));
      final s = list.single;
      expect(s.tag, 'ts-home');
      expect(s.backendState, 'Running');
      expect(s.networkName, 'alice@example.com');
      expect(s.keyAuth, isTrue);
      expect(s.self!.hostName, 'phone');
      expect(s.self!.ips, ['100.64.0.1', 'fd7a::1']);
      expect(s.self!.dnsNameClean, 'phone.tail1234.ts.net');
      expect(s.self!.keyExpiry, 1790000000);
      expect(s.exitNode!.stableId, 'n2');
      expect(s.userGroups, hasLength(2));
      expect(s.userGroups.first.title, 'Alice');
      expect(s.userGroups.last.title, 'bob@example.com');
      expect(s.peers.map((p) => p.stableId), ['n2', 'n3', 'n4']);
      expect(showOwnerGroups(s), isTrue);
      expect(exitNodeOptions(s).map((p) => p.stableId), ['n2']);
    });

    test('сообщение формы §579 (без полного состояния) разбирается', () {
      final s = CcTailscaleStatus.listFrom([
        {'tag': 't', 'backend_state': 'NeedsLogin', 'state_text': 'x'},
      ]).single;
      expect(s.self, isNull);
      expect(s.exitNode, isNull);
      expect(s.peers, isEmpty);
    });
  });

  group('exit node: записанное против действующего', () {
    const gw = CcTailscalePeer(
      stableId: 'n2',
      hostName: 'gw',
      dnsName: 'gw.tail1234.ts.net.',
      ips: ['100.64.0.2', 'fd7a::2'],
    );
    const other = CcTailscalePeer(stableId: 'n9', hostName: 'other');

    test('совпадают — знака нет', () {
      for (final rec in [
        '100.64.0.2',
        'gw',
        'GW',
        'gw.tail1234.ts.net',
        'gw.tail1234.ts.net.',
      ]) {
        expect(
            exitNodeMismatch(
                recorded: rec, active: gw, magicDnsSuffix: 'tail1234.ts.net'),
            ExitNodeMismatch.none,
            reason: rec);
      }
      expect(exitNodeMismatch(recorded: null, active: null),
          ExitNodeMismatch.none);
      expect(exitNodeWarningText(ExitNodeMismatch.none), isEmpty);
    });

    test('в узле нет, на ходу выбран', () {
      final m = exitNodeMismatch(recorded: null, active: gw);
      expect(m, ExitNodeMismatch.chosenNotSaved);
      expect(exitNodeWarningText(m),
          'Not saved. Traffic is not routed through this node until you save the choice.');
    });

    test('в узле записан, на ходу снят', () {
      final m = exitNodeMismatch(recorded: 'gw', active: null);
      expect(m, ExitNodeMismatch.clearedNotSaved);
      expect(exitNodeWarningText(m),
          'Not saved. The node stays in the lists, but has no exit until you save the choice.');
    });

    test('в узле один, на ходу другой', () {
      final m = exitNodeMismatch(recorded: '100.64.0.2', active: other);
      expect(m, ExitNodeMismatch.otherNotSaved);
      expect(exitNodeWarningText(m),
          'Not saved. The choice is lost after restart.');
    });

    test('в тело пишется адрес IPv4', () {
      expect(exitNodeConfigValue(gw), '100.64.0.2');
      expect(
          exitNodeConfigValue(const CcTailscalePeer(
              hostName: 'h', dnsName: 'h.ts.net.', ips: ['fd7a::5'])),
          'fd7a::5');
      expect(
          exitNodeConfigValue(
              const CcTailscalePeer(hostName: 'h', dnsName: 'h.ts.net.')),
          'h.ts.net');
    });

    test('записанное значение из тела', () {
      expect(recordedExitNode({'exit_node': ' gw '}), 'gw');
      expect(recordedExitNode({'exit_node': ''}), isNull);
      expect(recordedExitNode({}), isNull);
    });
  });

  group('Save choice: поле в теле узла', () {
    const src = '{\n  "type": "tailscale",\n  "tag": "ts",\n  "auth_key": "k"\n}';

    test('поле появляется', () {
      final out = jsonDecode(withExitNode(src, '100.64.0.2')) as Map;
      expect(out['exit_node'], '100.64.0.2');
      expect(out.keys.toList(), ['type', 'tag', 'auth_key', 'exit_node']);
    });

    test('поле меняется, порядок ключей прежний', () {
      final withGw = withExitNode(src, 'gw');
      final out = jsonDecode(withExitNode(withGw, '100.64.0.9')) as Map;
      expect(out['exit_node'], '100.64.0.9');
      expect(out.keys.toList(), ['type', 'tag', 'auth_key', 'exit_node']);
    });

    test('пункт None убирает поле, прочее не меняется', () {
      final out = jsonDecode(withExitNode(withExitNode(src, 'gw'), null)) as Map;
      expect(out.containsKey('exit_node'), isFalse);
      expect(out, jsonDecode(src));
    });

    test('источник не объект — отказ', () {
      expect(() => withExitNode('[1]', 'gw'), throwsFormatException);
    });
  });

  test('порядок устройств: в сети первыми, внутри по имени', () {
    final sorted = sortDevices(const [
      CcTailscalePeer(hostName: 'zeta', online: true),
      CcTailscalePeer(hostName: 'Alpha', online: false),
      CcTailscalePeer(hostName: 'beta', online: true),
      CcTailscalePeer(hostName: 'gamma', online: false),
    ]);
    expect(sorted.map((p) => p.hostName), ['beta', 'zeta', 'Alpha', 'gamma']);
  });

  group('Diagnostics: есть ли выход', () {
    const withExit = CcTailscaleStatus(
      tag: 't',
      backendState: 'Running',
      stateText: '',
      exitNode: CcTailscalePeer(stableId: 'n2'),
    );
    const noExit =
        CcTailscaleStatus(tag: 't', backendState: 'Running', stateText: '');

    test('VPN включён — по состоянию ядра', () {
      expect(tailscaleHasExit(vpnUp: true, status: withExit, body: {}), isTrue);
      expect(
          tailscaleHasExit(
              vpnUp: true, status: noExit, body: {'exit_node': 'gw'}),
          isFalse);
    });

    test('VPN выключен или данных нет — по записанному', () {
      expect(tailscaleHasExit(vpnUp: false, status: null, body: {}), isFalse);
      expect(
          tailscaleHasExit(
              vpnUp: false, status: null, body: {'exit_node': 'gw'}),
          isTrue);
    });
  });

  test('Debug API: состояние и число устройств, без имён и адресов', () {
    final s = CcTailscaleStatus.listFrom(message).single;
    final json = jsonEncode(
        serializeHomeState(HomeState(tailscaleStatus: {s.tag: s})));
    final map = jsonDecode(json) as Map;
    expect(map['tailscale'], {
      'ts-home': {'backend_state': 'Running', 'devices': 3},
    });
    for (final secret in [
      'phone',
      'laptop',
      'nas',
      '100.64.',
      'alice',
      'Alice',
      'bob@',
      'tail1234',
    ]) {
      expect(json.contains(secret), isFalse, reason: secret);
    }
  });
}
