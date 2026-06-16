# §144 — Отдельный валидатор для поля «Domain suffix»

**Статус:** Done
**Фича:** §053 (CustomRuleEditScreen / extracted validators+normalizers)
**Тип:** bug-fix (UI-индикатор)

## Симптом

В редакторе кастомного правила поле **«Domain suffix»** показывает бейдж
`N · M invalid` для совершенно валидных суффиксов (`ru`, `com`, `.ru`), хотя
само правило собирается и матчится в sing-box нормально.

Бейдж — чисто **косметика** ([items_field.dart](../../../app/lib/screens/custom_rule_edit/widgets/items_field.dart):66-73,109-119):
он не фильтрует ввод на save, поэтому «invalid» горит, а правило работает.

## Корень

Поле суффикса было подвешено на тот же валидатор, что и exact-домен —
`isValidDomain` ([match_section.dart](../../../app/lib/screens/custom_rule_edit/sections/match_section.dart):50), а это строгая FQDN-регулярка
([validators.dart](../../../app/lib/screens/custom_rule_edit/validators.dart):16-20):

```
^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$
```

Она требует **минимум одну точку и буквенный TLD**. Но `domain_suffix` в
sing-box — это суффиксное сравнение хвоста хоста (по сути `HasSuffix` с
дописыванием точки), TLD-only суффикс там легитимен. Кейсы, ломавшие бейдж:

| Ввод | После normalize (lower + strip leading `.`) | `isValidDomain` |
|---|---|---|
| `.ru` | `ru` | ❌ нет точки |
| `com` | `com` | ❌ нет точки |
| `xn--p1ai` (`.рф`) | `xn--p1ai` | ❌ нет точки |

Причём hint самого поля прямо предлагает писать `.ru`
([match_section.dart](../../../app/lib/screens/custom_rule_edit/sections/match_section.dart):56).

## Фикс

Отдельный, более слабый валидатор `isValidDomainSuffix` — точка и «настоящий»
TLD **необязательны**, остальное (валидные DNS-лейблы, без схемы/слэшей/
пробелов, без граничных дефисов, лейбл ≤63) сохраняется.

```dart
final RegExp _domainSuffixRegex = RegExp(
  r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$',
);

bool isValidDomainSuffix(String v) => _domainSuffixRegex.hasMatch(v);
```

Регистр `[a-z0-9]` без заглавных — корректно: normalizer
([match_section.dart](../../../app/lib/screens/custom_rule_edit/sections/match_section.dart):51-55)
делает `toLowerCase()` и срезает ведущую точку **до** вызова валидатора.

### Затронутые файлы

- `app/lib/screens/custom_rule_edit/validators.dart` — `+ isValidDomainSuffix`
- `app/lib/screens/custom_rule_edit/sections/match_section.dart` — поле
  «Domain suffix» переключено с `v.isValidDomain` → `v.isValidDomainSuffix`
- `app/test/screens/custom_rule_edit/validators_test.dart` — group `isValidDomainSuffix`

## Проверка

Прогнан кандидат-регэксп через normalizer на наборе кейсов:

- valid: `ru`, `com`, `example.com`, `co.uk`, `sub.example.co.uk`, `.ru`,
  `xn--p1ai`, `a`, `a-b.c`, `123.com`, `EXAMPLE.COM`
- invalid: пусто, `https://x.com`, `a/b`, `a b`, `foo..bar`, `-foo.com`,
  `foo-.com`, `.`, `foo.`, лейбл 64 символа

→ все приняты/отклонены как ожидалось.

---

## §144.1 — Punycode / IDNA ToASCII на вводе

### Зачем

После §144 валидатор суффикса корректно реджектил сырой кириллический IDN
(`.рф`, `почта.рф`) — sing-box хочет ASCII/punycode. Но юзеру неудобно вручную
вводить `xn--p1ai`. Решение: UI сам конвертит Unicode-домен → ASCII на
нормализации, и для exact-домена, и для суффикса.

### Реализация

Новый файл `app/lib/screens/custom_rule_edit/punycode.dart` — чистый Dart,
**без внешних зависимостей** (project rule):

- `punycodeEncode(String)` — RFC 3492 §6.3 encode (Unicode → punycode без
  `xn--`).
- `domainToAscii(String)` — per-label IDNA ToASCII: split по `.`, каждый
  не-ASCII лейбл → `xn--…`; pure-ASCII лейблы и весь pure-ASCII вход —
  fast-path passthrough.

**Что НЕ делаем:** полный UTS-46 nameprep (мапинг `ﬁ`→`fi`, `ß`→`ss`,
bidi-checks). Для VPN-правил достаточно Unicode lower-case (`toLowerCase()`,
Dart-aware) + Punycode не-ASCII меток.

### Точки интеграции

| Слой | Файл | Изменение |
|---|---|---|
| save-path (exact + suffix) | `normalizers.dart` `normalizedDomains` | финальный шаг `domainToAscii(v)` |
| UI-бейдж (exact) | `match_section.dart` | `normalize: domainToAscii(s.toLowerCase())` |
| UI-бейдж (suffix) | `match_section.dart` | `normalize: …strip dot → domainToAscii(x)` |

Save-path общий для обоих полей → punycode попадает в сохранённое правило →
оттуда в конфиг sing-box. Hint суффикса дополнен примером `почта.рф`.

### Проверка

- `punycode_test.dart` — RFC 3492 §7.1 reference vectors (arabic, chinese,
  russian, münchen) + per-label (`.рф`→`xn--p1ai`, `мвд.рф`, `shop.рф`
  mixed, CJK, ASCII passthrough).
- `normalizers_test.dart` — `почта.рф`→`xn--80a1acny.xn--p1ai`, `МВД.РФ`
  (upper→lower→puny), IDN-суффикс с strip leading dot, mixed-label.
- Полный `flutter test`: целевой `custom_rule_edit/` 77 passed; builder
  pipeline passed. (Flaky в `subscription/rehydrate_race` + `rule_set_downloader`
  при параллельном прогоне — НЕ связаны: изолированно зелёные, мой код не
  импортируют.)
