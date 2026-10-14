import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/node_emoji.dart';

/// §647 — префикс тегов подписки из эмодзи её названия.
void main() {
  group('§647 emojiPrefixFromTitle — таблица ТЗ', () {
    const cases = <String, String>{
      'Liberty VPN 🗽': '🗽',
      '🇩🇪🔥 Germany': '🇩🇪🔥',
      'MyVPN 🚀⚡ Premium': '🚀⚡',
      '🇩🇪 🔥 Germany': '🇩🇪 🔥',
      '🇩🇪·🔥 DE': '🇩🇪·🔥',
      '🇩🇪 · 🔥 DE': '🇩🇪',
      '🔥🔥🔥🔥🔥 Fast': '🔥🔥🔥🔥',
      '🔥 🚀 ⚡ X': '🔥 🚀',
      '🔥 VPN 🚀': '🔥',
      '👨‍💻 Dev': '👨‍💻',
      '1️⃣ Server': '1️⃣',
      'Provider™': '',
      '© Corp ★': '',
      'Plain name': '',
      '--- 🗽 ---': '🗽',
    };
    cases.forEach((title, expected) {
      test('"$title" → "$expected"', () {
        expect(emojiPrefixFromTitle(title), expected);
      });
    });

    test('пустое имя → пусто', () {
      expect(emojiPrefixFromTitle(''), '');
    });

    test('Extended_Pictographic с U+FE0F — эмодзи, без него — нет', () {
      expect(emojiPrefixFromTitle('Shield \u{1F6E1}️'), '\u{1F6E1}️');
      expect(emojiPrefixFromTitle('Arrows ↔ x'), '');
    });
  });

  group('§647 dedupTagPrefix', () {
    test('свободный — как есть', () {
      expect(dedupTagPrefix('🗽', const ['🚀', '']), '🗽');
    });
    test('занятый — индекс 2 без пробела', () {
      expect(dedupTagPrefix('🗽', const ['🗽']), '🗽2');
    });
    test('заняты 🗽 и 🗽2 — 🗽3', () {
      expect(dedupTagPrefix('🗽', const ['🗽2', '🗽']), '🗽3');
    });
  });
}
