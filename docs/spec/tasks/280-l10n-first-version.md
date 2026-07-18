# 280 — Локализация: первый цикл реализации (en + ru)

Реализация [фичи 279](../features/279%20localization/spec.md) — фазы 0–7 плана
миграции (§10 архитектуры). Языки первой версии: английский (базовый) + русский.
Новые языки добавляются позже без структурных изменений.

## Скоуп фаз (чеклист)

- [x] **Phase 0 — развязка протоколов.** `StopReason`-парсинг native-строк
  Dart-side (Kotlin wire не трогается); `NodeWarning`/`ValidationIssue`
  equality по полям данных; `XhttpParamResetWarning.reason` → enum;
  поля `id` у `sections[]`, `ping_options.presets[]`,
  `speed_test_options.servers[]` шаблона; выбор speed-сервера по `id`
  вместо индекса; prep-rename `NodeWarning.message` getter → метод.
  *Итог: выполнено как спланировано, wire не тронут, тесты зелёные.*
- [x] **Phase 1 — инфраструктура (ships inert).** `l10n.yaml` + `app_en.arb`
  (seed) + `app_ru.arb`; `L10n` holder (eager, пиненный `en`);
  `LocaleController` (WidgetsBindingObserver, didChangeLocales);
  wiring MaterialApp (merged Listenable с themeNotifier, delegates,
  supportedLocales en+ru); `TemplateOverlay` (apply/extract, скоупированная
  схема адресов, fail на дубль-конфликте); `TemplateLoader` — кэш по тегу
  локали; `assets/l10n/template/en.json` (генерируемое зеркало);
  *(позже: en.json удалён — базовый английский живёт в самом `wizard_template.json`,*
  *а словари перегруппированы под `assets/l10n/<tag>/`.)*
  var `app_language` (`system|en|ru`) в `_appFeatureFlagVars` + typed-аксессоры;
  Debug API per-key side-effect registry; language picker в App Settings →
  General (System default / English / Русский); checkers `tool/l10n/`
  (template_check, arb_check, hardcoded_check + baseline) + шаг CI.
  *Итог: выполнено; отгружено inert (ru скрыт до Phase 6).*
- [x] **Phase 2 — шаблон.** `assets/l10n/template/ru.json` (объектный формат
  с `src`-hash) *(позже: путь → `assets/l10n/ru/template.json`; entry без*
  *`src`-hash — plain `{"value": ...}` по english-text-ключу)*; live-резолюция preset-label'ов (ordinal-дизамбигуация копий,
  dedup по display-именам); magic-node-титулы из шаблона (снос хардкод-зеркала
  `special_node_display`); typed-модели raw-секций; `_template`-fetch →
  `didChangeDependencies` (settings, dns_settings, speed_test, home_menus);
  `RuleNameResolver.relocalize()`; тест rootBundle-загрузки overlay.
  *Итог: выполнено; паттерн оформлен mixin'ом `TemplateAwareState`.*
- [x] **Phase 3 — sweep UI-chrome.** Миграция ~1000 сайтов волнами
  (home → subscriptions → routing/folders → stats/profiler → dns/speed →
  хвост); ICU-плюралы; en-ARB = сегодняшние литералы дословно; ru-перевод
  каждой волны; baseline сужается поволново.
  *Итог: выполнено, baseline дошёл до нуля; +~100 сайтов доехали в Phase 7
  (литералы в ternary/switch-ветках, вскрытые ужесточением checker'а).*
- [x] **Phase 4 — warnings/errors (атомарная).** `NodeWarning.message(l)`;
  sealed `UiMsg` (`render(l)` / `renderEn()`); `formatUserError`/`humanizeError`
  возвращают `UiMsg`; контроллеры + render-сайты + тесты одной веткой;
  rendering-locality-правило checker'а → fail-режим.
  *Итог: выполнено одной веткой; rendering-locality в fail-режиме.*
- [x] **Phase 5 — форматирование.** Даты через `intl`; relativeTime с ICU;
  слова (`Expired`, `days left`, …) → ARB; единицы и суффиксы `d/h/m/s` —
  латиница (решение 9); дедуп `_formatDuration`.
  *Итог: выполнено; golden-тесты форматов не тронуты.*
- [x] **Phase 6 — Android native.** `strings.xml` + `values-ru/`; manifest
  `@string`; `L10n.kt` (createConfigurationContext в момент рендера, без
  кэша); MethodChannel `setAppLanguage` → resubmit канала + relabel
  нотификации + `updateShortcuts()` (+ retry из onResume) + тайл +
  `Libbox.setLocale`; `ACTION_LOCALE_CHANGED`-receiver; `localeConfig` +
  `LocaleManager` (33+, empty-list на system, трёхсторонний reconciliation
  через `last_pushed_locale`); Kotlin literal guard.
  *Итог: код выполнен, `kotlin_check --strict` зелёный; device-verify
  отложен — см. DEVICE-PENDING ниже.*
- [x] **Phase 7 — lock down.** Baseline → 0; ru-гейт/orphan-гейт hard-fail
  (`--strict` на каждом push/PR, CI-условие удалено); доки (STORAGE.md,
  TEMPLATE.md, BUILD.md, debug-api-reference, ARCHITECTURE.md, CHANGELOG,
  translator-guide `docs/l10n.md`).
  *Итог: выполнено; попутно `hardcoded_check` ужесточён — рекурсия в
  ternary/switch-ветки display-позиций (скан вынесен в
  `tool/l10n/src/hardcoded_scan.dart`, self-тест `test/tool/`), вскрытые
  ~100 литералов домигрированы в ARB (en+ru).*

## DEVICE-PENDING — верификация на устройстве (Phase 6, матрица §10)

Ни один пункт нативной части не проверен на живом устройстве:

- [ ] QS-тайл cold-start на ru (сервис-процесс без Flutter).
- [ ] Кнопки шторки Stop/Reconnect после смены языка при видимой нотификации
  (реконструкция builder'а — action'ы не дублируются, метки переключаются).
- [ ] Смена языка устройства при `app_language=system` с приложением в
  foreground и background — UI и натив переключаются согласованно.
- [ ] `ru → System default → restart` на Android 13+ — показывает язык
  устройства, `app_language='system'` сохраняется (empty-list push).
- [ ] Restore бэкапа с `app_language` на 33+ при выставленном `LocaleManager`
  (reconciliation ветка 2: сторадж побеждает, пере-пуш зеркала).
- [ ] Pinned-shortcut-лейблы после смены языка (`updateShortcuts` + rate-limit
  retry из `MainActivity.onResume`).
- [ ] Имя notification-канала в системных настройках после смены.
- [ ] Boot-start: язык нативных поверхностей при старте с BOOT_COMPLETED.
- [ ] Tasker-строки (blurb'ы активити меняют язык; матчинг по extras жив).
- [ ] `Libbox.setLocale` mid-run: принимает ли ядро смену без рестарта VPN;
  если нет — задокументировать окно «строки ядра до следующего рестарта»
  в release notes (§6.3 шаг 5 спеки).
- [ ] ru-smoke-pass на маленьком экране (русские строки на ~30–40% длиннее;
  subtitle QS-тайла молча обрезается).

## Инварианты цикла

- en-ARB значения = существующие литералы **дословно** — widget-тесты
  (`find.text`) переживают миграцию без правок.
- Каждая фаза коммитится только зелёной (`flutter analyze` чист, `flutter test`
  проходит); Phase 4 — одной веткой, не по волнам.
- Номера задач (§NNN) не попадают в видимые строки и в ARB-значения.
- Device-verify нативной части (Phase 6, матрица §10) — отложен до сессии с
  устройством; помечать DEVICE-PENDING.

## Docs to update

См. список в [спеке фичи 279](../features/279%20localization/spec.md#docs-to-update);
выполняется в Phase 7 этого цикла.
