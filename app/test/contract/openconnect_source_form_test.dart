import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/contract/form_source_sync.dart';
import 'package:lxbox/services/contract/registry_form.dart';

import '../contract_paths.dart';

/// §654 B2 — форма OpenConnect над текстом Source правки узла: тело формы —
/// разбор текста ([formBodyFromSource]), правка поля — новый текст
/// ([sourceWithFormBody]) в прежнем формате, прочие ключи не теряются.
const _compact =
    '{"type":"openconnect","tag":"forti",'
    '"server":"https://fw.example.com:42319","flavor":"fortinet",'
    '"username":"user","password":"secret","token":{"mode":"totp"},'
    '"cookie":"c=1","detour":"proxy",'
    '"tls":{"client_certificate_path":"/a.pem","client_key_path":"/a.key",'
    '"insecure":true},"x_passthrough":7}';

/// Правка «полем формы»: текст → тело → withFormValue → текст.
String _edit(String source, String path, Object? value) {
  final body = formBodyFromSource(source)!;
  return sourceWithFormBody(source, withFormValue(body, path, value));
}

void main() {
  setUpAll(loadTestRegistry);

  group('formBodyFromSource', () {
    test('объект JSON — тело целиком, с type/tag', () {
      final body = formBodyFromSource(_compact)!;
      expect(body['type'], 'openconnect');
      expect(body['tag'], 'forti');
      expect(formValueAt(body, 'tls.insecure'), true);
    });

    test('не объект — форма неактивна (null)', () {
      expect(formBodyFromSource(''), isNull);
      expect(formBodyFromSource('{"server": '), isNull);
      expect(formBodyFromSource('[1, 2]'), isNull);
      expect(formBodyFromSource('"str"'), isNull);
      expect(formBodyFromSource('openconnect://fw.example.com'), isNull);
      expect(formBodyFromSource('{"a": 1} // comment'), isNull);
      expect(formBodyFromSource('[Interface]\nPrivateKey = x'), isNull);
    });

    test('документ с outbounds/endpoints — не тело узла', () {
      expect(
        formBodyFromSource('{"endpoints": [{"type": "openconnect"}]}'),
        isNull,
      );
      expect(formBodyFromSource('{"outbounds": []}'), isNull);
    });
  });

  group('sourceWithFormBody', () {
    test('компактный остаётся компактным, порядок ключей прежний', () {
      final out = _edit(_compact, 'username', 'other');
      expect(out.contains('\n'), isFalse);
      expect(out, _compact.replaceFirst('"user"', '"other"'));
    });

    test('многострочный — с прежним отступом', () {
      final pretty = const JsonEncoder.withIndent(
        '    ',
      ).convert(jsonDecode(_compact));
      final out = _edit(pretty, 'server', 'vpn.example.com:443');
      expect(
        out,
        pretty.replaceFirst(
          'https://fw.example.com:42319',
          'vpn.example.com:443',
        ),
      );
    });

    test('новый ключ — в конец, вложенный — в конец своего объекта', () {
      var out = _edit(_compact, 'mtu', 1400);
      expect((jsonDecode(out) as Map).keys.last, 'mtu');
      out = _edit(out, 'tls.server_name', 'sni.example.com');
      final tls = (jsonDecode(out) as Map)['tls'] as Map;
      expect(tls.keys.toList(), [
        'client_certificate_path',
        'client_key_path',
        'insecure',
        'server_name',
      ]);
    });

    test('пустое значение снимает ключ, неформенные ключи не теряются', () {
      final out = jsonDecode(_edit(_compact, 'password', null)) as Map;
      expect(out.containsKey('password'), isFalse);
      expect(out['token'], {'mode': 'totp'});
      expect(out['cookie'], 'c=1');
      expect(out['detour'], 'proxy');
      expect(out['x_passthrough'], 7);
      expect((out['tls'] as Map)['client_certificate_path'], '/a.pem');
      expect((out['tls'] as Map)['client_key_path'], '/a.key');
    });

    test('вариант сертификата: tls.client_* остаются', () {
      final layout = formLayoutFor('openconnect')!;
      final cert = layout.choice('server_cert_check')!;
      final body = formBodyFromSource(_compact)!;
      final out =
          jsonDecode(
                sourceWithFormBody(
                  _compact,
                  applyFormOption(body, cert, 'system'),
                ),
              )
              as Map;
      final tls = out['tls'] as Map;
      expect(tls.containsKey('insecure'), isFalse);
      expect(tls['client_certificate_path'], '/a.pem');
      expect(tls['client_key_path'], '/a.key');
      expect(out['token'], {'mode': 'totp'});
    });

    test('type и tag берутся из прежнего текста', () {
      final body = formBodyFromSource(_compact)!
        ..['type'] = 'other'
        ..remove('tag');
      final out = jsonDecode(sourceWithFormBody(_compact, body)) as Map;
      expect(out['type'], 'openconnect');
      expect(out['tag'], 'forti');
    });

    test('та же правка — тот же текст (эхо формы текст не меняет)', () {
      final body = formBodyFromSource(_compact)!;
      expect(sourceWithFormBody(_compact, body), _compact);
    });
  });
}
