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

    test('URL без host → `***`', () {
      expect(maskSubscriptionUrl('file:///local/path'), '***');
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
          'auto_rebuild': 'true',
          'unknown_new_key': 'value',
        },
      };
      final out = serializeStorageCache(cache);
      final vars = out['vars'] as Map;
      expect(vars['debug_enabled'], 'true');
      expect(vars['auto_rebuild'], 'true');
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

    test('server_lists: URL маскируется, nodes → count, rawBody → length', () {
      final cache = {
        'server_lists': [
          {
            'id': '1',
            'url': 'https://prov/sub/token',
            'nodes': [
              {'tag': 'n1'},
              {'tag': 'n2'},
            ],
            'rawBody': 'vless://uuid@host:443#tag',
          },
        ],
      };
      final out = serializeStorageCache(cache);
      final lists = out['server_lists'] as List;
      expect(lists[0]['url'], 'https://prov/***');
      expect(lists[0]['nodes_count'], 2);
      expect(lists[0]['raw_body_bytes'], 25);
      expect((lists[0] as Map).containsKey('nodes'), isFalse);
      expect((lists[0] as Map).containsKey('rawBody'), isFalse);
    });

    test('пустой cache → пустая мапа', () {
      expect(serializeStorageCache({}), isEmpty);
    });
  });
}
