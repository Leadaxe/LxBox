# 280 — Локализация: первый цикл реализации (en + ru)

Реализация [фичи 279](../features/279%20localization/spec.md) — фазы 0–7 плана
миграции (§10 архитектуры). Языки первой версии: английский (базовый) + русский.
Новые языки добавляются позже без структурных изменений.

## Скоуп фаз (чеклист)

- [ ] **Phase 0 — развязка протоколов.** `StopReason`-парсинг native-строк
  Dart-side (Kotlin wire не трогается); `NodeWarning`/`ValidationIssue`
  equality по полям данных; `XhttpParamResetWarning.reason` → enum;
  поля `id` у `sections[]`, `ping_options.presets[]`,
  `speed_test_options.servers[]` шаблона; выбор speed-сервера по `id`
  вместо индекса; prep-rename `NodeWarning.message` getter → метод.
- [ ] **Phase 1 — инфраструктура (ships inert).** `l10n.yaml` + `app_en.arb`
  (seed) + `app_ru.arb`; `L10n` holder (eager, пиненный `en`);
  `LocaleController` (WidgetsBindingObserver, didChangeLocales);
  wiring MaterialApp (merged Listenable с themeNotifier, delegates,
  supportedLocales en+ru); `TemplateOverlay` (apply/extract, скоупированная
  схема адресов, fail на дубль-конфликте); `TemplateLoader` — кэш по тегу
  локали; `assets/l10n/template/en.json` (генерируемое зеркало);
  var `app_language` (`system|en|ru`) в `_appFeatureFlagVars` + typed-аксессоры;
  Debug API per-key side-effect registry; language picker в App Settings →
  General (System default / English / Русский); checkers `tool/l10n/`
  (template_check, arb_check, hardcoded_check + baseline) + шаг CI.
- [ ] **Phase 2 — шаблон.** `assets/l10n/template/ru.json` (объектный формат
  с `src`-hash); live-резолюция preset-label'ов (ordinal-дизамбигуация копий,
  dedup по display-именам); magic-node-титулы из шаблона (снос хардкод-зеркала
  `special_node_display`); typed-модели raw-секций; `_template`-fetch →
  `didChangeDependencies` (settings, dns_settings, speed_test, home_menus);
  `RuleNameResolver.relocalize()`; тест rootBundle-загрузки overlay.
- [ ] **Phase 3 — sweep UI-chrome.** Миграция ~1000 сайтов волнами
  (home → subscriptions → routing/folders → stats/profiler → dns/speed →
  хвост); ICU-плюралы; en-ARB = сегодняшние литералы дословно; ru-перевод
  каждой волны; baseline сужается поволново.
- [ ] **Phase 4 — warnings/errors (атомарная).** `NodeWarning.message(l)`;
  sealed `UiMsg` (`render(l)` / `renderEn()`); `formatUserError`/`humanizeError`
  возвращают `UiMsg`; контроллеры + render-сайты + тесты одной веткой;
  rendering-locality-правило checker'а → fail-режим.
- [ ] **Phase 5 — форматирование.** Даты через `intl`; relativeTime с ICU;
  слова (`Expired`, `days left`, …) → ARB; единицы и суффиксы `d/h/m/s` —
  латиница (решение 9); дедуп `_formatDuration`.
- [ ] **Phase 6 — Android native.** `strings.xml` + `values-ru/`; manifest
  `@string`; `L10n.kt` (createConfigurationContext в момент рендера, без
  кэша); MethodChannel `setAppLanguage` → resubmit канала + relabel
  нотификации + `updateShortcuts()` (+ retry из onResume) + тайл +
  `Libbox.setLocale`; `ACTION_LOCALE_CHANGED`-receiver; `localeConfig` +
  `LocaleManager` (33+, empty-list на system, трёхсторонний reconciliation
  через `last_pushed_locale`); Kotlin literal guard.
- [ ] **Phase 7 — lock down.** Baseline → 0; ru-гейт/orphan-гейт hard-fail;
  доки (STORAGE.md, TEMPLATE.md, debug-api-reference, ARCHITECTURE.md,
  CHANGELOG, translator-guide `docs/l10n.md`).

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
