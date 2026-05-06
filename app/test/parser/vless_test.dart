import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/transport_spec.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/parser/uri_utils.dart';

void main() {
  group('VLESS Reality + flow', () {
    test('reality with pbk auto-sets flow when no transport', () {
      final spec = parseVless(
        'vless://u@h:443?type=tcp&security=reality&pbk=PK&sid=ABCD&sni=w.example.com&fp=chrome#L',
      );
      expect(spec, isNotNull);
      expect(spec!.flow, 'xtls-rprx-vision');
      expect(spec.tls.reality?.publicKey, 'PK');
      expect(spec.tls.reality?.shortId, 'abcd');
      expect(spec.tls.fingerprint, 'chrome');
    });

    test('flow=xtls-rprx-vision-udp443 → vision + xudp packet encoding', () {
      final spec = parseVless('vless://u@h:443?type=tcp&flow=xtls-rprx-vision-udp443');
      expect(spec!.flow, 'xtls-rprx-vision');
      expect(spec.packetEncoding, 'xudp');
    });

    test('plaintext VLESS port keeps TLS disabled', () {
      final spec = parseVless('vless://u@h:8080?type=ws&path=/x');
      expect(spec!.tls.enabled, isFalse);
    });
  });

  group('VLESS transport', () {
    test('ws transport parsed', () {
      final spec = parseVless('vless://u@h:443?type=ws&path=/p&host=h&security=tls');
      expect(spec!.transport, isA<WsTransport>());
      final t = spec.transport as WsTransport;
      expect(t.path, '/p');
      expect(t.host, 'h');
    });

    test('grpc transport parsed', () {
      final spec =
          parseVless('vless://u@h:443?type=grpc&serviceName=svc&security=tls');
      expect((spec!.transport as GrpcTransport).serviceName, 'svc');
    });

    test('xhttp transport triggers UnsupportedTransportWarning on emit', () {
      final spec = parseVless('vless://u@h:443?type=xhttp&path=/x&host=h&security=tls');
      expect(spec!.transport, isA<XhttpTransport>());
      spec.emit(TemplateVars.empty);
      expect(
        spec.warnings.whereType<UnsupportedTransportWarning>(),
        hasLength(1),
      );
    });
  });

  group('VLESS packet_encoding allow-list', () {
    // Sing-box `vless.NewOutbound` принимает только {"", xudp, packetaddr};
    // другое значение → panic в libbox. См. normalizePacketEncoding.

    test('xudp passes through', () {
      final spec = parseVless('vless://u@h:443?type=tcp&packetEncoding=xudp');
      expect(spec!.packetEncoding, 'xudp');
      expect(spec.emit(TemplateVars.empty).map['packet_encoding'], 'xudp');
    });

    test('XUDP normalized to lowercase', () {
      final spec = parseVless('vless://u@h:443?type=tcp&packetEncoding=XUDP');
      expect(spec!.packetEncoding, 'xudp');
    });

    test('PacketAddr normalized to lowercase', () {
      final spec = parseVless(
        'vless://u@h:443?type=tcp&packetEncoding=PacketAddr',
      );
      expect(spec!.packetEncoding, 'packetaddr');
    });

    test('xray-style none silently dropped', () {
      // Реальный триггер краша libbox.so: panic в format.ToString при
      // unknown packet encoding. Должно стать omitted.
      final spec = parseVless('vless://u@h:443?type=tcp&packetEncoding=none');
      expect(spec!.packetEncoding, '');
      expect(
        spec.emit(TemplateVars.empty).map.containsKey('packet_encoding'),
        isFalse,
      );
    });

    test('garbage value dropped', () {
      final spec = parseVless(
        'vless://u@h:443?type=tcp&packetEncoding=somethingweird',
      );
      expect(spec!.packetEncoding, '');
      expect(
        spec.emit(TemplateVars.empty).map.containsKey('packet_encoding'),
        isFalse,
      );
    });

    test('absent → empty', () {
      final spec = parseVless('vless://u@h:443?type=tcp');
      expect(spec!.packetEncoding, '');
    });

    test('case-insensitive query key (packetencoding lowercase)', () {
      final spec = parseVless('vless://u@h:443?type=tcp&packetencoding=xudp');
      expect(spec!.packetEncoding, 'xudp');
    });

    test('vision-udp443 quirk wins over query value', () {
      // flow=xtls-rprx-vision-udp443 принудительно ставит xudp; неверный
      // packetEncoding=none из URI игнорируется (короткое замыкание).
      final spec = parseVless(
        'vless://u@h:443?type=tcp&flow=xtls-rprx-vision-udp443&packetEncoding=none',
      );
      expect(spec!.packetEncoding, 'xudp');
    });

    test('normalizePacketEncoding helper directly', () {
      expect(normalizePacketEncoding(''), '');
      expect(normalizePacketEncoding('none'), '');
      expect(normalizePacketEncoding('  None  '), '');
      expect(normalizePacketEncoding('xudp'), 'xudp');
      expect(normalizePacketEncoding('XUDP'), 'xudp');
      expect(normalizePacketEncoding('packetaddr'), 'packetaddr');
      expect(normalizePacketEncoding('PacketAddr'), 'packetaddr');
      expect(normalizePacketEncoding('garbage'), '');
    });
  });

  group('VLESS emit', () {
    test('produces sing-box vless outbound with uuid + flow + tls + transport', () {
      final spec = parseVless(
        'vless://u@h:443?type=ws&path=/p&host=h&security=tls&sni=h&fp=chrome',
      );
      final m = spec!.emit(TemplateVars.empty).map;
      expect(m['type'], 'vless');
      expect(m['uuid'], 'u');
      expect((m['transport'] as Map)['type'], 'ws');
      expect((m['tls'] as Map)['enabled'], true);
    });
  });
}
