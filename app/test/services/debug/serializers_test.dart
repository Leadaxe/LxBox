import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/debug/serializers/storage.dart';
import 'package:lxbox/services/debug/serializers/subs.dart';

void main() {
  group('maskSubscriptionUrl', () {
    test('оставляет только scheme + host', () {
      expect(
        maskSubscriptionUrl('https://provider.com/sub/abc123token'),
        'https://provider.com/***',
      );
    });

    test('пустая строка → пустая', () {
      expect(maskSubscriptionUrl(''), '');
    });

    test('невалидный URL → `***`', () {
      expect(maskSubscriptionUrl('not a url @#%'), '***');
    });

    test('невалидный URL без host → `***`', () {
      // §129: любая `file:`-строка светится как `file:<local>` (см. ниже),
      // поэтому URL-без-host проверяем на data:-схеме — не секрет, но и не хост.
      expect(maskSubscriptionUrl('data:text/plain,x'), '***');
    });

    test('§129 файловая подписка `file:<uuid>` → `file:<local>`', () {
      // Локальный ключ кэша, не секрет и без хоста — светим читаемо, не `***`.
      expect(maskSubscriptionUrl('file:abc-123-uuid'), 'file:<local>');
      expect(maskSubscriptionUrl('file:///local/path'), 'file:<local>');
    });

    test('сохраняет http и https', () {
      expect(maskSubscriptionUrl('http://p.co/path'), 'http://p.co/***');
      expect(maskSubscriptionUrl('https://p.co/path'), 'https://p.co/***');
    });
  });

  group('serializeStorageCache (denylist + scrubber)', () {
    test('debug_token маскируется, остальные vars pass-through', () {
      final cache = {
        'vars': {
          'debug_enabled': 'true',
          'debug_token': 'secret123',
          'auto_update_subs': 'true',
          'unknown_new_key': 'value',
        },
      };
      final out = serializeStorageCache(cache);
      final vars = out['vars'] as Map;
      expect(vars['debug_enabled'], 'true');
      expect(vars['auto_update_subs'], 'true');
      expect(vars['debug_token'], '***',
          reason: 'secret token must always be masked');
      expect(vars['unknown_new_key'], 'value',
          reason: 'new keys default to visible (denylist philosophy)');
    });

    test('пустой debug_token остаётся пустой строкой', () {
      final out = serializeStorageCache({
        'vars': {'debug_token': ''},
      });
      expect((out['vars'] as Map)['debug_token'], '');
    });

    test('неизвестные top-level ключи проходят как есть', () {
      final cache = {
        'route_final': 'vpn-1',
        'excluded_nodes': ['x'],
        'unknown_top_level': 'value',
      };
      final out = serializeStorageCache(cache);
      expect(out['route_final'], 'vpn-1');
      expect(out['excluded_nodes'], ['x']);
      expect(out['unknown_top_level'], 'value',
          reason: 'новые поля видны по умолчанию');
    });

    // §439 A3 — источники читаются моделями репозитория из записи хранения
    // (`raw_body`, `members`), секрет гасится в модели: счётчик встаёт на
    // место поля, битая запись в дамп не попадает.
    test(
        'server_lists: URL маскируется, raw_body → raw_body_bytes, '
        'members → members_count, битая запись пропускается', () {
      final cache = {
        'server_lists': [
          {
            'type': 'subscription',
            'id': 's1',
            'name': 'Sub',
            'url': 'https://prov/sub/token',
          },
          {
            'type': 'user',
            'id': 'u1',
            'name': 'Mine',
            'origin': 'manual',
            'created_at': '2026-01-01T00:00:00.000',
            'raw_body': 'vless://uuid@host:443#tag',
          },
          {
            'type': 'folder',
            'id': 'f1',
            'name': 'Folder',
            'created_at': '2026-01-01T00:00:00.000',
            'members': [
              {'raw': 'vless://m1-secret@a:443#a', 'enabled': true},
              {'raw': 'vless://m2-secret@b:443#b', 'enabled': false},
            ],
          },
          {'id': 'broken', 'url': 'https://prov/sub/broken-token'},
        ],
      };
      final out = serializeStorageCache(cache);
      final lists = (out['server_lists'] as List).cast<Map>();
      expect([for (final l in lists) l['id']], ['s1', 'u1', 'f1']);

      expect(lists[0]['url'], 'https://prov/***');

      expect(lists[1]['raw_body_bytes'], 25);
      expect(lists[1].containsKey('raw_body'), isFalse);
      final userKeys = lists[1].keys.toList();
      expect(userKeys.last, 'raw_body_bytes',
          reason: 'счётчик на месте raw_body');

      expect(lists[2]['members_count'], 2);
      expect(lists[2].containsKey('members'), isFalse);
      final folderKeys = lists[2].keys.toList();
      expect(folderKeys.indexOf('members_count'),
          folderKeys.indexOf('created_at') + 1,
          reason: 'счётчик на месте members');

      final dump = jsonEncode(out);
      for (final secret in [
        'sub/token',
        'uuid@host',
        'm1-secret',
        'm2-secret',
        'broken-token',
      ]) {
        expect(dump, isNot(contains(secret)));
      }
    });

    test('§219 — warp_account/masque_account НЕ маскируются (root by design)', () {
      // Намеренно: Debug API даёт полный root-доступ к секретам за токеном
      // (те же приватники доступны сырыми через /backup/export). Scrubber тут —
      // UX-удобство, не security-граница. НЕ добавлять маскировку этих ключей
      // как «security-фикс» — см. serializers/storage.dart докстринг.
      final cache = {
        'warp_account': {'private_key': 'wp-secret'},
        'masque_account': {'priv_key_der': 'mp-secret', 'token': 't'},
      };
      final out = serializeStorageCache(cache);
      expect((out['warp_account'] as Map)['private_key'], 'wp-secret');
      expect((out['masque_account'] as Map)['priv_key_der'], 'mp-secret');
    });

    test('пустой cache → пустая мапа', () {
      expect(serializeStorageCache({}), isEmpty);
    });
  });
}
