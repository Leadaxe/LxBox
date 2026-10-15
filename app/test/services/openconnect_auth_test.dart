// §654 C — чистая логика второго фактора и SSO openconnect.
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/openconnect_auth.dart';
import 'package:lxbox/vpn/cc_openconnect.dart';

CcOpenConnectChallenge _form(
  String id, {
  String error = '',
  List<CcOpenConnectField> fields = const [
    CcOpenConnectField(name: 'code', kind: 'text'),
  ],
}) => CcOpenConnectChallenge(id: id, error: error, form: fields);

const _passwordForm = [
  CcOpenConnectField(name: 'username', kind: 'text', value: 'user'),
  CcOpenConnectField(name: 'password', kind: 'password'),
];

void main() {
  group('callbackURLPrefixes → port', () {
    test('prefix without port → 8020', () {
      expect(openConnectCallbackPort(['http://127.0.0.1:']), 8020);
      expect(openConnectCallbackPort(['http://127.0.0.1/']), 8020);
      expect(openConnectCallbackPort(const []), 8020);
    });

    test('port from prefix', () {
      expect(openConnectCallbackPort(['http://127.0.0.1:9000/']), 9000);
      expect(openConnectCallbackPort(['http://localhost:8443']), 8443);
      expect(
        openConnectCallbackPort(['http://127.0.0.1:', 'http://[::1]:7000/']),
        7000,
      );
    });

    test('out-of-range or garbage port → default', () {
      expect(openConnectCallbackPort(['http://127.0.0.1:0/']), 8020);
      expect(openConnectCallbackPort(['http://127.0.0.1:70000/']), 8020);
      expect(openConnectCallbackPort(['http://127.0.0.1:abc/']), 8020);
    });
  });

  group('loopback-only prefixes', () {
    test('loopback http hosts', () {
      expect(openConnectCallbackLoopbackOnly(['http://127.0.0.1:']), isTrue);
      expect(
        openConnectCallbackLoopbackOnly(['HTTP://localhost:8020/']),
        isTrue,
      );
      expect(openConnectCallbackLoopbackOnly(['http://127.0.0.2:9/']), isTrue);
    });

    test('empty, https, foreign host, IPv6 → not supported', () {
      expect(openConnectCallbackLoopbackOnly(const []), isFalse);
      expect(openConnectCallbackLoopbackOnly(['https://127.0.0.1:']), isFalse);
      expect(openConnectCallbackLoopbackOnly(['http://example.com/']), isFalse);
      expect(openConnectCallbackLoopbackOnly(['http://[::1]:8020/']), isFalse);
      expect(
        openConnectCallbackLoopbackOnly([
          'http://127.0.0.1:',
          'http://gw.example.com/',
        ]),
        isFalse,
      );
    });
  });

  group('dialog kind', () {
    test('none for missing or empty challenge', () {
      expect(openConnectAuthKind(null), OpenConnectAuthKind.none);
      expect(
        openConnectAuthKind(const CcOpenConnectChallenge(id: '')),
        OpenConnectAuthKind.none,
      );
    });

    test('form', () {
      expect(openConnectAuthKind(_form('1')), OpenConnectAuthKind.form);
    });

    test('browser callback (FortiGate SAML)', () {
      const c = CcOpenConnectChallenge(
        id: '2',
        browser: CcOpenConnectBrowser(
          url: 'https://gw.example.com/remote/saml/start',
          callbackUrlPrefixes: ['http://127.0.0.1:'],
        ),
      );
      expect(openConnectAuthKind(c), OpenConnectAuthKind.browserCallback);
    });

    test('browser cookie mode (AnyConnect) → unsupported', () {
      const c = CcOpenConnectChallenge(
        id: '3',
        browser: CcOpenConnectBrowser(
          url: 'https://gw.example.com/+CSCOE+/saml/sp/login',
          cookieNames: ['acSamlv2Token'],
        ),
      );
      expect(openConnectAuthKind(c), OpenConnectAuthKind.browserUnsupported);
    });
  });

  test('sign-in link must be http(s) with host', () {
    expect(openConnectWebUrl('https://gw.example.com/x'), isTrue);
    expect(openConnectWebUrl('http://gw.example.com'), isTrue);
    expect(openConnectWebUrl('intent://x'), isFalse);
    expect(openConnectWebUrl('javascript:alert(1)'), isFalse);
    expect(openConnectWebUrl(''), isFalse);
  });

  group('form response', () {
    test('submission key wins over name, edits over gateway value', () {
      const fields = [
        CcOpenConnectField(name: 'username', value: 'user'),
        CcOpenConnectField(name: 'code', submissionKey: 'credential'),
        CcOpenConnectField(name: 'realm', kind: 'select', value: 'a'),
        CcOpenConnectField(label: 'no key'),
      ];
      final values = openConnectFormValues(fields, {'credential': '123456'});
      expect(values.map((e) => '${e.key}=${e.value}').toList(), [
        'username=user',
        'credential=123456',
        'realm=a',
      ]);
    });

    test('password field detection', () {
      expect(
        openConnectFormAsksPassword(_form('1', fields: _passwordForm)),
        isTrue,
      );
      expect(
        openConnectFormAsksPassword(
          _form(
            '1',
            fields: const [CcOpenConnectField(name: 'code', kind: 'password')],
          ),
        ),
        isFalse,
      );
      expect(openConnectFormAsksPassword(_form('1')), isFalse);
    });
  });

  group('wrong code streak', () {
    test('two wrong codes in a row on one node → warn', () {
      final t = OpenConnectWrongCodeTracker();
      t.challenge('fw', _form('1'));
      t.submitted('fw', '1');
      t.challenge('fw', _form('2', error: 'Invalid code'));
      expect(t.streak('fw'), 1);
      expect(t.shouldWarn('fw'), isFalse);
      t.submitted('fw', '2');
      t.challenge('fw', _form('3', error: 'Invalid code'));
      expect(t.shouldWarn('fw'), isTrue);
      expect(t.shouldWarn('other'), isFalse);
    });

    test('same challenge again does not count', () {
      final t = OpenConnectWrongCodeTracker();
      t.submitted('fw', '1');
      t.challenge('fw', _form('1', error: 'x'));
      expect(t.streak('fw'), 0);
    });

    test('new challenge without a submit does not count', () {
      final t = OpenConnectWrongCodeTracker();
      t.challenge('fw', _form('1', error: 'x'));
      t.challenge('fw', _form('2', error: 'x'));
      expect(t.streak('fw'), 0);
    });

    test('wrong password form, cancel and connect reset the streak', () {
      final t = OpenConnectWrongCodeTracker();
      t.submitted('fw', '1');
      t.challenge('fw', _form('2', error: 'bad'));
      t.submitted('fw', '2');
      t.challenge('fw', _form('3', error: 'bad', fields: _passwordForm));
      expect(t.streak('fw'), 0);

      t.submitted('fw', '3');
      t.challenge('fw', _form('4', error: 'bad'));
      expect(t.streak('fw'), 1);
      t.cancelled('fw');
      expect(t.streak('fw'), 0);

      t.submitted('fw', '4');
      t.challenge('fw', _form('5', error: 'bad'));
      t.connected('fw');
      expect(t.streak('fw'), 0);
    });
  });

  group('row label', () {
    test('pending challenge → waiting', () {
      const s = CcOpenConnectStatus(
        tag: 'fw',
        state: 'connecting',
        challenge: CcOpenConnectChallenge(id: '1'),
      );
      expect(openConnectRowState(s).kind, OpenConnectRowKind.waiting);
      expect(
        openConnectRowState(
          const CcOpenConnectStatus(tag: 'fw', state: 'auth-pending'),
        ).kind,
        OpenConnectRowKind.waiting,
      );
    });

    test('error → core text, falls back to state text', () {
      final a = openConnectRowState(
        const CcOpenConnectStatus(
          tag: 'fw',
          state: 'error',
          error: ' authentication failed ',
        ),
      );
      expect(a.kind, OpenConnectRowKind.error);
      expect(a.text, 'authentication failed');
      final b = openConnectRowState(
        const CcOpenConnectStatus(
          tag: 'fw',
          state: 'error',
          stateText: 'certificate rejected',
        ),
      );
      expect(b.text, 'certificate rejected');
    });

    test('connected or unknown → nothing', () {
      expect(
        openConnectRowState(
          const CcOpenConnectStatus(tag: 'fw', state: 'connected'),
        ).kind,
        OpenConnectRowKind.none,
      );
      expect(openConnectRowState(null).kind, OpenConnectRowKind.none);
    });
  });

  test('snapshot from channel map', () {
    final snap = CcOpenConnectSnapshot.fromObject({
      'endpoints': [
        {
          'tag': 'fw',
          'state': 'auth-pending',
          'challenge': {
            'id': 'c1',
            'message': 'Enter the code',
            'form': [
              {
                'name': 'code',
                'kind': 'select',
                'options': [
                  {'value': 'a', 'label': 'A'},
                ],
              },
            ],
          },
        },
        {
          'tag': 'gw',
          'state': 'connected',
          'challenge': {'id': ''},
        },
        {'tag': '', 'state': 'connected'},
      ],
      'callback': {'tag': 'fw', 'challenge_id': 'c1', 'state': 'listening'},
    });
    expect(snap.endpoints.keys, ['fw', 'gw']);
    final c = snap.endpoints['fw']!.challenge!;
    expect(c.id, 'c1');
    expect(c.form!.single.options.single.label, 'A');
    expect(snap.endpoints['gw']!.challenge, isNull);
    expect(snap.callback!.state, 'listening');
    expect(CcOpenConnectSnapshot.fromObject(null).endpoints, isEmpty);
  });
}
