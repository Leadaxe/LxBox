import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/builder/post_steps.dart';

Map<String, dynamic> _outbound({
  required String serverName,
  bool tlsEnabled = true,
  bool isDetour = false,
  bool? reality,
}) =>
    {
      'tag': 'test',
      'type': 'vless',
      if (isDetour) 'detour': 'parent',
      'tls': {
        'enabled': tlsEnabled,
        'server_name': serverName,
        if (reality != null)
          'reality': {
            'enabled': reality,
            'public_key': 'HYmfuVfjxEcHl6AkNr3WV1C0GfeAEXnBkIBJ31PYvXc',
            'short_id': 'a1b2c3d4',
          },
      },
    };

Map<String, dynamic> _config(List<Map<String, dynamic>> outbounds) => {
      'outbounds': outbounds,
    };

void main() {
  group('applyMixedCaseSni', () {
    test('skip when toggle off', () {
      final cfg = _config([_outbound(serverName: 'www.youtube.com')]);
      applyMixedCaseSni(cfg, {'tls_mixed_case_sni': 'false'});
      expect(
        ((cfg['outbounds'] as List)[0] as Map)['tls']['server_name'],
        'www.youtube.com',
      );
    });

    test('skip when var missing', () {
      final cfg = _config([_outbound(serverName: 'www.youtube.com')]);
      applyMixedCaseSni(cfg, const {});
      expect(
        ((cfg['outbounds'] as List)[0] as Map)['tls']['server_name'],
        'www.youtube.com',
      );
    });

    test('case-insensitively equal to original (RFC compliance)', () {
      final cfg = _config([_outbound(serverName: 'www.example.com')]);
      applyMixedCaseSni(cfg, {'tls_mixed_case_sni': 'true'});
      final after = ((cfg['outbounds'] as List)[0] as Map)['tls']['server_name']
          as String;
      expect(after.toLowerCase(), 'www.example.com');
    });

    test('produces mixed case (not all-lower / not all-upper) over many trials',
        () {
      // Probabilistic: 13 letters в "www.example.com" (без точек)
      // → шанс получить полностью lower или upper ничтожен
      var hadVariation = false;
      for (var i = 0; i < 5; i++) {
        final cfg = _config([_outbound(serverName: 'www.example.com')]);
        applyMixedCaseSni(cfg, {'tls_mixed_case_sni': 'true'});
        final s = ((cfg['outbounds'] as List)[0] as Map)['tls']['server_name']
            as String;
        if (s != s.toLowerCase() && s != s.toUpperCase()) {
          hadVariation = true;
          break;
        }
      }
      expect(hadVariation, isTrue,
          reason: 'No mixed case in 5 randomizations — RNG broken?');
    });

    test('IP literal unchanged', () {
      final cfg = _config([_outbound(serverName: '192.168.1.1')]);
      applyMixedCaseSni(cfg, {'tls_mixed_case_sni': 'true'});
      expect(
        ((cfg['outbounds'] as List)[0] as Map)['tls']['server_name'],
        '192.168.1.1',
      );
    });

    test('punycode label preserved (xn-- prefix)', () {
      // xn--e1aybc.xn--p1ai = "тест.рф" в ACE
      final cfg = _config([_outbound(serverName: 'xn--e1aybc.xn--p1ai')]);
      applyMixedCaseSni(cfg, {'tls_mixed_case_sni': 'true'});
      expect(
        ((cfg['outbounds'] as List)[0] as Map)['tls']['server_name'],
        'xn--e1aybc.xn--p1ai',
        reason: 'Punycode labels must not be touched',
      );
    });

    test('mixed punycode + ASCII: only ASCII labels randomized', () {
      // sub.xn--e1aybc.com — punycode label не трогаем, остальные — да
      final cfg = _config([_outbound(serverName: 'sub.xn--e1aybc.com')]);
      applyMixedCaseSni(cfg, {'tls_mixed_case_sni': 'true'});
      final after = ((cfg['outbounds'] as List)[0] as Map)['tls']['server_name']
          as String;
      final parts = after.split('.');
      expect(parts[1], 'xn--e1aybc');
      expect(after.toLowerCase(), 'sub.xn--e1aybc.com');
    });

    test('detour outbound NOT touched', () {
      final cfg = _config([
        _outbound(serverName: 'first.example.com'),
        _outbound(serverName: 'inner.example.com', isDetour: true),
      ]);
      applyMixedCaseSni(cfg, {'tls_mixed_case_sni': 'true'});
      final inner =
          ((cfg['outbounds'] as List)[1] as Map)['tls']['server_name'];
      expect(inner, 'inner.example.com',
          reason: 'detour (inner hop) outbound must stay untouched');
    });

    test('outbound without tls.server_name skipped', () {
      final cfg = _config([
        {'tag': 'a', 'type': 'shadowsocks'}, // нет tls
        _outbound(serverName: ''), // пустой server_name
      ]);
      applyMixedCaseSni(cfg, {'tls_mixed_case_sni': 'true'});
      // Не должно быть исключений
      expect(((cfg['outbounds'] as List)[1] as Map)['tls']['server_name'], '');
    });

    test('two outbounds get independent randomization', () {
      // Очень малый шанс что две независимые рандомизации одного хоста совпадут
      var foundDifferent = false;
      for (var i = 0; i < 5; i++) {
        final cfg = _config([
          _outbound(serverName: 'aaaaaaaa.example.com'),
          _outbound(serverName: 'aaaaaaaa.example.com'),
        ]);
        applyMixedCaseSni(cfg, {'tls_mixed_case_sni': 'true'});
        final a = ((cfg['outbounds'] as List)[0] as Map)['tls']['server_name'];
        final b = ((cfg['outbounds'] as List)[1] as Map)['tls']['server_name'];
        if (a != b) {
          foundDifferent = true;
          break;
        }
      }
      expect(foundDifferent, isTrue,
          reason: 'Two outbounds with same server_name produced identical '
              'randomization 5 times — likely shared RNG state bug');
    });

    // §363 — REALITY: SNI входит в AAD хендшейка, сервер матчит имя по map с
    // точным ключом без нормализации регистра. Рандомизация = мёртвый узел.
    group('§363 REALITY', () {
      test('reality outbound NOT touched', () {
        final cfg = _config([
          _outbound(serverName: 'ya.ru', reality: true),
        ]);
        applyMixedCaseSni(cfg, {'tls_mixed_case_sni': 'true'});
        expect(
          ((cfg['outbounds'] as List)[0] as Map)['tls']['server_name'],
          'ya.ru',
          reason: 'REALITY server_name must stay byte-identical',
        );
      });

      test('reality disabled → randomized as plain TLS', () {
        // Гейт по флагу reality.enabled, а не по наличию ключа reality.
        var hadVariation = false;
        for (var i = 0; i < 5; i++) {
          final cfg = _config([
            _outbound(serverName: 'www.example.com', reality: false),
          ]);
          applyMixedCaseSni(cfg, {'tls_mixed_case_sni': 'true'});
          final s =
              ((cfg['outbounds'] as List)[0] as Map)['tls']['server_name']
                  as String;
          expect(s.toLowerCase(), 'www.example.com');
          if (s != s.toLowerCase() && s != s.toUpperCase()) {
            hadVariation = true;
            break;
          }
        }
        expect(hadVariation, isTrue,
            reason: 'reality.enabled=false must not gate randomization');
      });

      test('gate is per-outbound: plain TLS neighbour still randomized', () {
        var hadVariation = false;
        for (var i = 0; i < 5; i++) {
          final cfg = _config([
            _outbound(serverName: 'ya.ru', reality: true),
            _outbound(serverName: 'www.example.com'),
          ]);
          applyMixedCaseSni(cfg, {'tls_mixed_case_sni': 'true'});
          final obs = cfg['outbounds'] as List;
          expect((obs[0] as Map)['tls']['server_name'], 'ya.ru');
          final plain = (obs[1] as Map)['tls']['server_name'] as String;
          expect(plain.toLowerCase(), 'www.example.com');
          if (plain != plain.toLowerCase() && plain != plain.toUpperCase()) {
            hadVariation = true;
            break;
          }
        }
        expect(hadVariation, isTrue,
            reason: 'REALITY outbound must not disable the whole post-step');
      });

      test('reality without server_name does not throw', () {
        final cfg = _config([
          {
            'tag': 'a',
            'type': 'vless',
            'tls': {
              'enabled': true,
              'reality': {'enabled': true},
            },
          },
          _outbound(serverName: '', reality: true),
        ]);
        applyMixedCaseSni(cfg, {'tls_mixed_case_sni': 'true'});
        expect(((cfg['outbounds'] as List)[1] as Map)['tls']['server_name'], '');
      });
    });
  });
}
