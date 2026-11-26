// §717 (контракт 1.1.175) — ссылки deep-link TrustTunnel
// (`tt://?<base64url TLV>`) → узел `trusttunnel` и обратно.
//
// Формат раскрывает табличный примитив `tlv` движка (MAPPER_ENGINE §4a) по
// диалекту секции реестра; декодера под схему нет. Ссылки собираются
// функциями самого кодека ([encodeTlv]) — они же зеркало чтения.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/services/parser/engine/emitter.dart';
import 'package:lxbox/services/parser/engine/section.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/engine/tlv.dart';
import 'package:lxbox/services/parser/singbox_config.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';
import 'package:lxbox/services/subscription/input_helpers.dart';

import '../contract_paths.dart';
import 'engine_test_setup.dart';

List<int> _str(int tag, String s) => encodeTlv(tag, utf8.encode(s));

String _link(List<List<int>> fields) => 'tt://?'
    '${base64Url.encode([for (final f in fields) ...f]).replaceAll('=', '')}';

final _version = encodeTlv(0x00, writeVarint(2));
final _hostname = _str(0x01, 'vpn.example.com');
final _addr = _str(0x02, '1.2.3.4:443');
final _user = _str(0x05, 'alice');
final _pass = _str(0x06, 's3cr3t');
final _name = _str(0x0C, 'Example VPN');
final _node = [_version, _hostname, _user, _pass, _addr];

// Два DER-элемента: SEQUENCE с длинной формой длины (100 байт тела) и с
// короткой. Годность сертификата кодек не судит — только заголовок ASN.1.
final _der1 = [0x30, 0x81, 100, ...List<int>.generate(100, (i) => (i * 7) & 0xFF)];
final _der2 = [0x30, 3, 1, 2, 3];

Map<String, dynamic> _bodyOf(NodeSpec n) => (n as UnknownTypeSpec).body;

List<RegistryWarning> _notes(NodeSpec n) =>
    n.warnings.whereType<RegistryWarning>().toList();

String? _dropCode(String link) {
  final dropped = XrayDropVerdict();
  expect(parseUri(link, dropped: dropped), isNull);
  return dropped.reason?.code;
}

void main() {
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  test('varint: QUIC-форма, чтение — зеркало записи', () {
    for (final v in [0, 63, 64, 16383, 16384, 1 << 29, (1 << 30) - 1]) {
      final enc = writeVarint(v);
      expect(readVarint(enc, 0), (v, enc.length));
    }
    expect(writeVarint(64), [0x40, 0x40]);
  });

  test('адрес: IPv6 в скобках, порт числом, голый IPv6 без порта', () {
    expect(splitHostPort('[2001:db8::1]:8443'), ('2001:db8::1', 8443));
    expect(splitHostPort('host.example:443'), ('host.example', 443));
    expect(splitHostPort('2001:db8::1'), ('2001:db8::1', null));
    expect(joinHostPort('2001:db8::1', 8443), '[2001:db8::1]:8443');
  });

  test('секция — из реестра, диалект tlv объявлен таблицей', () {
    final section = MapperSections.I.sectionFor('uri', 'trusttunnel');
    expect(section?.tlv, isNotNull);
    expect(section!.tlv!.byName('tls_profile')?.tag, 0x10);
    expect(File('assets/contract_draft/uri/trusttunnel.json').existsSync(),
        isFalse);
  });

  test('1. полный узел http2 без сертификата', () {
    final link = _link([..._node, _name]);
    final node = parseUri(link);
    expect(node, isA<UnknownTypeSpec>());
    final n = node! as UnknownTypeSpec;
    expect(n.type, 'trusttunnel');
    final b = _bodyOf(n);
    expect(b['server'], '1.2.3.4');
    expect(b['server_port'], 443);
    expect(b['username'], 'alice');
    expect(b['password'], 's3cr3t');
    expect(b['tls'], {'enabled': true, 'server_name': 'vpn.example.com'});
    expect(b.containsKey('quic'), isFalse);
    expect(n.tag, 'Example VPN');
    expect(n.label, 'Example VPN');
    expect(n.server, '1.2.3.4');
    expect(n.port, 443);
    expect(_notes(n), isEmpty);
    expect(n.toUri(), link);
  });

  test('1a. имени нет — метка пуста, тег — фолбэк по типу тела', () {
    final n = parseUri(_link(_node))!;
    expect(n.label, '');
    expect(n.tag, 'trusttunnel-1.2.3.4-443');
  });

  test('1b. имя из фрагмента; имя контейнера сильнее', () {
    expect(parseUri('${_link(_node)}#From%20Fragment')!.label, 'From Fragment');
    expect(parseUri('${_link([..._node, _name])}#Other')!.label, 'Example VPN');
  });

  test('2. http3 + custom_sni + цепочка DER + skip_verification', () {
    final link = _link([
      ..._node,
      _str(0x03, 'sni.example.org'),
      encodeTlv(0x07, [1]),
      encodeTlv(0x08, [..._der1, ..._der2]),
      encodeTlv(0x09, [2]),
    ]);
    final n = parseUri(link)!;
    final b = _bodyOf(n);
    expect(b['quic'], true);
    final tls = (b['tls'] as Map).cast<String, dynamic>();
    // Сертификат сверяется с hostname; custom_sni тело не выражает.
    expect(tls['server_name'], 'vpn.example.com');
    expect(tls['insecure'], true);
    final cert = tls['certificate'];
    final pem = cert is List ? cert.join('\n') : cert as String;
    expect('-----BEGIN CERTIFICATE-----'.allMatches(pem).length, 2);
    expect(pem.endsWith('-----END CERTIFICATE-----'), isTrue);
    expect(
        pem.split('\n').where((l) => !l.startsWith('-----')).every(
            (l) => l.length <= 64),
        isTrue);
    expect(pemToDerChain(pem), [..._der1, ..._der2]);
    final notes = _notes(n);
    expect(notes.map((w) => w.code), ['tt_field_unsupported', 'tls_insecure']);
    expect(notes.first.params['field'], 'custom_sni');
  });

  test('3. поля формата, которых нет в теле, — tt_field_unsupported', () {
    final link = _link([
      ..._node,
      _str(0x02, '[2001:db8::1]:8443'),
      encodeTlv(0x04, [0]),
      encodeTlv(0x0D, encodeStringArray(['8.8.8.8', '1.1.1.1'])),
      encodeTlv(0x0A, [1]),
      _str(0x0B, 'aabb/ffff'),
      _str(0x0F, '00112233'),
    ]);
    final n = parseUri(link)!;
    final b = _bodyOf(n);
    expect(b['server'], '1.2.3.4');
    expect(b['server_port'], 443);
    final notes = _notes(n);
    expect(notes.map((w) => w.code).toSet(), {'tt_field_unsupported'});
    expect(notes.map((w) => w.params['field']), unorderedEquals([
      'address', 'has_ipv6', 'dns_upstreams', 'anti_dpi',
      'client_random_prefix', 'client_random_auth_key',
    ]));
    expect(b.keys, unorderedEquals(
        ['type', 'server', 'server_port', 'username', 'password', 'tls']));
  });

  test('3a. tls_profile → uTLS; умолчание и openssl блока не дают', () {
    Map? utls(int profile) => (_bodyOf(parseUri(
            _link([..._node, encodeTlv(0x10, [profile])]))!)['tls']
        as Map)['utls'] as Map?;
    expect(utls(0), isNull);
    expect(utls(3), {'enabled': true, 'fingerprint': 'firefox'});
    expect(utls(4), {'enabled': true, 'fingerprint': 'android'});
    expect(utls(5), isNull);
  });

  test('3b. tls_profile при http3 — код без uTLS', () {
    final n = parseUri(
        _link([..._node, encodeTlv(0x09, [2]), encodeTlv(0x10, [3])]))!;
    expect((_bodyOf(n)['tls'] as Map).containsKey('utls'), isFalse);
    expect(_bodyOf(n)['quic'], true);
    expect(_notes(n).single.code, 'tt_field_unsupported');
    expect(_notes(n).single.params['field'], 'tls_profile');
  });

  test('3c. явные умолчания формата равны отсутствию тега', () {
    final n = parseUri(_link([
      ..._node,
      encodeTlv(0x04, [1]),
      encodeTlv(0x07, [0]),
      encodeTlv(0x09, [1]),
      encodeTlv(0x0A, [0]),
      encodeTlv(0x10, [0]),
    ]))!;
    expect(_notes(n), isEmpty);
    expect(_bodyOf(n).containsKey('quic'), isFalse);
  });

  test('3d. не-UTF-8 в строке — один U+FFFD на серию, узел жив', () {
    final n = parseUri(
        _link([..._node, encodeTlv(0x0C, [0x41, 0xFF, 0xFE, 0x42])]))!;
    expect(n.label, 'A�B');
  });

  test('4. только subscription_url → снята tt_subscription_only', () {
    expect(_dropCode(_link([_version, _str(0x0E, 'https://sub.example.com/x')])),
        'tt_subscription_only');
  });

  test('4a. subscription_url при полном узле — tt_subscription_ignored', () {
    final n = parseUri(
        _link([..._node, _str(0x0E, 'https://sub.example.com/x')]))!;
    expect(_notes(n).map((w) => w.code), ['tt_subscription_ignored']);
  });

  group('5. контейнер не прочитан → form_unrecognized', () {
    final cases = {
      'битый base64': 'tt://?@@@!!',
      'пейлоада нет': 'tt://?',
      'обрыв TLV':
          'tt://?${base64Url.encode([0x01, 0x10, 0x61]).replaceAll('=', '')}',
      'version 3': _link([encodeTlv(0x00, writeVarint(3)), ..._node.skip(1)]),
      'bool не 00/01': _link([..._node, encodeTlv(0x07, [2])]),
      'tls_profile вне таблицы': _link([..._node, encodeTlv(0x10, [0x7F])]),
      'subscription_url не https':
          _link([..._node, _str(0x0E, 'http://sub.example.com/x')]),
      'certificate не DER': _link([..._node, encodeTlv(0x08, [1, 2, 3])]),
    };
    for (final e in cases.entries) {
      test(e.key, () => expect(_dropCode(e.value), 'form_unrecognized'));
    }
  });

  test('6. нет пароля, адреса или порта → field_missing', () {
    expect(_dropCode(_link([_version, _hostname, _user, _addr])),
        'field_missing');
    expect(_dropCode(_link([_version, _hostname, _user, _pass])),
        'field_missing');
    expect(
        _dropCode(_link([_version, _hostname, _user, _pass, _str(0x02, '1.2.3.4')])),
        'field_missing');
  });

  test('7. ссылка распознаётся как прямая', () {
    expect(isDirectLink(_link(_node)), isTrue);
  });

  group('8. обратный ход emit.container tlv', () {
    String? emit(String link) {
      final n = parseUri(link)! as UnknownTypeSpec;
      final section = MapperSections.I.sectionFor('uri', 'trusttunnel')!;
      return emitViaSection(section, n.body, n.label)?.uri;
    }

    // Критерий паритета TASKS_LXBOX §177 п. 4: ссылка из тела равна исходной
    // байт в байт (исходные собраны энкодером AdGuard).
    for (final name in const [
      'http2_basic',
      'ipv6_address',
      'cert_chain_two',
      'tls_profile_firefox',
      'tls_profile_okhttp',
    ]) {
      test('паритет: $name', () {
        final link = File('$kVendorRoot/corpus/uri/trusttunnel/$name.uri')
            .readAsLinesSync()
            .firstWhere((l) => l.startsWith('tt://'));
        expect(emit(link), link);
      });
    }

    test('hostname ← tls.server_name, без него — server', () {
      final section = MapperSections.I.sectionFor('uri', 'trusttunnel')!;
      final uri = emitViaSection(section, {
        'type': 'trusttunnel',
        'server': '2001:db8::1',
        'server_port': 8443,
        'username': 'u',
        'password': 'p',
        'quic': true,
        'tls': {'enabled': true, 'insecure': true},
      }, '')!.uri;
      final b = _bodyOf(parseUri(uri)!);
      expect(b['server'], '2001:db8::1');
      expect(b['server_port'], 8443);
      expect(b['quic'], true);
      expect(b['tls'],
          {'enabled': true, 'server_name': '2001:db8::1', 'insecure': true});
    });

    test('отпечаток вне таблицы формата в ссылку не пишется', () {
      final section = MapperSections.I.sectionFor('uri', 'trusttunnel')!;
      final uri = emitViaSection(section, {
        'type': 'trusttunnel',
        'server': '1.2.3.4',
        'server_port': 443,
        'username': 'u',
        'password': 'p',
        'tls': {
          'enabled': true,
          'server_name': 'h.example',
          'utls': {'enabled': true, 'fingerprint': 'edge'},
        },
      }, 'N')!.uri;
      final n = parseUri(uri)!;
      expect((_bodyOf(n)['tls'] as Map).containsKey('utls'), isFalse);
      expect(n.label, 'N');
    });
  });
  // Узел из sing-box JSON хранится текстом записи, а Share отдаёт ссылку,
  // собранную движком по секции реестра (contract 1.1.176, emit.container tlv).
  group('9. Share узла из sing-box JSON', () {
    List<String> corpusLinks() => [
          for (final f in Directory('$kVendorRoot/corpus/uri/trusttunnel')
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.uri'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
            f.readAsLinesSync().firstWhere((l) => l.startsWith('tt://'),
                orElse: () => ''),
        ].where((l) => l.isNotEmpty).toList();

    // Тот же узел, как если бы он пришёл записью конфига: хранение — JSON.
    UnknownTypeSpec asJsonNode(UnknownTypeSpec n) => UnknownTypeSpec(
          id: 'j',
          tag: n.tag,
          label: n.label,
          type: n.type,
          body: n.body,
          server: n.server,
          port: n.port,
          rawSource: const JsonEncoder.withIndent('  ').convert(n.body),
        );

    // Те же пять кейсов, что TestContractTLVEmitByteParity лаунчера.
    for (final name in const [
      'http2_basic',
      'ipv6_address',
      'cert_chain_two',
      'tls_profile_firefox',
      'tls_profile_okhttp',
    ]) {
      test('паритет байт в байт: $name', () {
        final link = File('$kVendorRoot/corpus/uri/trusttunnel/$name.uri')
            .readAsLinesSync()
            .firstWhere((l) => l.startsWith('tt://'));
        final json = asJsonNode(parseUri(link)! as UnknownTypeSpec);
        expect(json.shareUri(), link);
        expect(json.toUri(), json.rawSource, reason: 'хранение не меняется');
      });
    }

    test('круг по корпусу: тело и метка возвращаются', () {
      var seen = 0;
      for (final link in corpusLinks()) {
        final n = parseUri(link);
        if (n is! UnknownTypeSpec) continue;
        seen++;
        final shared = asJsonNode(n).shareUri();
        expect(shared, startsWith('tt://?'), reason: link);
        final back = parseUri(shared)! as UnknownTypeSpec;
        expect(back.body, n.body, reason: link);
        expect(back.label, n.label, reason: link);
      }
      expect(seen, greaterThanOrEqualTo(15));
    });

    test('запись endpoints[] конфига: имя ссылки — тег записи', () {
      final nodes = parseSingboxConfigs([
        {
          'endpoints': [
            {
              'type': 'trusttunnel',
              'tag': 'Office',
              'server': '1.2.3.4',
              'server_port': 443,
              'username': 'alice',
              'password': 's3cr3t',
              'tls': {'enabled': true, 'server_name': 'vpn.example.com'},
            },
          ],
        },
      ]);
      final n = nodes.single as UnknownTypeSpec;
      expect(n.toUri().trimLeft(), startsWith('{'));
      final back = parseUri(n.shareUri())! as UnknownTypeSpec;
      expect(back.label, 'Office');
      expect(back.body['server'], '1.2.3.4');
      expect(back.body['server_port'], 443);
      expect(back.body['username'], 'alice');
      expect(back.body['password'], 's3cr3t');
      expect((back.body['tls'] as Map)['server_name'], 'vpn.example.com');
    });

    test('узел, пришедший ссылкой, отдаёт её как есть', () {
      // Неизвестный тег на круге теряется — исходная ссылка его хранит.
      final link = File(
              '$kVendorRoot/corpus/uri/trusttunnel/unknown_tag_skipped.uri')
          .readAsLinesSync()
          .firstWhere((l) => l.startsWith('tt://'));
      final n = parseUri(link)!;
      expect(n.shareUri(), n.rawSource);
      expect(n.shareUri(), n.toUri());
    });

    test('тип без обратного хода в реестре: остаётся текст записи', () {
      final n = UnknownTypeSpec(
        id: 'x',
        tag: 't',
        label: 't',
        type: 'no-such-type',
        body: const {'type': 'no-such-type'},
        rawSource: '{"type":"no-such-type"}',
      );
      expect(n.shareUri(), n.rawSource);
    });
  });

  test('10. цепочка a|b, литерал и \$label в json_map контейнера JSON', () {
    final reg = jsonDecode(
            File('$kVendorRoot/registry/protocols/vmess.json').readAsStringSync())
        as Map<String, dynamic>;
    final uri = Map<String, dynamic>.from((reg['mappers'] as Map)['uri'] as Map);
    uri['emit'] = {
      ...uri['emit'] as Map,
      'json_map': {
        'v': '=2',
        'ps': r'$label',
        'add': 'server',
        'port': 'server_port',
        'id': 'uuid',
        'sni': 'tls.server_name|server',
      },
    };
    final section = MapperSection.fromJson('uri', 'vmess', uri);
    Map<String, dynamic> emitted(Map<String, dynamic> body) {
      final link = emitViaSection(section, body, 'N')!.uri;
      final text = link.substring(link.indexOf('://') + 3);
      return jsonDecode(utf8.decode(base64.decode(base64.normalize(text))))
          as Map<String, dynamic>;
    }

    final base = {
      'type': 'vmess',
      'server': 'a.example',
      'server_port': 443,
      'uuid': '11111111-2222-3333-4444-555555555555',
    };
    final plain = emitted(base);
    expect(plain['sni'], 'a.example');
    expect(plain['v'], '2');
    expect(plain['ps'], 'N');
    final named = emitted({
      ...base,
      'tls': {'enabled': true, 'server_name': 'sni.example'},
    });
    expect(named['sni'], 'sni.example');
  });
}
