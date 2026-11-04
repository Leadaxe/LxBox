# 712 — `package_name_regex` и `domain_regex` в пользовательских правилах маршрутизации

| Field | Value |
|-------|-------|
| Status | Done |
| Start date | 2026-11-04 |
| End date | 2026-11-04 |
| Commits | — |
| Related specs | features/004-ROUTING (inline-rules), §692 (dnsLayerEligible), §683 (DNS & Resolve) |

## Problem

Issue #193 (paratroop3r, 04.11.2026): правило «в туннель» для системных
приложений требует выбрать в пикере больше 100 пакетов, конфиг раздувается.
Все пакеты вендора имеют общий префикс (`com.oplus.`), одна регулярка
закрыла бы их все. Просит `route.rules.package_name_regex`.

У нас в пользовательском правиле пакет задаётся только точным списком
`package_name` (пикер). Регулярок нет ни по пакетам, ни по доменам.
`package_name_regex` встречается только в шаблонном пресете `unknown-traffic`
(`invert` + `"^"`), пользователю не настраивается.

## Diagnosis

Ядро (sing-box-lx 1.14) принимает `package_name_regex` и `domain_regex`
и в route-правиле (`option/rule.go`), и в headless-правиле inline rule_set
(`option/rule_set.go`), и в DNS-правиле. Контракт: ключи уже в allowlists
`route_rule_conditions`, `dns_rule_conditions`, `rule_dns_mirror_match`.
Так что это чисто наша модель + кодек + эмиссия + UI.

Семантика ядра: `package_name_regex` — список regex (Go RE2), совпадение
по `regexp.MatchString` (не anchored, `com\.oplus\.` матчит любой пакет
с этой подстрокой). `domain_regex` — то же по домену запроса/соединения.
Внутри поля — OR, с остальными категориями — AND (как `package_name`).

## Solution

Два новых поля у `CustomRuleInline` (и `CustomRuleSrs`, где есть `packages`):
`packageRegexes` (`package_name_regex`) и `domainRegexes` (`domain_regex`),
списки строк, по умолчанию пустые.

1. Модель `app/lib/models/custom_rule.dart`: поля, конструкторы, `copyWith`,
   `==`/`hashCode`, геттеры-switch по аналогии с `packages`; `summary`
   (строка 748) — «N package regex» / «N domain regex»; `dnsLayerEligible`
   (§692) — оба поля дают право на DNS-слой (домен и пакет DNS-слой проверяет).
2. Кодек `app/lib/models/codec/rule_record.dart`: ключи в `kRuleBodyKeys`,
   запись/чтение рядом с `package_name` / `domain_keyword`.
3. Эмиссия `app/lib/services/builder/post_steps/custom_rules.dart`: в headless
   match (строка ~590) и в `srsMatch` DNS-зеркала (~469) — `package_name_regex`
   и `domain_regex` рядом с `package_name`. Проверить гейты, которые режут
   поля для DNS-зеркала: regex-поля DNS-безопасны (ядро принимает их в
   DNS-правиле).
4. Имя правила `app/lib/services/rule_name_resolver.dart` (~244): добавить
   оба ключа.
5. Редактор `app/lib/screens/custom_rule_edit/`:
   - `apps_section.dart`: под пикером многострочное поле «Package name regex
     (one per line)» через тот же `ItemsField`/контроллер, что у
     `domainKeywordCtrl` в `match_section.dart`; подсказка: «Go RE2, matched
     anywhere in the package name, e.g. `^com\.oplus\.`».
   - `match_section.dart`: поле «Domain regex (one per line)» после Domain
     keyword, та же подсказка про RE2.
   - `edit_controller.dart`: контроллеры, `hasMatch`-предикаты (строки
     ~262/~293 — правило с одной лишь регуляркой считается заполненным),
     гидрация из правила, сборка правила (~1084/~1112/~1116).
   - `validators.dart`/`normalizers.dart`: строка непустая, без переводов
     строки; синтаксис проверять `RegExp(v)` в try/catch — Dart-regex шире
     RE2, но отловит явный мусор (незакрытая скобка). Ошибка — как у
     остальных полей секции.
   - Вкладка View/JSON показывает новые ключи автоматически через кодек —
     проверить.
6. Доки: `docs/spec/features/004-ROUTING/FUNCTIONS/inline-rules.md` и `.ru.md`
   — строки таблицы для обоих ключей (headless) + абзац про RE2 и OR/AND;
   `CHANGELOG.md` Unreleased.
7. Контракт: `app/contract` не трогать — ключи уже разрешены. Если тест
   корпуса/контракта падает на новом ключе в записи правила — доложить,
   не чинить контракт самому.

Не делать: пресеты, пикер по regex (превью совпавших пакетов), миграции.

### Как сделано (расхождения с планом и дополнения)

- `CustomRuleSrs` получил только `packageRegexes` (у srs нет доменных полей);
  эмиссия — routing-rule (`_outboundToRoute`/`_resolveToRoute`) и `srsMatch`
  DNS-зеркала. У inline DNS-зеркало ссылается на тот же headless rule_set,
  отдельной эмиссии не нужно.
- `resolveEligible` (модель и контроллер): `domainRegexes` — доменная группа.
- Регулярки делятся только по `\n` (`splitLines`/`normalizedRegexes` в
  [normalizers.dart](../../../app/lib/screens/custom_rule_edit/normalizers.dart)):
  запятая в RE2 значима (`{1,3}`). Для этого у
  [ItemsField](../../../app/lib/screens/custom_rule_edit/widgets/items_field.dart)
  параметры `split` (по умолчанию `splitRaw`) и `helper` (строка-пояснение).
- Ошибка поля = счётчик «N · M invalid» как у соседей; плюс
  `regexError` в `saveBlockReason`
  ([edit_controller.dart](../../../app/lib/screens/custom_rule_edit/edit_controller.dart)) —
  битая регулярка блокирует Save (ядро такой конфиг не примет).
- Debug API: `domain_regexes` / `package_regexes` в сериализаторе, create,
  PATCH и смене вида
  ([serializers/rules.dart](../../../app/lib/services/debug/serializers/rules.dart),
  [handlers/rules.dart](../../../app/lib/services/debug/handlers/rules.dart)).
- Строки RU/ZH — `app/assets/l10n/{ru,zh}/ui.json`.
- Тесты: [custom_rules_test.dart](../../../app/test/builder/custom_rules_test.dart)
  (группа §712), [regex_fields_test.dart](../../../app/test/screens/custom_rule_edit/regex_fields_test.dart),
  `validators_test.dart`, `normalizers_test.dart`.

## Risks and edge cases

- Правило только с regex и без прочих матчеров — валидное (не match-all).
- Пустые строки в поле отбрасываются; поле целиком пустое — ключ не пишется.
- `CustomRuleSrs`: regex-поля — AND к rule_set, как `packages`.
- Пакеты, выведенные из туннеля OS-уровнем (Tun apps), regex не поймает —
  как и `package_name`; отдельно не объяснять.

## Verification

- Unit: `app/test/builder/custom_rules_test.dart` — правило с
  `packageRegexes: ['^com\\.oplus\\.']` эмитит headless `package_name_regex`
  и, при включённом DNS-зеркале, тот же ключ в DNS-правиле; кодек
  round-trip (запись → чтение) обоих ключей.
- Widget-тест в `app/test/screens/custom_rule_edit/` по образцу соседних:
  ввод двух регулярок, сохранение, в правиле два элемента; битая регулярка
  даёт ошибку поля.
- Гонять только затронутые файлы тестов, не каталоги.

## Unresolved / follow-up

—
