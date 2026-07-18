# 285 — Миграция на getLocalText (natural keys, снос ARB)

Реализация [ревизии getLocalText](../features/279%20localization/getlocaltext.md)
фичи 279. Цель: убрать искусственные ARB-ключи (`commonCancel` и ~1167 других)
из кода — вместо `context.l.commonCancel` писать `getLocalText.s("Cancel")`.

## Фазы

- [x] **Ф1 — движок + resolver'ы.** `get_local_text.dart` (`GetLocalText.s/.plural`,
  printf `%s/%d/%1$s/%%`, форма-индекс, fallback = ключ); `plural_resolver.dart`
  (`PluralResolver` + `EnPluralResolver`/`RuPluralResolver`, CLDR ru); загрузка
  `assets/l10n/ui/<tag>.json`; интеграция в `LocaleController` (resolver по
  локали, dict-reload в `_applyLocale`, глобальный `getLocalText` getter).
  Юнит-тесты движка.
- [x] **Ф2 — миграционный скрипт (одноразовый, снесён).** ARB en/ru →
  `assets/l10n/ui/ru.json` (plural ICU→объект, `{x}`→`%s/%d`), коллизии →
  special-формы. Итог: словарь `ru.json` (1146 записей: 1088 строк, 58 plural,
  8 special). Инструменты (`arb_to_getlocaltext.dart`, `migrate_callsites.dart`,
  `_arb_migration_map.json`) удалены как отработавшие.
- [x] **Ф3 — миграция call-site'ов.** `context.l.<key>` /`L10n.current.<key>` →
  `getLocalText.s/.plural("<en>", args)`; ~1450 сайтов; импорты `l10n.dart`/gen
  сняты. analyze + tests зелёные.
- [x] **Ф4 — CI-гейты.** `ui_check.dart` + `src/ui_scan.dart` (AST-скан
  getLocalText → сверка ru.json: missing/orphan/orphan-special/usage-conflict/
  shape/placeholder-арность; `--strict` эскалирует warn→fail); self-тест
  `test/tool/ui_check_test.dart`. `hardcoded_check` rendering-locality
  переписан под getLocalText (`.render()` разгейчен, `renderEn`/`GetLocalText.en`
  правила сохранены). `arb_check.dart` удалён. CI-шаг «L10n checks» обновлён
  (ui_check добавлен, arb_check убран).
- [x] **Ф5 — снос ARB.** Удалены `l10n.yaml`, `lib/l10n/*.arb`, `lib/l10n/gen/`,
  `services/l10n/l10n.dart` (`L10n`/`context.l`), `AppLocalizations`-делегат из
  `MaterialApp` (Global* делегаты сохранены), `flutter: generate` из pubspec,
  analyzer-exclude + .gitignore записи для gen. `flutter_localizations` + `intl`
  оставлены (Global*Localizations / DateFormat). Доки: l10n.md, ARCHITECTURE,
  CLAUDE.md, tool/l10n/README.md переписаны; getlocaltext.md помечен LIVE.
  Финальный gate: analyze/test/4 checkers --strict зелёные.

## Итог

- `ui_check`: 1146 keys, 0 missing, 0 orphan, 0 arity-errors, 0 dynamic-skipped.
- Видимый текст не изменился (en-ключ = прежнее ARB-en дословно); `find.text`
  в тестах переживает.
- Русского текста в коде нет (ключ всегда английский).

## Инварианты

- Видимый текст **не меняется**: en-ключ = прежнее ARB-en дословно, ru = прежнее ARB-ru.
  `find.text` в тестах переживает.
- Русского текста в исходном коде нет (ключ всегда английский).
- Каждая фаза зелёная (analyze + test), коммит атомарный.
- Template overlay и Android native не трогаются.
