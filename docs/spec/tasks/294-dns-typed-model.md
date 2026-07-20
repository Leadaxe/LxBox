# §294 — DNS servers+rules: типизированная sealed-модель

**Тип:** structural refactor (Шаг 2 фичи [§291](../features/291%20layered-architecture-facades/spec.md)) · **Статус:** spec · **Размер:** L · **Приоритет:** высший структурный

Крупнейшее снижение долга в приложении. DNS — единственный домен с оценкой
**worst**: `dns_options.servers` и `dns_options.rules` хранятся как сырые
`List<Map<String,dynamic>>` **без модели**, а всё знание формы (kind-refs,
override-detection, orphan cleanup, tag-rename каскад) размазано инлайн по
`dns_settings_screen.dart` (985 строк) + `dns_server_resolver.dart`.

## Проблема (нарушение §291)

- **Нет модели** — форма живёт в сырых Map, каждый читатель знает раскладку JSON.
- **Нет валидации на записи** — Debug `_putDnsServers` (`settings.dart:331`)
  пишет verbatim; асимметрия с типизированным `/rules` (у того sealed `CustomRule`).
- **dns_settings_screen — seam magnet:** держит ДВА хранилища сразу (свой
  staged `dns_options` + чужой `custom_rules`), пишет `custom_rules` un-staged
  через `unawaited()` в 4 местах (rename cascade :469, `_toggleRuleDns` :920,
  `_toggleRuleForceIpv4` :945, `_togglePresetDnsEnable` :965). DNS-поведение
  правила физически расколото на два мира.

## Решение — sealed модель по образцу CustomRule

Ввести `DnsServer` / `DnsRule` sealed-модели с trio (toJson/fromJson/copyWith),
дискриминатор `kind` (inline/preset/template), инварианты в trio (как §283
`disabledHashes` переживает backup merge). Знание формы (resolve, override,
orphan, rename-cascade) переезжает из `dns_server_resolver.dart`/экрана **в
модель**. `SettingsStorage` DNS-методы отдают/принимают типы, не сырые Map.

**Strangler:** модель встаёт **за** существующим render-time resolver'ом —
на чтение ничего не ломается. `DnsServer`/`DnsRule` парсятся из тех же JSON, что
лежат сейчас; форма хранилища НЕ мигрируется (§291 нецель). Debug
`_putDnsServers` получает реальную валидацию — уже отдельно shippable выигрыш.

**Эталон:** `custom_rule.dart:23` (sealed + typed subclasses + exhaustive
switch), `server_list.dart` (trio + инварианты в trio).

## Файлы

- новый `lib/models/dns_server.dart` + `lib/models/dns_rule.dart` (sealed trio)
- `lib/services/settings_storage/network.dart:100-222` (методы → типы)
- `lib/screens/dns_settings_screen/dns_server_resolver.dart` (shape-knowledge → модель)
- `lib/services/debug/handlers/settings.dart:331` `_putDnsServers` (валидация)
- `build_config` DNS-leg (потребитель типов)

## Приёмка

- `DnsServer`/`DnsRule` — sealed, trio round-trip покрыт тестом.
- Debug `PUT /settings/dns_options/servers` отвергает невалидную форму (симметрия
  с `/rules`).
- Чтение старого JSON (сырые Map) парсится в модель без миграции формы на диске.
- §221 backup-инвариант не задет (форма ключей `dns_options` не меняется).
- Разблокирует §295 (dual-write fix).

## Docs to update

- `docs/api/debug-api-reference.md` — валидация `/settings/dns_options/*`.
- `docs/STORAGE.md` — DNS теперь типизирован (форма на диске без изменений).
- `CHANGELOG.md` — API-валидация DNS.
