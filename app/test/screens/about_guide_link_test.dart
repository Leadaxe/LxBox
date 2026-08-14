import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/screens/about_screen.dart';

// §361 — кнопка «Руководство пользователя» в About ведёт на документ языка
// интерфейса. Единственная логика, где можно ошибиться, — сопоставление
// тега локали и URL: перепутанные языки выглядят рабочей кнопкой, но открывают
// текст, который юзер не читает.

void main() {
  group('About → user guide link', () {
    test('ru → русский гайд, en → английский', () {
      expect(AboutScreen.guideUrlFor('ru'), AboutScreen.guideUrlRu);
      expect(AboutScreen.guideUrlFor('en'), AboutScreen.guideUrlEn);
      expect(AboutScreen.guideUrlRu, isNot(AboutScreen.guideUrlEn));
    });

    test('незнакомый язык → английский (fallback, не 404)', () {
      // LocaleController.effectiveTag сейчас отдаёт только en/ru, но при
      // добавлении третьего языка (без своего гайда) ссылка обязана остаться
      // рабочей.
      for (final tag in ['de', 'fa', 'zh', '']) {
        expect(AboutScreen.guideUrlFor(tag), AboutScreen.guideUrlEn,
            reason: 'тег "$tag" должен падать в английскую версию');
      }
    });

    test('оба URL смотрят на main и на разные файлы репозитория', () {
      for (final url in [AboutScreen.guideUrlEn, AboutScreen.guideUrlRu]) {
        // Ветка main — единственная, куда доезжают релизные доки (§361);
        // ссылка на develop сгнила бы после мержа.
        expect(url, startsWith('https://github.com/Leadaxe/LxBox/blob/main/'),
            reason: 'ссылка должна вести в main: $url');
        expect(url, endsWith('.md'));
      }
      expect(AboutScreen.guideUrlEn, contains('docs/USER_GUIDE.md'));
      expect(AboutScreen.guideUrlRu, contains('docs/USER_GUIDE.ru.md'));
    });
  });
}
