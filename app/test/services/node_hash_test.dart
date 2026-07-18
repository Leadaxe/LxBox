import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §283 — identity-хеш ноды: стабилен через reparse и переименования,
/// меняется при смене сути; TTL-порог и GC отметок disable.
void main() {
  group('nodeIdentityHash', () {
    const uri = 'vless://0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c@h.example:443'
        '?type=ws&security=tls&sni=x.com&fp=chrome#Label';

    test('один и тот же URI при повторном парсе → одинаковый хеш', () {
      final a = parseVless(uri)!;
      final b = parseVless(uri)!;
      expect(a.id == b.id, isFalse, reason: 'id эфемерен — новый на парс');
      expect(nodeIdentityHash(a), nodeIdentityHash(b));
    });

    test('смена только ремарки (#label → tag) хеш НЕ меняет', () {
      final a = parseVless(uri)!;
      final b = parseVless(uri.replaceFirst('#Label', '#Renamed%20NL-42'))!;
      expect(a.tag == b.tag, isFalse);
      expect(nodeIdentityHash(a), nodeIdentityHash(b));
    });

    test('смена сути (uuid / порт) хеш меняет', () {
      final a = parseVless(uri)!;
      final otherUuid = parseVless(uri.replaceFirst('0aa41f0a', '1bb52f1b'))!;
      final otherPort = parseVless(uri.replaceFirst(':443', ':8443'))!;
      expect(nodeIdentityHash(a), isNot(nodeIdentityHash(otherUuid)));
      expect(nodeIdentityHash(a), isNot(nodeIdentityHash(otherPort)));
    });

    test('chained-цепочка (detour) в хеш не входит', () {
      Map<String, dynamic> xray({required bool withJump}) => {
            'remarks': 'L',
            'outbounds': [
              {
                'protocol': 'vless',
                'tag': 'proxy',
                'settings': {
                  'vnext': [
                    {
                      'address': 'h.example',
                      'port': 443,
                      'users': [
                        {'id': '0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c'}
                      ],
                    }
                  ],
                },
                'streamSettings': {
                  'network': 'ws',
                  'security': 'tls',
                  'tlsSettings': {'serverName': 'x.com'},
                  if (withJump) 'sockopt': {'dialerProxy': 'jump'},
                },
              },
              if (withJump)
                {
                  'protocol': 'socks',
                  'tag': 'jump',
                  'settings': {
                    'servers': [
                      {'address': 'j.example', 'port': 1080},
                    ],
                  },
                },
            ],
          };
      final chained = parseXrayOutbound(xray(withJump: true))!;
      final plain = parseXrayOutbound(xray(withJump: false))!;
      expect(chained.chained, isNotNull, reason: 'фикстура с цепочкой');
      expect(nodeIdentityHash(chained), nodeIdentityHash(plain));
    });
  });

  group('deepSortKeys', () {
    test('детерминированная сериализация независимо от порядка ключей', () {
      final a = {
        'b': 1,
        'a': {
          'd': [
            {'z': 1, 'y': 2}
          ],
          'c': 3,
        },
      };
      final b = {
        'a': {
          'c': 3,
          'd': [
            {'y': 2, 'z': 1}
          ],
        },
        'b': 1,
      };
      expect(jsonEncode(deepSortKeys(a)), jsonEncode(deepSortKeys(b)));
      expect(jsonEncode(deepSortKeys(a)),
          '{"a":{"c":3,"d":[{"y":2,"z":1}]},"b":1}');
    });
  });

  group('disabledHashTtl (clamp 3×interval, пол 24ч, потолок месяц)', () {
    test('таблица порогов', () {
      expect(disabledHashTtl(1), const Duration(hours: 24)); // пол
      expect(disabledHashTtl(24), const Duration(hours: 72));
      expect(disabledHashTtl(168), const Duration(hours: 504));
      expect(disabledHashTtl(336), const Duration(hours: 720)); // потолок
      expect(disabledHashTtl(0), const Duration(hours: 24)); // respect-server
      expect(disabledHashTtl(-1), const Duration(hours: 24)); // file:
    });
  });

  group('gcDisabledHashes', () {
    final now = DateTime.utc(2026, 7, 18, 12);

    test('источник найден в свежем теле → lastSeen = now', () {
      final out = gcDisabledHashes(
        {'h1': now.subtract(const Duration(days: 10))},
        {'h1'},
        updateIntervalHours: 24,
        now: now,
      );
      expect(out, {'h1': now});
    });

    test('источник отсутствует, но порог не истёк → отметка на месте', () {
      final lastSeen = now.subtract(const Duration(hours: 71));
      final out = gcDisabledHashes(
        {'h1': lastSeen},
        const {},
        updateIntervalHours: 24, // порог 72ч
        now: now,
      );
      expect(out, {'h1': lastSeen}, reason: 'lastSeen не трогаем без находки');
    });

    test('источник отсутствует дольше порога → отметка удалена', () {
      final out = gcDisabledHashes(
        {'h1': now.subtract(const Duration(hours: 73))},
        const {},
        updateIntervalHours: 24,
        now: now,
      );
      expect(out, isEmpty);
    });

    test('смешанный проход: found/спящий/истёкший за один вызов', () {
      final sleeping = now.subtract(const Duration(hours: 10));
      final out = gcDisabledHashes(
        {
          'found': now.subtract(const Duration(hours: 100)),
          'sleeping': sleeping,
          'expired': now.subtract(const Duration(hours: 100)),
        },
        {'found'},
        updateIntervalHours: 24,
        now: now,
      );
      expect(out, {'found': now, 'sleeping': sleeping});
    });

    test('пустой current → тот же (пустой) без работы', () {
      final current = <String, DateTime>{};
      expect(
          identical(
              gcDisabledHashes(current, {'x'},
                  updateIntervalHours: 24, now: now),
              current),
          isTrue);
    });
  });
}
