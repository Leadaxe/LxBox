import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/tcp_keep_alive_spec.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §453 — TCP keep-alive dial-поля sing-box на узле: sing-box JSON, share-URI,
/// Xray sockopt.
void main() {
  const vars = TemplateVars();

  Map<String, dynamic> emitOf(NodeSpec s) =>
      s.emit(vars).map;

  group('sing-box JSON → spec → emit', () {
    test('три поля переживают round-trip', () {
      final entry = <String, dynamic>{
        'type': 'vless',
        'tag': 'ka-01',
        'server': 'srv.example.com',
        'server_port': 443,
        'uuid': '11111111-2222-3333-4444-555555555555',
        'disable_tcp_keep_alive': true,
        'tcp_keep_alive': '30s',
        'tcp_keep_alive_interval': '15s',
      };
      final s = parseSingboxEntry(entry);
      expect(s, isA<VlessSpec>());
      expect(s!.tcpKeepAlive,
          const TcpKeepAliveSpec(disabled: true, idle: '30s', interval: '15s'));

      final out = emitOf(s);
      expect(out['disable_tcp_keep_alive'], isTrue);
      expect(out['tcp_keep_alive'], '30s');
      expect(out['tcp_keep_alive_interval'], '15s');
    });

    test('голое число → секунды (D-024)', () {
      final s = parseSingboxEntry(<String, dynamic>{
        'type': 'trojan',
        'tag': 't',
        'server': 'h.example',
        'server_port': 443,
        'password': 'pw',
        'tcp_keep_alive': 30,
        'tcp_keep_alive_interval': '45',
      })!;
      expect(s.tcpKeepAlive!.idle, '30s');
      expect(s.tcpKeepAlive!.interval, '45s');
    });

    test('duration не Go-формата отброшен, соседние поля живы', () {
      final s = parseSingboxEntry(<String, dynamic>{
        'type': 'vless',
        'tag': 'bad',
        'server': 'h.example',
        'server_port': 443,
        'uuid': 'u',
        'tcp_keep_alive': 'abc',
        'tcp_keep_alive_interval': '15s',
      })!;
      expect(s.tcpKeepAlive!.idle, '', reason: '«abc» — не Go-duration');
      expect(s.tcpKeepAlive!.interval, '15s');

      final out = emitOf(s);
      expect(out.containsKey('tcp_keep_alive'), isFalse);
      expect(out['tcp_keep_alive_interval'], '15s');
    });

    test('составной Go-duration («1h30m») проходит', () {
      final s = parseSingboxEntry(<String, dynamic>{
        'type': 'vless',
        'tag': 'c',
        'server': 'h.example',
        'server_port': 443,
        'uuid': 'u',
        'tcp_keep_alive': '1h30m',
        'tcp_keep_alive_interval': '500ms',
      })!;
      expect(s.tcpKeepAlive!.idle, '1h30m');
      expect(s.tcpKeepAlive!.interval, '500ms');
    });

    test('disable_tcp_keep_alive:false без duration → null, ключей в emit нет',
        () {
      final s = parseSingboxEntry(<String, dynamic>{
        'type': 'vless',
        'tag': 'off',
        'server': 'h.example',
        'server_port': 443,
        'uuid': 'u',
        'disable_tcp_keep_alive': false,
      })!;
      expect(s.tcpKeepAlive, isNull);

      final out = emitOf(s);
      expect(out.containsKey('disable_tcp_keep_alive'), isFalse);
      expect(out.containsKey('tcp_keep_alive'), isFalse);
      expect(out.containsKey('tcp_keep_alive_interval'), isFalse);
    });

    test('узел без полей эмитится прежним байт-в-байт', () {
      final entry = <String, dynamic>{
        'type': 'vless',
        'tag': 'plain',
        'server': 'h.example',
        'server_port': 443,
        'uuid': 'u',
      };
      final out = emitOf(parseSingboxEntry(entry)!);
      expect(
        out.keys.where((k) => k.contains('keep_alive')),
        isEmpty,
      );
    });

    test('hysteria2 — не носитель: поля игнорируются', () {
      final s = parseSingboxEntry(<String, dynamic>{
        'type': 'hysteria2',
        'tag': 'hy',
        'server': 'h.example',
        'server_port': 443,
        'password': 'pw',
        'tcp_keep_alive': '30s',
        'disable_tcp_keep_alive': true,
      })!;
      expect(s, isA<Hysteria2Spec>());
      expect(s.tcpKeepAlive, isNull, reason: 'QUIC — keep-alive TCP не к чему');

      final out = emitOf(s);
      expect(out.keys.where((k) => k.contains('keep_alive')), isEmpty);
    });

    test('все 9 носителей принимают поле из sing-box JSON', () {
      final entries = <Map<String, dynamic>>[
        {'type': 'vless', 'uuid': 'u'},
        {'type': 'vmess', 'uuid': 'u'},
        {'type': 'trojan', 'password': 'pw'},
        {'type': 'anytls', 'password': 'pw'},
        {'type': 'shadowsocks', 'method': 'aes-128-gcm', 'password': 'pw'},
        {'type': 'naive', 'username': 'u', 'password': 'pw'},
        {'type': 'ssh', 'user': 'root'},
        {'type': 'socks', 'username': 'u', 'password': 'pw'},
        {'type': 'http', 'username': 'u', 'password': 'pw'},
      ];
      for (final base in entries) {
        final entry = <String, dynamic>{
          ...base,
          'tag': 'n-${base['type']}',
          'server': 'h.example',
          'server_port': 443,
          'tcp_keep_alive': '30s',
        };
        final s = parseSingboxEntry(entry);
        expect(s, isNotNull, reason: '${base['type']} не распарсился');
        expect(s!.tcpKeepAlive?.idle, '30s',
            reason: '${base['type']} потерял tcp_keep_alive');
        expect(emitOf(s)['tcp_keep_alive'], '30s',
            reason: '${base['type']} не эмитит tcp_keep_alive');
      }
    });
  });

  group('URI round-trip', () {
    test('vless — поля в query и обратно', () {
      final a = parseUri('vless://u@h.example:443'
          '?tcp_keep_alive=30s&tcp_keep_alive_interval=15s'
          '&disable_tcp_keep_alive=1#KA')!;
      expect(a.tcpKeepAlive,
          const TcpKeepAliveSpec(disabled: true, idle: '30s', interval: '15s'));

      final b = parseUri(a.toUri())!;
      expect(b.tcpKeepAlive, a.tcpKeepAlive);
    });

    test('disable_tcp_keep_alive=true тоже принимается', () {
      final a = parseUri(
          'vless://u@h.example:443?disable_tcp_keep_alive=true#D')!;
      expect(a.tcpKeepAlive!.disabled, isTrue);
    });

    test('round-trip для 8 схем с query', () {
      const uris = <String>[
        'vless://u@h.example:443?tcp_keep_alive=30s#V',
        'trojan://pw@h.example:443?tcp_keep_alive=30s#T',
        'anytls://pw@h.example:443?tcp_keep_alive=30s#A',
        'ss://YWVzLTEyOC1nY206cHc@h.example:8388?tcp_keep_alive=30s#S',
        'naive+https://u:pw@h.example:443?tcp_keep_alive=30s#N',
        'ssh://root:pw@h.example:22?tcp_keep_alive=30s#H',
        'socks5://u:pw@h.example:1080?tcp_keep_alive=30s#K',
        'proxy-http://u:pw@h.example:8080?tcp_keep_alive=30s#P',
      ];
      for (final uri in uris) {
        final a = parseUri(uri);
        expect(a, isNotNull, reason: 'не распарсился: $uri');
        expect(a!.tcpKeepAlive?.idle, '30s', reason: 'потеряно на входе: $uri');
        final b = parseUri(a.toUri());
        expect(b, isNotNull, reason: 'не распарсился обратно: $uri');
        expect(b!.tcpKeepAlive?.idle, '30s',
            reason: 'потеряно на round-trip: $uri');
      }
    });

    test('vmess — поля в base64-JSON объекта v2rayN', () {
      final cfg = <String, dynamic>{
        'v': '2',
        'ps': 'VM',
        'add': 'h.example',
        'port': '443',
        'id': '11111111-2222-3333-4444-555555555555',
        'aid': '0',
        'net': 'tcp',
        'tcp_keep_alive': '30s',
        'tcp_keep_alive_interval': '15s',
        'disable_tcp_keep_alive': true,
      };
      final uri =
          'vmess://${base64.encode(utf8.encode(jsonEncode(cfg))).replaceAll('=', '')}';
      final a = parseUri(uri)!;
      expect(a.tcpKeepAlive,
          const TcpKeepAliveSpec(disabled: true, idle: '30s', interval: '15s'));

      final b = parseUri(a.toUri())!;
      expect(b.tcpKeepAlive, a.tcpKeepAlive, reason: 'round-trip через base64');
    });

    test('vmess cleartext — поля в query-хвосте', () {
      // Cleartext-форма тоже приезжает base64 (парсер декодирует тело до
      // разбора), поэтому кодируем строку целиком.
      const body = 'auto:11111111-2222-3333-4444-555555555555'
          '@h.example:443?tcp_keep_alive=30s';
      final uri =
          'vmess://${base64.encode(utf8.encode(body)).replaceAll('=', '')}#VC';
      final a = parseUri(uri)!;
      expect(a.tcpKeepAlive?.idle, '30s');
    });

    test('naive — dial-поля в known-списке, без «unknown query param»', () {
      // Аллоулист naive логирует незнакомые ключи; наши три в нём есть.
      final a = parseUri('naive+https://u:pw@h.example:443'
          '?tcp_keep_alive=30s&tcp_keep_alive_interval=15s'
          '&disable_tcp_keep_alive=1#N')!;
      expect(a.tcpKeepAlive,
          const TcpKeepAliveSpec(disabled: true, idle: '30s', interval: '15s'));
    });

    test('ss/socks без полей — URI прежний, без «?»', () {
      final ss = parseUri('ss://YWVzLTEyOC1nY206cHc@h.example:8388#S')!;
      expect(ss.toUri().contains('?'), isFalse);
      final socks = parseUri('socks5://u:pw@h.example:1080#K')!;
      expect(socks.toUri().contains('?'), isFalse);
    });

    test('мусорный duration в URI отброшен молча', () {
      final a = parseUri('vless://u@h.example:443'
          '?tcp_keep_alive=abc&tcp_keep_alive_interval=15s#B')!;
      expect(a.tcpKeepAlive!.idle, '');
      expect(a.tcpKeepAlive!.interval, '15s');
      expect(a.warnings, isEmpty, reason: 'без нового NodeWarning');
    });
  });

  group('Xray sockopt', () {
    NodeSpec? xray(Map<String, dynamic> stream, {String protocol = 'vless'}) {
      final settings = protocol == 'vless'
          ? {
              'vnext': [
                {
                  'address': 'h.example',
                  'port': 443,
                  'users': [
                    {'id': '11111111-2222-3333-4444-555555555555'}
                  ],
                }
              ]
            }
          : {
              'servers': [
                {
                  'address': 'h.example',
                  'port': 8388,
                  'method': 'aes-128-gcm',
                  'password': 'pw',
                }
              ]
            };
      // parseXrayOutbound ждёт ЭЛЕМЕНТ подписки (с массивом outbounds),
      // а не голый outbound.
      return parseXrayOutbound(<String, dynamic>{
        'outbounds': [
          <String, dynamic>{
            'protocol': protocol,
            'tag': 'x',
            'settings': settings,
            'streamSettings': stream,
          }
        ],
      });
    }

    test('целые секунды → duration', () {
      final s = xray({
        'network': 'tcp',
        'sockopt': {'tcpKeepAliveIdle': 30, 'tcpKeepAliveInterval': 15},
      })!;
      expect(s.tcpKeepAlive,
          const TcpKeepAliveSpec(idle: '30s', interval: '15s'));
    });

    test('отрицательное → disabled (Xray ставит SO_KEEPALIVE=0)', () {
      final s = xray({
        'network': 'tcp',
        'sockopt': {'tcpKeepAliveIdle': -1},
      })!;
      expect(s.tcpKeepAlive!.disabled, isTrue);
      expect(s.tcpKeepAlive!.idle, '');
    });

    test('0 = не задано → null', () {
      final s = xray({
        'network': 'tcp',
        'sockopt': {'tcpKeepAliveIdle': 0, 'tcpKeepAliveInterval': 0},
      })!;
      expect(s.tcpKeepAlive, isNull);
    });

    test('sockopt отсутствует → null', () {
      final s = xray({'network': 'tcp'})!;
      expect(s.tcpKeepAlive, isNull);
    });

    test('shadowsocks-конвертер читает тот же sockopt', () {
      final s = xray({
        'network': 'tcp',
        'sockopt': {'tcpKeepAliveIdle': 30},
      }, protocol: 'shadowsocks')!;
      expect(s, isA<ShadowsocksSpec>());
      expect(s.tcpKeepAlive!.idle, '30s');
    });
  });

  group('withChained', () {
    test('поле переживает навешивание detour', () {
      final s = parseSingboxEntry(<String, dynamic>{
        'type': 'vless',
        'tag': 'head',
        'server': 'h.example',
        'server_port': 443,
        'uuid': 'u',
        'tcp_keep_alive': '30s',
      })!;
      final tail = parseSingboxEntry(<String, dynamic>{
        'type': 'socks',
        'tag': 'tail',
        'server': 'p.example',
        'server_port': 1080,
      })!;

      final chained = withChained(s, tail);
      expect(chained.tcpKeepAlive?.idle, '30s');

      final out = emitOf(chained);
      expect(out['detour'], 'tail');
      expect(out['tcp_keep_alive'], '30s');
    });
  });

  group('TcpKeepAliveSpec', () {
    test('isEmpty', () {
      expect(const TcpKeepAliveSpec().isEmpty, isTrue);
      expect(const TcpKeepAliveSpec(disabled: true).isEmpty, isFalse);
      expect(const TcpKeepAliveSpec(idle: '30s').isEmpty, isFalse);
      expect(const TcpKeepAliveSpec(interval: '15s').isEmpty, isFalse);
    });

    test('равенство по трём полям', () {
      expect(const TcpKeepAliveSpec(idle: '30s'),
          const TcpKeepAliveSpec(idle: '30s'));
      expect(const TcpKeepAliveSpec(idle: '30s').hashCode,
          const TcpKeepAliveSpec(idle: '30s').hashCode);
      expect(const TcpKeepAliveSpec(idle: '30s'),
          isNot(const TcpKeepAliveSpec(idle: '31s')));
    });
  });
}
