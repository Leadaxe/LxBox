# §337 — Обновлять выключенные подписки (глобальная галка)

| | |
|---|---|
| Статус | ✅ Реализовано (DEVICE-PENDING) |
| Дата | 2026-08-02 |
| Связанные | [`027 subscriptions`](../features/027%20subscriptions/spec.md), [`323 on-update action`](323-subscription-on-update-action.md), [`331 blue banner`](331-blue-banner-and-manual-refresh-reaction.md) |

## Проблема

Выключенная подписка (`SubscriptionServers.enabled == false`) авто-обновление
не получает вовсе:

```dart
// services/subscription/auto_updater.dart — shouldUpdatePure
if (!list.enabled) return false;
```

Узлы в ней тухнут: панель отдала новый список, сменились адреса/теги — а в
приложении лежит снапшот месячной давности. Юзер включает подписку и получает
мёртвые узлы, хотя приложение весь месяц имело сеть и время обновиться.

Обходной путь — включить, дождаться обновления, выключить — на каждую подписку
и вручную.

## Решение

Глобальная галка в App Settings → Subscriptions: **«Update disabled
subscriptions»**. Снимает гейт `!enabled` для авто-путей. Off по умолчанию —
сохраняет текущее поведение.

Галка глобальная, не per-subscription: смысл у неё один на всё приложение
(«держать снапшоты свежими»), per-subscription поле дублировало бы `enabled` и
рождало бессмысленную комбинацию «выключена + не обновлять» = сегодняшнее
поведение.

## Что галка НЕ меняет

| | Почему |
|---|---|
| Ручной ⟳ выключенной подписки | работал и до галки: `updateAt` → `_fetchEntry` идёт мимо `shouldUpdatePure`, гейта там нет |
| Билдер | выключенная подписка в конфиг не попадает независимо от свежести снапшота |
| `updateIntervalHours <= 0` | «не обновлять автоматически» (§129, файловые подписки) — сильнее галки, проверяется своим гейтом ниже |
| Глобальный `auto_update_subs` | выключен → не обновляется вообще ничего, включая включённые подписки. Наша галка живёт внутри этого «да» |

Порядок гейтов в `shouldUpdatePure` после правки:

```
!enabled && !updateDisabled  → false   ← новое условие
fails >= cap && !force       → false
force                        → true
updateIntervalHours <= 0     → false
min-retry / interval         → …
```

`force` остаётся **ниже** `enabled`-гейта — как и было: `force` приходит из
restore-backup и «обновить все» (§027), и включать им замороженные выключенные
подписки при снятой галке не нужно.

## Пересборка конфига

Обновление выключенной подписки состав активного конфига не меняет. Реакция
§323/§331 гейтится `compositionChanged` от `refreshEntry` — а тот сравнивает
состав узлов подписки, не итоговый конфиг. Выключенная подписка со сменившимся
списком вернёт `true` → пересборка + (в режиме `reload`) reload туннеля из-за
подписки, которой в конфиге нет.

Поэтому в агрегации `maybeUpdateAll` реакция берётся только с **включённых**
подписок. Пересборка от выключенной не нужна по построению: билдер её узлы не
читает, конфиг не изменится, §324 всё равно вынесет `fresh`, — но и гонять
пустой rebuild-цикл раз в час незачем.

## Реализация

| Слой | Файл | Что |
|---|---|---|
| Storage | `services/settings_storage.dart` | ключ `auto_update_disabled_subs` + `get/setAutoUpdateDisabledSubs`; в `_appFeatureFlagVars` (allowlist §221) |
| Гейт | `services/subscription/auto_updater.dart` | `shouldUpdatePure({required bool updateDisabled})`; чтение флага в `maybeUpdateAll` рядом с `getAutoUpdateSubs`; реакция — только с `list.enabled` |
| UI | `screens/app_settings_screen/widgets/subscriptions_tab.dart` | `SwitchListTile` под «Auto-update subscriptions», зависимая (`onChanged: null` при выключенном родителе) |
| Проводка | `screens/app_settings_screen.dart` | поле состояния + чтение в `_loadAutoStart` + колбэк |

Флаг читается в `maybeUpdateAll` (один раз за проход) и передаётся в
`shouldUpdatePure` параметром — pure-функция системных зависимостей не
получает, как и `now`/`fails`.

## Тесты

`test/subscription/auto_updater_test.dart`, группа «§337 — updateDisabled»:

- выключенная подписка: `updateDisabled: false` → skip; `true` → обновляется;
- `updateDisabled: true` не отменяет `updateIntervalHours <= 0` (файловые);
- `updateDisabled: true` не отменяет min-retry и fail-cap;
- включённая подписка от флага не зависит;
- дефолт ключа = `false` (существующие установки поведение не меняют).

## Device-verify

1. Выключить подписку, галку не ставить → за час `last_updated` не сдвинулся.
2. Поставить галку → на следующем тике `last_updated` обновился, подписка
   осталась выключенной.
3. Выключенная подписка со сменившимся составом + галка + режим `reload`:
   туннель НЕ дропнулся, плашки нет.
4. Глобальный «Auto-update subscriptions» off + галка on → не обновляется
   ничего.

## Docs to update

- `CHANGELOG.md` — Unreleased.
- `docs/STORAGE.md` — ключ `auto_update_disabled_subs`.
