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
singboxUpstream · telegram · donate · issues · automationDoc ·
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
| `@tgLink` · `@donateLink` · `@issuesLink` | сообщество/донат/фидбэк |
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
008-donate 72ч. Все URL — через `@плейсхолдеры`; отзыв ведёт в Telegram
и GitHub issues; в 004 — кнопка `share:`, в 005 — `route:profiler`.

## 6. Тесты

`test/services/project_links_test.dart`: подстановка известных ключей,
неизвестный `@токен` не трогается, строка без `@` возвращается той же,
`guideFor` фолбэк, `releaseTag`. `support_nav_test`: `share:` резолвится и
`isInPlaceSupportAction` = true (route/add — false).

## 7. Страница поддержки и донат-попап

- `docs/DONATE.md` / `docs/DONATE_RU.md` — веб-страница поддержки (пара RU/EN
  как гайд): четыре крипто-адреса с deeplink'ами Trust Wallet, Boosty, раздел
  «как помочь не деньгами». Ссылки добавлены в шапку и таблицу доков обоих
  README.
- `docs/donate.json` — источник донат-попапа приложения (About → «Поддержать
  проект»). Раздаётся через raw.githubusercontent (паттерн §356): правка
  адресов НЕ требует релиза. Порядок загрузки: сеть → `donate_cache_json` в
  SettingsStorage → bundled `app/assets/donate.json` (первый запуск офлайн).
  `kind: crypto` — адрес + «Копировать» + «Оплатить» (deeplink); `kind: link` —
  одна кнопка; `note` опционален; `title`/`note` не переводятся (названия сетей
  и брендов).
- Попап перестроен на `DonateMethods` (`app/lib/services/donate_methods.dart`)
  — прежняя таблица адресов, вшитая в разметку, удалена; внизу кнопка «Все
  способы поддержки» на веб-страницу по локали.
- **Маршрут `route:donate`** (§357-реестр) — кнопки поддержки в support-ленте
  ведут в этот попап ВНУТРИ приложения, а не на внешнюю страницу
  (`AboutScreen(openDonate: true)` открывает его post-frame).

## 8. Не сделано (отложено юзером)

**Проверка ссылок из remote-контента.** support.json приезжает с GitHub:
компрометация репозитория/канала позволит подставить произвольный URL в
кнопку (в т.ч. в `share:`, который юзер разошлёт своим именем). Кандидаты:
вайтлист хостов в приложении (github.com/Leadaxe/*, t.me/singbox_launcher*) — простое и покрывает и `share:`, и обычные https-кнопки; либо
подпись файла (ed25519, публичный ключ в APK). Решение отложено.
