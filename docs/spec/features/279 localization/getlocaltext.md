# getLocalText — natural-key локализация (замена gen_l10n/ARB)

> **Статус: LIVE (§285 реализован).** ARB/gen_l10n снесены; весь UI
> локализуется через `getLocalText`. Раздел UI-строк в [spec.md §2](spec.md)
> (ARB-подход) — superseded этим документом. Реализация — [задача
> 285](../../tasks/285-getlocaltext-migration.md).

Ревизия механизма UI-локализации из [спеки 279](spec.md). ARB + gen_l10n
(искусственные ключи `commonCancel`, кодген, типизированные геттеры) заменены
на **natural keys**: английский текст на call-site *и есть* ключ.

## Мотивация

- ARB требует церемонии: придумать ключ, `@key`-description, кодген, `context.l.x`.
- Один механизм на весь проект: тот же принцип «английский-источник + перевод»,
  что уже работает в template-overlay ([spec.md §3](spec.md)).
- В коде: `getLocalText.s("Connected to %s", host)` — читается как есть, английский
  виден в исходнике, он же fallback.

## API

```dart
// Простая строка. Первый (int) параметр — необязательный, дефолт 0.
getLocalText.s("Connected to %s", host)      // форма 0 (основная)
getLocalText.s(1, "New")                      // особая форма №1 (напр. женский род)

// Множественное число (последний аргумент — число, идёт в %d).
getLocalText.plural("%d servers", n)          // форма 0
getLocalText.plural(1, "%d items", n)         // особая форма №1 + плюрал
```

Глобальный доступ `getLocalText` (top-level getter, как `L10n.current` сейчас) —
без `BuildContext`, работает в сервисах/контроллерах/парсерах. Виджеты и код
без контекста используют одинаково.

**Правила:**
- **Ключ = английский текст дословно.** Не хешируется.
- **Fallback = сам ключ** с подставленными аргументами, если перевода нет.
- Первый `int`-аргумент (0 по умолчанию) выбирает форму: `0` → основная,
  `1+` → `special[N]`.

### Плейсхолдеры

printf-стиль, позиционные:
- `%s` — строка/произвольное значение (`toString()`).
- `%d` — целое число. В `plural` число-аргумент подставляется в `%d`.
- `%1$s` / `%2$s` — явный номер, когда порядок в переводе отличается от исходника.
- `%%` — литеральный процент.

## Формат словаря

`app/assets/l10n/ui/ru.json` — плоский `Map<englishKey, entry>`:

```json
{
  "Connected to %s": { "value": "Подключено к %s" },

  "New": {
    "value": "Новый",
    "special": { "1": { "value": "Новая" } }
  },

  "%d servers": {
    "value": { "one": "%d сервер", "few": "%d сервера", "many": "%d серверов", "other": "%d сервера" }
  },

  "%d items": {
    "value": { "one": "%d элемент", "few": "%d элемента", "many": "%d элементов", "other": "%d элемента" },
    "special": {
      "1": { "value": { "one": "%d шт.", "few": "%d шт.", "many": "%d шт.", "other": "%d шт." } }
    }
  }
}
```

- `value` — либо строка, либо **plural-объект** (ключи диктует зарегистрированный
  resolver: для ru — `one`/`few`/`many`/`other`).
- `special[N]` (N ≥ 1) — особые формы; каждая устроена как `value` (строка или
  plural-объект). `special` и plural **ортогональны и пересекаются**:
  `getLocalText.plural(1, ...)` берёт `special["1"].value` как plural-объект.
- Форма 0 всегда = корневой `value`; отдельного `special["0"]` нет.

**Английского словаря нет** — fallback = ключ. `en.json` не хранится.

## Движок

`app/lib/services/l10n/get_local_text.dart`:

```dart
abstract class PluralResolver {
  /// Ключи plural-форм, которые resolver ждёт в value-объекте (для CI-валидации).
  Set<String> get forms;
  /// Выбор строки-формы по числу из plural-объекта.
  String select(Map<String, String> forms, int n);
}

class GetLocalText {
  GetLocalText(this._dict, this._plural);
  final Map<String, dynamic> _dict;      // englishKey -> entry (null для fallback-локали)
  final PluralResolver _plural;

  String s(Object a0, [Object? a1, Object? a2, Object? a3, Object? a4]) { ... }
  String plural(Object a0, [Object? a1, Object? a2]) { ... }
}

GetLocalText get getLocalText => LocaleController.I.text;
```

- Перегрузка «первый int = индекс формы»: если первый аргумент `int` — это индекс
  формы, ключ во втором; иначе первый аргумент — ключ, индекс = 0. (Dart не имеет
  overload'ов → разбор по рантайм-типу первого аргумента, как в примерах API.)
- Рендер: найти `entry` по ключу → выбрать форму (`value` или `special[N]`) →
  если plural-объект, `_plural.select(...)` по числу → printf-подстановка `%s/%d`.
- **Fallback**: ключ отсутствует / форма отсутствует / словарь = fallback-локаль →
  печатаем сам английский ключ с подстановкой. Никогда не бросаем.

### Plural-resolver'ы через DI

Локализатор при инициализации регистрирует per-language resolver:
- `EnPluralResolver` (`one`/`other`) — тривиальный, для fallback-контроля.
- `RuPluralResolver` — CLDR: `n%10==1 && n%100!=11 → one`; `n%10 in 2..4 &&
  n%100 not in 12..14 → few`; `n%10==0 || n%10 in 5..9 || n%100 in 11..14 → many`;
  дробные → `other`.

Resolver выбирается по активной локали в `LocaleController._applyLocale`. Формат
plural-объекта в словаре обязан покрывать `resolver.forms` (CI-гейт).

## Интеграция с рантаймом

- `LocaleController` грузит `assets/l10n/ui/<tag>.json` (для `en` — словаря нет,
  всё fallback) и подставляет resolver по локали. `set()`/`didChangeLocales`/
  runtime-switch — как сейчас, `notifyListeners()` → rebuild.
- `MaterialApp.localizationsDelegates` теряет `AppLocalizations.delegate`, но
  сохраняет `GlobalMaterial/Widgets/Cupertino` (Flutter-встроенные строки).
  `supportedLocales`, `locale: effective` — без изменений.
- `L10n.current`/`context.l`/gen_l10n удаляются целиком.

## Границы (без изменений)

- **Template overlay** остаётся — локализует данные шаблона (не код).
  Ключуется английским текстом display-полей (принцип `ui/`-словаря, `{value}`-
  формат, без адресов и `src`-hash — §285). Сосуществует, общий
  `check_common`-харнесс.
- **Android native** (`values-ru/`) — отдельно.
- Wire/логи/Debug API/automation — английские; `getLocalText` в них не зовём
  (для machine-строк просто литерал, не оборачиваем).

## CI-гейты (`tool/l10n/`)

- `ui_check.dart` (**новый**): AST-скан всех `getLocalText.s(...)`/`.plural(...)` →
  множество английских ключей + использованных индексов форм. Проверки:
  - каждый ключ есть в `ru.json` → иначе missing-translation (warning, под
    `--strict` fail);
  - `ru.json` не содержит ключей, которых нет в коде → orphan (warning/strict-fail);
  - plural-ключ (вызван через `.plural`) обязан иметь plural-объект с полным
    `resolver.forms`; не-plural — строку;
  - каждый использованный `special[N]`-индекс присутствует в записи;
  - placeholder-арность: число `%s/%d` в переводе (и каждой plural-форме) = в ключе;
  - `value`, начинающийся с недопустимого, пустой перевод → fail.
- `hardcoded_check.dart` (**остаётся**, ужесточается): голый `Text("...")` без
  `getLocalText` — fail; `Text(getLocalText.s("..."))` легально. Baseline → 0.
- `arb_check.dart` / `template_check.dart`: ARB-чекер **удаляется** (ARB нет);
  template-чекер живёт.
- Ключ = английский текст → **русского текста в исходном коде быть не может**
  (инвариант [feedback-ui-strings-english-only] сохраняется буквально: ключ
  всегда английский, русский только в `ru.json`).

## Миграция (детерминированная)

Скрипт `tool/l10n/arb_to_getlocaltext.dart` (разовый):
1. Для каждого ARB-ключа `K`: `en = app_en.arb[K]`, `ru = app_ru.arb[K]`.
   - простой: новый ключ = `en`, `ru.json[en] = {"value": ru}`.
   - ICU plural: раскрыть в plural-объект `{one, few, many, other}` (ru-формы из
     ICU-веток; `{count}`/`{n}` → `%d`, прочие `{x}` → `%s` позиционно).
   - `{placeholder}` → `%s`/`%d` по типу; порядок → `%1$s` при расхождении.
2. Заменить call-site'ы: `context.l.K` → `getLocalText.s("<en>")` (или `.plural`,
   если K был plural), аргументы переносятся. ~1451 сайт, автоматизируемо по
   ARB-ключу; коллизии одинакового `en` с разным ru → `special`-индексы, ручная
   триажировка (список даёт скрипт).
3. Удалить `l10n.yaml`, `lib/l10n/`, `AppLocalizations`-делегат, `context.l`.

Инвариант: видимый текст **не меняется** — en-ключ = прежнее ARB-en-значение
дословно, ru = прежнее ARB-ru-значение. `find.text` в тестах переживает.

## Docs to update

- [`docs/l10n.md`](../../../l10n.md) — переписать translator-guide под natural keys.
- [`docs/ARCHITECTURE.md`](../../../ARCHITECTURE.md) — секцию l10n.
- [`spec.md`](spec.md) — пометить §2 (ARB) вытесненным этой ревизией.
- `CHANGELOG.md` — если user-visible (не должно быть — текст тот же).
