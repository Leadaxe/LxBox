import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/subscription_meta.dart';
import 'package:lxbox/services/subscription/sources.dart';

import '../parser/engine_test_setup.dart';

/// §648 — описание подписки из заголовка `announce`.
void main() {
  setUpAll(loadEngineSections);
  tearDownAll(unloadEngineSections);

  // Пример владельца (Liberty VPN): легенда к эмодзи в именах узлов.
  const legendB64 = 'base64:4pqhIOKAlCDQm9GD0YfRiNC40LUg0YHQtdGA0LLQtdGA0LAK'
      '8J+SsyDigJQg0JfQsNGA0YPQsdC10LbQvdCw0Y8g0L7Qv9C70LDRgtCwCvCfjq4g4oCUINCf'
      '0J7QlNCl0J7QlNCv0KIg0JTQm9CvINCY0JPQoArwn5OLIOKAlCDQkdCV0JvQq9CVINCh0J/Q'
      'mNCh0JrQmCDQkiDQodCQ0JzQntCcINCd0JjQl9CjCg==';
  const legend = '⚡ — Лучшие сервера\n'
      '💳 — Зарубежная оплата\n'
      '🎮 — ПОДХОДЯТ ДЛЯ ИГР\n'
      '📋 — БЕЛЫЕ СПИСКИ В САМОМ НИЗУ';

  String? announceOf(String body, Map<String, String> headers) =>
      parseFetched(FetchResult(body, null, headers)).meta?.announce;

  group('разбор заголовка', () {
    test('base64: → четыре строки легенды', () {
      final a = announceOf('', {'announce': legendB64});
      expect(a, legend);
      expect(a!.split('\n'), hasLength(4));
    });

    test('открытый текст берётся как есть, регистр имени не важен', () {
      expect(announceOf('', {'Announce': 'Hello\nworld'}), 'Hello\nworld');
    });

    test('\\r\\n → \\n, края обрезаны, >2 переводов строки схлопнуты', () {
      expect(parseAnnounceHeader('  a\r\nb\r\n\r\n\r\n\r\nc  \r\n'),
          'a\nb\n\nc');
    });

    test('пустое значение → поля нет', () {
      expect(parseAnnounceHeader('   '), isNull);
      expect(parseAnnounceHeader('base64:'), isNull);
      expect(announceOf('', {'announce': ''}), isNull);
    });

    test('битый base64 → поля нет, остальные метаданные на месте', () {
      final meta = parseFetched(FetchResult('', null,
          {'announce': 'base64:@@@', 'profile-title': 'Sub'})).meta;
      expect(meta?.announce, isNull);
      expect(meta?.profileTitle, 'Sub');
    });

    test('длинный текст обрезается до предела графем', () {
      final long = '🎮' * (kAnnounceMaxGraphemes + 50);
      final a = parseAnnounceHeader(long)!;
      expect(a.runes.length, kAnnounceMaxGraphemes);
    });

    test('ключ из комментария тела при отсутствии заголовка', () {
      const body = '# announce: from body\nvless://x@a.example:443#n\n';
      expect(announceOf(body, const {}), 'from body');
    });

    test('HTTP-заголовок приоритетнее тела', () {
      const body = '# announce: from body\n';
      expect(announceOf(body, {'announce': 'from header'}), 'from header');
    });

    test('только announce → meta не null', () {
      final meta =
          parseFetched(FetchResult('', null, {'announce': 'x'})).meta;
      expect(meta, isNotNull);
      expect(meta!.announce, 'x');
    });
  });

  group('SubscriptionMeta JSON', () {
    test('с полем — круг через JSON', () {
      const m = SubscriptionMeta(profileTitle: 'T', announce: 'a\nb');
      final j = m.toJson();
      expect(j['announce'], 'a\nb');
      expect(SubscriptionMeta.fromJson(j), m);
    });

    test('без поля — ключа нет, старый JSON читается', () {
      const m = SubscriptionMeta(profileTitle: 'T');
      expect(m.toJson().containsKey('announce'), isFalse);
      final old = SubscriptionMeta.fromJson({'profile_title': 'T'});
      expect(old.announce, isNull);
      expect(old, m);
    });
  });
}
