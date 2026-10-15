import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/contract/body_edit.dart';
import 'package:lxbox/services/contract/body_sanitizer.dart';
import 'package:lxbox/services/contract/registry.dart';

import '../contract_paths.dart';

// §654 A — wildcard `*` реестра (контракт 1.1.122, TASKS_LXBOX §119 п. 1–2):
// неописанные ключи объекта с `*` проходят как есть, без `unknown_key`;
// описанные судятся правилами; `*` не наследуется во вложенный объект без
// своего `*`; запись `*` — не поле ни для одного обхода.
List<String> _codes(SanitizeResult r) => [
  for (final w in r.warnings) '${w.code}@${w.path ?? ''}',
];

SanitizeResult _sanitize(Map<String, dynamic> body) =>
    RegistrySanitizer.sanitize(
      (jsonDecode(jsonEncode(body)) as Map).cast<String, dynamic>(),
      scheme: '${body['type']}',
      coreVersion: '0.0.0',
      applyCoreGates: false,
    );

void main() {
  group('реестр бандла', () {
    setUpAll(loadTestRegistry);

    test('`*` — не поле: нет в fields, есть в order (слот)', () {
      final oc = ContractRegistry.I.schemaFor('openconnect')!;
      expect(oc.fields.containsKey(kWildcardField), isFalse);
      expect(oc.order.last, kWildcardField);
      expect(oc.hasWildcard, isTrue);
      expect(oc.fields['tls']!.fields!.containsKey(kWildcardField), isFalse);
      expect(oc.fields['tls']!.hasWildcard, isTrue);
      expect(oc.fields['token']!.hasWildcard, isTrue);
      final ovpn = ContractRegistry.I.schemaFor('openvpn-client')!;
      expect(ovpn.order, [kWildcardField]);
      expect(ovpn.fields, isEmpty);
      expect(ContractRegistry.I.schemaFor('vless')!.hasWildcard, isFalse);
    });

    test('роль и адрес: variant у flavor, server описан, server_port нет', () {
      expect(fieldByRole('openconnect', 'variant'), 'flavor');
      final reg = ContractRegistry.I;
      expect(reg.describesRootField('openconnect', 'server'), isTrue);
      expect(reg.describesRootField('openconnect', 'server_port'), isFalse);
      expect(reg.describesRootField('openconnect', kWildcardField), isFalse);
      expect(reg.describesRootField('vless', 'server_port'), isTrue);
      expect(reg.knowsType('openconnect'), isTrue);
      expect(reg.knowsType('future-proto'), isFalse);
    });

    test('openvpn-client (`order: ["*"]`) — тело как написано, без кодов', () {
      final body = <String, dynamic>{
        'type': 'openvpn-client',
        'tag': 'ovpn',
        'servers': [
          {'address': 'vpn.example.com', 'port': 1194},
        ],
        'tls': {'anything': true},
        'z_last': 1,
      };
      final r = _sanitize(body);
      expect(r.warnings, isEmpty);
      expect(r.body, body);
    });

    test('openconnect: сквозные ключи на всех уровнях с `*`, описанные — '
        'правилами', () {
      final r = _sanitize({
        'type': 'openconnect',
        'tag': 'forti',
        'server': 'fw.example.com',
        'flavor': 'fortinet',
        'cookie': 'webvpn=abc',
        'mobile': {'device_type': 'iPhone'},
        'token': {'mode': 'totp', 'secret': 'JBSWY3DPEHPK3PXP', 'pin': '1'},
        'tls': {
          'insecure': true,
          'mca_key_path': '/k',
          'peer_fingerprint': ['sha256:0123', 'AA:BB'],
        },
      });
      expect(_codes(r), [
        'tls_insecure@tls.insecure',
        'openconnect_fingerprint_invalid@tls.peer_fingerprint[1]',
      ]);
      final b = r.body!;
      expect(b['cookie'], 'webvpn=abc');
      expect(b['mobile'], {'device_type': 'iPhone'});
      expect((b['token'] as Map)['pin'], '1');
      expect((b['tls'] as Map)['mca_key_path'], '/k');
      expect((b['tls'] as Map)['peer_fingerprint'], ['sha256:0123']);
    });

    test('неизвестный flavor снимает узел своим кодом', () {
      final r = _sanitize({
        'type': 'openconnect',
        'tag': 'x',
        'server': 'fw.example.com',
        'flavor': 'forti',
      });
      expect(r.body, isNull);
      expect(r.explicitDropNode, isTrue);
      expect(r.warnings[r.dropFrom].code, 'openconnect_flavor_invalid');
    });

    test('связь снимает единственное поле объекта — объект не остаётся '
        'пустым', () {
      final r = _sanitize({
        'type': 'openconnect',
        'tag': 'x',
        'server': 'fw.example.com',
        'tls': {'client_certificate_path': '/c'},
      });
      expect(_codes(r), ['field_requires@tls.client_certificate_path']);
      expect(r.body!.containsKey('tls'), isFalse);
    });

    // §654 A2 (контракт 1.1.123, TASKS_LXBOX §120 п. 7) — у `headers` ws и
    // httpupgrade описан `Host` и стоит `*`: прочие заголовки идут насквозь,
    // без `unknown_key`.
    for (final t in const ['ws', 'httpupgrade']) {
      test('$t: сквозные заголовки без unknown_key, Host описан', () {
        final headers = {
          'Host': 'cdn.example.com',
          'User-Agent': 'Mozilla/5.0',
          'X-Forwarded-For': ['1.1.1.1', '2.2.2.2'],
        };
        final r = _sanitize({
          'type': 'vless',
          'tag': 'x',
          'server': 'a.example.com',
          'server_port': 443,
          'uuid': 'b831381d-6324-4d53-ad4f-8cda48b30811',
          'transport': {'type': t, 'path': '/ws', 'headers': headers},
        });
        expect(_codes(r), isEmpty);
        expect((r.body!['transport'] as Map)['headers'], headers);
      });
    }

    // §654 A2 (контракт 1.1.124, PARSING_PRINCIPLES §6.4).
    test('описанный объект `{}` во входе снимается без кода; вариантный '
        '`{}` — field_missing на дискриминаторе', () {
      final r = _sanitize({
        'type': 'vless',
        'tag': 'x',
        'server': 'a.example.com',
        'server_port': 443,
        'uuid': 'b831381d-6324-4d53-ad4f-8cda48b30811',
        'tls': {'enabled': true, 'server_name': 'a.example.com', 'ech': {}},
        'transport': {},
      });
      expect(_codes(r), ['field_missing@transport.type']);
      expect(r.body!.containsKey('transport'), isFalse);
      expect(r.body!['tls'], {'enabled': true, 'server_name': 'a.example.com'});
    });

    test('авторское тело (§577): пустой описанный объект не правится', () {
      final raw = <String, dynamic>{
        'type': 'vless',
        'tag': 'x',
        'server': 'a.example.com',
        'server_port': 443,
        'uuid': 'b831381d-6324-4d53-ad4f-8cda48b30811',
        'tls': {'enabled': true, 'server_name': 'a.example.com', 'ech': {}},
        'transport': {},
      };
      final res = settleSanitized('vless', raw, _sanitize(raw), authored: true);
      expect(res.body, raw);
      expect([
        for (final w in res.warnings) '${w.code}@${w.path}:${w.applied}',
      ], ['field_missing@transport.type:false']);
    });

    test('сквозной `{}` под `*` остаётся', () {
      final r = _sanitize({
        'type': 'openconnect',
        'tag': 'x',
        'server': 'fw.example.com',
        'csd': {},
        'tls': {'server_name': 'fw.example.com', 'hip': {}},
      });
      expect(_codes(r), isEmpty);
      expect(r.body!['csd'], <String, dynamic>{});
      expect((r.body!['tls'] as Map)['hip'], <String, dynamic>{});
    });
  });

  test('структура: запись `*` — только desc_*/impl и стоит в order; в путях '
      'связей и условий `*` нет', () {
    final bad = <String>[];
    const relKeys = {
      'conflicts',
      'requires',
      'advisory',
      'required_unless',
      'visible_when',
      'when',
      'exit_capable_when',
      'choices',
      'relations',
    };
    bool hasStar(String s) => s.split('.').contains(kWildcardField);
    void scanPaths(Object? n, String at) {
      if (n is String && hasStar(n)) bad.add('$at: путь со звёздочкой «$n»');
      if (n is List) {
        for (final e in n) {
          scanPaths(e, at);
        }
      }
      if (n is Map) {
        for (final e in n.entries) {
          if (hasStar('${e.key}')) bad.add('$at: ключ условия «${e.key}»');
          scanPaths(e.value, '$at.${e.key}');
        }
      }
    }

    void walk(Object? n, String at) {
      if (n is List) {
        for (var i = 0; i < n.length; i++) {
          walk(n[i], '$at[$i]');
        }
        return;
      }
      if (n is! Map) return;
      final fields = n['fields'];
      if (fields is Map && fields.containsKey(kWildcardField)) {
        final w = fields[kWildcardField];
        final extra = (w is Map ? w.keys.map((k) => '$k') : ['<не объект>'])
            .where((k) => !const {'desc_en', 'desc_ru', 'impl'}.contains(k));
        if (extra.isNotEmpty) bad.add('$at.fields.*: лишние ключи $extra');
        final order = n['order'];
        if (order is! List || !order.contains(kWildcardField)) {
          bad.add('$at: `*` в fields, но не в order');
        }
      }
      for (final e in n.entries) {
        if (relKeys.contains(e.key)) scanPaths(e.value, '$at.${e.key}');
        walk(e.value, '$at.${e.key}');
      }
    }

    var files = 0;
    for (final f
        in Directory('$kRegistryRoot/registry')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))) {
      files++;
      walk(jsonDecode(f.readAsStringSync()), f.uri.pathSegments.last);
    }
    expect(files, greaterThan(0));
    expect(bad, isEmpty, reason: bad.join('\n'));
  });

  group('wildcard не наследуется', () {
    late Directory tmp;

    setUpAll(() async {
      // Копия зеркала реестра, где у `openconnect.tls` снят свой `*`: корень
      // остаётся нестрогим, `tls` — строгий.
      tmp = await Directory.systemTemp.createTemp('wildcard_');
      await _copyDir(Directory(kRegistryRoot), tmp);
      final f = File('${tmp.path}/registry/protocols/openconnect.json');
      final j = (jsonDecode(f.readAsStringSync()) as Map)
          .cast<String, dynamic>();
      final tls = (((j['body'] as Map)['fields'] as Map)['tls'] as Map);
      (tls['fields'] as Map).remove(kWildcardField);
      (tls['order'] as List).remove(kWildcardField);
      f.writeAsStringSync(jsonEncode(j));
      ContractRegistry.I.resetForTesting();
      await ContractRegistry.I.loadFromDirectory(tmp.path);
    });

    tearDownAll(() async {
      ContractRegistry.I.resetForTesting();
      await tmp.delete(recursive: true);
    });

    test(
      'корень с `*`, `tls` без своего — unknown_key только во вложенном',
      () {
        final r = _sanitize({
          'type': 'openconnect',
          'tag': 'x',
          'server': 'fw.example.com',
          'x_future': 1,
          'tls': {'server_name': 'a', 'mca_key_path': '/k'},
        });
        expect(_codes(r), ['unknown_key@tls.mca_key_path']);
        expect(r.body!['x_future'], 1);
        expect(r.body!['tls'], {'server_name': 'a'});
      },
    );
  });
}

Future<void> _copyDir(Directory from, Directory to) async {
  await for (final e in from.list(recursive: true)) {
    if (e is! File) continue;
    final rel = e.path.substring(from.path.length + 1);
    final dst = File('${to.path}/$rel');
    await dst.parent.create(recursive: true);
    await e.copy(dst.path);
  }
}
