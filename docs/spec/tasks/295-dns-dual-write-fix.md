# §295 — DNS dual-write фикс: убрать half-stage/half-write в экране

**Тип:** structural refactor (Шаг 2b фичи [§291](../features/291%20layered-architecture-facades/spec.md)) · **Статус:** spec · **Размер:** M · **Зависит от:** [§294](294-dns-typed-model.md)

`dns_settings_screen.dart` (985) пишет чужой `custom_rules` **un-staged** через
`unawaited()` в 4 местах (rename cascade :469, `_toggleRuleDns` :920,
`_toggleRuleForceIpv4` :945, `_togglePresetDnsEnable` :965), пока всё остальное
стейджит через `LazyPersistMixin`. Половина правок атомарна, половина летит мимо
— рассинхрон стораджа и live-состояния до рестарта.

## Решение

После §294 (DNS типизирован, владелец формы — модель) провести эти 4 записи
через единый staged/атомарный путь — либо DNS-фасад, либо тот же
`LazyPersistMixin`, что и остальные правки экрана. `presetDnsEnable` (сейчас
имеет ТРИ представления: custom_rules + dns_options.rules + magic-var) свести к
одному через модель §294.

## Файлы

- `lib/screens/dns_settings_screen.dart` (4 `unawaited` call-site)
- DNS-фасад/модель из §294

## Приёмка

- Ни одной un-staged записи `custom_rules` из DNS-экрана.
- `presetDnsEnable` — одно представление.
- Rename-cascade атомарен со staging.

## Docs to update

- `CHANGELOG.md` — если правит user-visible багу рассинхрона.
