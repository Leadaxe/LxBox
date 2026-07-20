# §295 — DNS dual-write фикс: убрать half-stage/half-write в экране

**Тип:** structural refactor (Шаг 2b фичи [§291](../features/291%20layered-architecture-facades/spec.md)) · **Статус:** device-required (не делать вслепую) · **Размер:** M · **Зависит от:** [§294](294-dns-typed-model.md)

> **Оценка при реализации (почему device-required):** 4 `unawaited
> saveCustomRules` — НЕ «забыли завернуть в staging». `custom_rules` — чужой
> экрану storage-ключ (владелец routing), а `stageChanges` dns_settings стейджит
> только `dns_servers`/`dns_rules`/dns-vars. Правки правил пишутся сразу, потому
> что иначе потерялись бы при уходе с экрана. Фикс (добавить custom_rules в
> staged-путь этого экрана) завязан на UI-lifecycle: staging/dispose-flush/
> навигацию между dns_settings и routing, где `custom_rules` шарится. Тихая
> потеря правок правил при неверном staging проверяется только на устройстве
> (staged flush:false + уход до dispose + конфликт с открытым routing).
> **Строить в цикле код→APK→устройство**, не вслепую.

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
