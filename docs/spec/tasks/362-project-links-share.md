# §362 — Общий слой ссылок проекта, `@плейсхолдеры` и действие `share:`

**Тип:** таска (расширение §357)
**Статус:** реализовано 03.08.2026 (юниты; device-verified частично — `share:` и подстановка проверены на эмуляторе)
**Связано:** §356 (support-лента), §357 (`lxbox://`-кнопки), §361 (пара гайдов RU/EN), §036 (update_checker)

---

## 1. Проблема

Адреса проекта лежали копиями по коду: `about_screen` (repo, upstream, launcher,
две ссылки гайда), `automation_tab` (AUTOMATION.md), `update_checker`
(releases/tag). Плюс в support-ленте (§356) URL прописывались прямо в JSON —
и локале-зависимый гайд приходилось дублировать в каждом языковом блоке.
Смена любого адреса требовала обхода всех мест.

## 2. `ProjectLinks` — единственный источник

`app/lib/services/project_links.dart`: repo · latestRelease · core · launcher ·
singboxUpstream · telegram · donate · issues · forum4pda · automationDoc ·
guideEn/guideRu + `guideFor(tag)` (незнакомый тег → EN, не 404) +
`releaseTag(tag)`.

Переведены на слой: `about_screen` (локальные алиасы сохранены для читаемости
call-site'ов; публичные `guideUrlEn/guideUrlRu/guideUrlFor` — прежние имена,
на них ссылаются тесты), `automation_tab`, `update_checker`.

## 3. `@плейсхолдеры` в remote-контенте

`ProjectLinks.expand(raw)` подставляет:

| Плейсхолдер | Значение |
|---|---|
| `@selfLink` | latestRelease |
| `@repoLink` · `@coreLink` · `@launcherLink` | репозитории |
| `@tgLink` · `@donateLink` · `@issuesLink` · `@pdaLink` | сообщество/донат/фидбэк |
| `@guideLink` | гайд **по текущей локали** |
| `@appVersion` | версия APK |

- Резолв — **в момент показа** (`SupportContent.expandLinks()` в
  `SupportMessageScreen.build`): `@guideLink` следует за сменой языка, кэш
  ленты один на все локали.
- Работает во всех текстовых полях контента: `url`, `label`, `message`.
- Неизвестный `@токен` остаётся текстом как есть — опечатка автора не ломает
  сообщение и видна глазом.
- Ключи подставляются от длинных к коротким (префикс не съедает более длинный).

## 4. Действие `share:` (§357-грамматика)

`lxbox://share:<текст>` → системный share-лист (`share_plus`, уже в проекте).
Отличие от `route:`/`add:`: **не уводит с экрана сообщения**
(`isInPlaceSupportAction`) — как https-кнопки, юзер делится и остаётся, потом
жмёт «Прочитал». Пустой payload → кнопка скрыта.

Канон текста кнопки (решение юзера — без рекламных описаний):
`"url": "lxbox://share:L×Box @selfLink"` → в share-лист уходит
`L×Box https://github.com/Leadaxe/LxBox/releases/latest`.

## 5. Прод-лента `docs/support.json`

Восемь сообщений (ru+en), интервалы = наработка туннеля ПОСЛЕ предыдущего
«Прочитал»: 001-welcome-guide 3ч · 002-telegram 12ч · 003-star 24ч ·
004-share 24ч · 005-profiler 36ч · 006-under-the-hood 36ч · 007-review 48ч ·
008-donate 72ч. Все URL — через `@плейсхолдеры`; 4PDA только в ru-блоке
(en → GitHub issues); в 004 — кнопка `share:`, в 005 — `route:profiler`.

## 6. Тесты

`test/services/project_links_test.dart`: подстановка известных ключей,
неизвестный `@токен` не трогается, строка без `@` возвращается той же,
`guideFor` фолбэк, `releaseTag`. `support_nav_test`: `share:` резолвится и
`isInPlaceSupportAction` = true (route/add — false).

## 7. Не сделано (отложено юзером)

**Проверка ссылок из remote-контента.** support.json приезжает с GitHub:
компрометация репозитория/канала позволит подставить произвольный URL в
кнопку (в т.ч. в `share:`, который юзер разошлёт своим именем). Кандидаты:
вайтлист хостов в приложении (github.com/Leadaxe/*, t.me/singbox_launcher*,
4pda.to) — простое и покрывает и `share:`, и обычные https-кнопки; либо
подпись файла (ed25519, публичный ключ в APK). Решение отложено.
