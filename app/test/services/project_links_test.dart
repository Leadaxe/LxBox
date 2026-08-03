import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/project_links.dart';

/// §362 — общий слой ссылок + подстановка `@плейсхолдеров` remote-контента.
void main() {
  test('известные плейсхолдеры подставляются', () {
    expect(ProjectLinks.expand('@selfLink'), ProjectLinks.latestRelease);
    expect(ProjectLinks.expand('L×Box @selfLink'),
        'L×Box ${ProjectLinks.latestRelease}');
    expect(ProjectLinks.expand('@repoLink и @tgLink'),
        '${ProjectLinks.repo} и ${ProjectLinks.telegram}');
  });

  test('неизвестный @токен остаётся текстом (опечатка не ломает сообщение)',
      () {
    expect(ProjectLinks.expand('@nopeLink'), '@nopeLink');
    expect(ProjectLinks.expand('почта me@example.com'), 'почта me@example.com');
  });

  test('строка без @ возвращается как есть', () {
    const s = 'обычный текст без плейсхолдеров';
    expect(ProjectLinks.expand(s), same(s));
  });

  test('guideFor: ru → RU-гайд, любой другой тег → EN (не 404)', () {
    expect(ProjectLinks.guideFor('ru'), ProjectLinks.guideRu);
    expect(ProjectLinks.guideFor('en'), ProjectLinks.guideEn);
    expect(ProjectLinks.guideFor('de'), ProjectLinks.guideEn);
  });

  test('donatePageFor: ru → RU-страница, прочие → EN', () {
    expect(ProjectLinks.donatePageFor('ru'), ProjectLinks.donatePageRu);
    expect(ProjectLinks.donatePageFor('en'), ProjectLinks.donatePage);
    expect(ProjectLinks.donatePageFor('de'), ProjectLinks.donatePage);
  });

  test('releaseTag строит адрес релиза по тегу', () {
    expect(ProjectLinks.releaseTag('v2.19.4'),
        'https://github.com/Leadaxe/LxBox/releases/tag/v2.19.4');
  });
}
