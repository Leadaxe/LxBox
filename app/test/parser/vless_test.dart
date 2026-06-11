import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/models/transport_spec.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/parser/uri_utils.dart';

void main() {
  // §115 — эталонная матрица брифа: эмитим flow ТОЛЬКО если (а) явно есть во
  // входе И (б) нет транспорта. Проверяем именно сгенерированный outbound.
  group('§115 flow-эмиссия (эталонная матрица)', () {
    String? emittedFlow(String uri) {
      final spec = parseVless(uri)!;
      return spec.emit(TemplateVars.empty).map['flow'] as String?;
    }

    const reality = 'security=reality&pbk=PK&sid=ABCD&sni=w.example.com';

    test('bare TCP + REALITY, без flow → flow не эмитится', () {
      expect(emittedFlow('vless://u@h:443?type=tcp&$reality#L'), isNull);
    });
    test('XHTTP + REALITY, без flow → flow не эмитится', () {
      expect(emittedFlow('vless://u@h:443?type=xhttp&host=cdn&$reality#L'),
          isNull);
    });
    test('XHTTP + REALITY, flow=vision → flow гасится', () {
      expect(
        emittedFlow(
            'vless://u@h:443?type=xhttp&host=cdn&flow=xtls-rprx-vision&$reality#L'),
        isNull,
      );
    });
    test('bare TCP + REALITY, flow=vision → flow=vision', () {
      expect(
        emittedFlow('vless://u@h:443?type=tcp&flow=xtls-rprx-vision&$reality#L'),
        'xtls-rprx-vision',
      );
    });
    test('литеральный flow=none в ссылке → flow не эмитится (не мусор в ядро)',
        () {
      expect(emittedFlow('vless://u@h:443?type=tcp&flow=none&$reality#L'),
          isNull);
    });
    test('deprecated flow=xtls-rprx-direct → flow не эмитится', () {
      expect(
          emittedFlow(
              'vless://u@h:443?type=tcp&flow=xtls-rprx-direct&$reality#L'),
          isNull);
    });
  });

  group('VLESS Reality + flow', () {
    test('§115: REALITY+bare TCP без flow → flow ПУСТОЙ (honor ссылку)', () {
      // Раньше навязывали xtls-rprx-vision → ломались валидные none-сетапы
      // (x3-ui flow: none). Теперь flow берём из ссылки как есть.
      final spec = parseVless(
        'vless://u@h:443?type=tcp&security=reality&pbk=PK&sid=ABCD&sni=w.example.com&fp=chrome#L',
      );
      expect(spec, isNotNull);
      expect(spec!.flow, '', reason: 'flow не навязывается');
      expect(spec.tls.reality?.publicKey, 'PK');
      expect(spec.tls.reality?.shortId, 'abcd');
      expect(spec.tls.fingerprint, 'chrome');
    });

    test('§115: явный flow=vision на bare TCP → сохраняется', () {
      final spec = parseVless(
        'vless://u@h:443?type=tcp&security=reality&flow=xtls-rprx-vision&pbk=PK&sid=ABCD#L',
      );
      expect(spec!.flow, 'xtls-rprx-vision');
      expect(spec.transport, isNull);
    });

    test('§115: vision + транспорт (ws) → flow погашен + warning', () {
      final spec = parseVless(
        'vless://u@h:443?type=ws&path=/x&security=tls&flow=xtls-rprx-vision#L',
      );
      expect(spec!.flow, '', reason: 'vision несовместим с транспортом');
      expect(spec.transport, isA<WsTransport>());
      expect(spec.warnings.whereType<VisionWithTransportWarning>(), isNotEmpty);
    });

    test('§115: vision + xhttp → flow погашен (XHTTP+Vision protocol limit)',
        () {
      final spec = parseVless(
        'vless://u@h:443?type=xhttp&host=cdn.example&security=reality&pbk=PK&flow=xtls-rprx-vision#L',
      );
      expect(spec!.flow, '');
      expect(spec.warnings.whereType<VisionWithTransportWarning>(), isNotEmpty);
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

    test('§097 — xhttp transport → нативный emit (без fallback-warning)', () {
      final spec = parseVless(
          'vless://u@h:443?type=xhttp&path=/x&host=h&mode=stream-one'
          '&xPaddingBytes=100-1000&noGRPCHeader=true&security=tls');
      final t = spec!.transport as XhttpTransport;
      expect(t.path, '/x');
      expect(t.host, 'h');
      expect(t.mode, 'stream-one');
      expect(t.xPaddingBytes, '100-1000');
      expect(t.noGrpcHeader, true);
      final tr = spec.emit(TemplateVars.empty).map['transport'] as Map;
      expect(tr['type'], 'xhttp');
      expect(tr['mode'], 'stream-one');
      expect(tr['x_padding_bytes'], '100-1000');
      expect(tr['no_grpc_header'], true);
      expect(spec.warnings.whereType<UnsupportedTransportWarning>(), isEmpty);
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
