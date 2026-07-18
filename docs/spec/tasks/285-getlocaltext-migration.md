# 285 — Миграция на getLocalText (natural keys, снос ARB)

Реализация [ревизии getLocalText](../features/279%20localization/getlocaltext.md)
фичи 279. Цель: убрать искусственные ARB-ключи (`commonCancel` и ~1167 других)
из кода — вместо `context.l.commonCancel` писать `getLocalText.s("Cancel")`.

## Фазы

- [ ] **Ф1 — движок + resolver'ы.** `get_local_text.dart` (`GetLocalText.s/.plural`,
  printf `%s/%d/%1$s/%%`, форма-индекс, fallback = ключ); `PluralResolver` +
  `EnPluralResolver`/`RuPluralResolver` (CLDR ru); загрузка `assets/l10n/ui/<tag>.json`;
  интеграция в `LocaleController` (resolver по локали, dict-reload в пайплайне).
  Юнит-тесты движка (fallback, plural ru-формы 1/2/5/22/25, special-индексы,
  placeholders, %1$s reorder).
- [ ] **Ф2 — миграционный скрипт.** `tool/l10n/arb_to_getlocaltext.dart`:
  ARB en/ru → `assets/l10n/ui/ru.json` (plural ICU→объект, `{x}`→`%s/%d`);
  отчёт о коллизиях (одинаковый en, разный ru). Прогон, ручная триажировка
  коллизий в special-формы. Валидация: кол-во ключей, placeholder-арность.
- [ ] **Ф3 — миграция call-site'ов волнами.** `context.l.<key>` →
  `getLocalText.s/.plural("<en>", args)` по ARB-маппингу; удалить импорты
  `l10n.dart`/gen. ~1451 сайт, ~135 файлов. Каждая волна: analyze + tests зелёные.
- [ ] **Ф4 — CI-гейты.** `ui_check.dart` (AST-скан getLocalText → сверка ru.json:
  missing/orphan/plural-forms/special-index/placeholder-арность); `hardcoded_check`
  ужесточить под новый паттерн; удалить `arb_check.dart`. CI-шаг обновить.
- [ ] **Ф5 — снос ARB.** Удалить `l10n.yaml`, `lib/l10n/*.arb`, `lib/l10n/gen/`,
  `AppLocalizations`-делегат, `flutter: generate`, `context.l`-extension,
  `intl`-ARB-зависимость (intl остаётся для DateFormat). Доки (l10n.md,
  ARCHITECTURE, spec.md §2 mark superseded). Финальный gate.

## Инварианты

- Видимый текст **не меняется**: en-ключ = прежнее ARB-en дословно, ru = прежнее ARB-ru.
  `find.text` в тестах переживает.
- Русского текста в исходном коде нет (ключ всегда английский).
- Каждая фаза зелёная (analyze + test), коммит атомарный.
- Template overlay и Android native не трогаются.
