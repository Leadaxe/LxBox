# §323 — Реакция на автообновление подписки (on-update action)

| | |
|---|---|
| Статус | ✅ Реализовано (DEVICE-PENDING — на устройстве не проверялось) |
| Дата | 2026-07-31 |
| Связанные | [`030 vpn reload button`](030-vpn-reload-button.md), [`031 reset network api`](031-reset-network-api.md), [`116 banner mechanism`](116-banner-mechanism-and-config-banner-fix.md), [`features/129 file-subscription`](../features/129%20file-subscription/spec.md) |

## Проблема

Жалоба 4PDA (HubbyBubby #1376/#1380/#1386, morfisiniumus #1383 — удалил приложение,
NeoCat #1385/#1389): плашка «restart VPN to apply» вылезает каждый час, хотя юзер
ничего не менял. «В неко+ всё автоматом».

Root cause — флаг ставится по факту «конфиг изменился при живом туннеле», без
различения источника изменения:

```dart
// controllers/home_controller/config_io.dart
final needRestart = (changed && _state.tunnelUp) || _state.configChangedNeedRestart;
```

Автообновление подписки (`AutoUpdater`, periodic раз в час) идёт тем же путём:
`_fetchEntryByRef` → `_persist()` → `configDirty = true` → пересборка на возврате
на home → `saveParsedConfig` → плашка. Обновление подписки почти всегда меняет
конфиг (меняются теги/порядок нод) → плашка гарантированно раз в час.

Второй дефект, найденный по пути: `HomeController.reloadVpn()` **не сбрасывает**
`configChangedNeedRestart` (в отличие от `_startInternal()`, который сбрасывает).
То есть даже успешный in-place reload оставлял плашку висеть.

## Цель

Подписка сама знает, что делать при своём обновлении. Три режима, выбор за юзером.

## Нецели

- Отложенный reload «в тихий момент» (экран выключен / нет активных соединений) —
  отдельная задача, если жалобы на обрыв 3с придут.
- Глобальная настройка (одна на все подписки) — поле per-subscription, рядом с
  `updateIntervalHours`, той же семантикой владения.
- ~~Реакция на **ручной** refresh (⟳)~~ — **отменено в §331.** Исходное
  рассуждение: ручной refresh — явное действие юзера, он и так видит плашку и
  жмёт Apply сам. На устройстве это читалось как сломанная настройка: выбрал
  «пересобрать и перезагрузить», нажал ⟳ — ничего не произошло. Настройка
  называется «При обновлении», а не «При автообновлении». Теперь работает на
  оба пути; на ручном — только при реально изменившемся составе узлов.

## Инструменты ядра (что реально доступно)

| Механизм | Перечитывает конфиг? | Цена | Годится |
|---|---|---|---|
| `saveParsedConfig` (запись файла) | — | 0 | да, база |
| `reloadVPN()` → `startOrReloadService` (§030) | **да** | туннель дропается ~3с, in-flight TCP умирают | да |
| `resetNetwork()` (§031) | **нет** | тоже рвёт все соединения | **нет** — новые ноды не увидит |
| `reconnect()` (stop+start) | да | ~5–8с, VpnService пересоздаётся | только как ручной fallback |

`resetNetwork` отпадает по существу: сбрасывает сеть, но конфиг не читает.
Мягкого пути между «ничего» и «reload» у ядра нет.

## Модель

`SubscriptionOnUpdateAction` — enum, поле `SubscriptionServers.onUpdateAction`.

| Значение | Поведение | Плашка |
|---|---|---|
| `rebuild` (**default**) | пересобрать конфиг + записать; туннель не трогаем | остаётся — юзер сам решает когда применить |
| `reload` | пересобрать + записать; если туннель up — `reloadVPN()` | нет (сбрасывается) |
| `none` | ничего: ноды обновлены в списке, `configDirty` стоит | нет новой; применится на следующем обычном rebuild'е |

Default `rebuild` — сохраняет текущее наблюдаемое поведение для существующих
установок (миграции не требуется, отсутствие ключа = `rebuild`).

**§338 — перекрытие.** Глобальная галка «автоперезапуск при смене настроек»
(`auto_reload_on_change`) делает эффективным действием `reload` для всех
подписок, а строку «При обновлении» на экране подписки скрывает. Поле
`onUpdateAction` при этом не переписывается — выключение галки возвращает выбор
юзера. Точка входа — `AutoUpdater.effectiveOnUpdateAction`.

## Гейт «состав не изменился»

Независимо от режима: если пересборка дала байт-в-байт тот же конфиг
(`canonicalJsonForSingbox` diff в `saveParsedConfig` → `changed == false`), то
плашка **гасится**, а не просто не поднимается. Провайдеры часто отдают тот же
список нод; это отсекает большинство ложных срабатываний.

Важно: гасим только когда `changed == false` **и** сохранение прошло. Sticky-
семантика `configChangedNeedRestart` (prev=true сохраняется) для этого случая
отменяется — если saved config совпал с running, running не устарел по
определению, независимо от истории.

## Реализация

| Слой | Файл | Что |
|---|---|---|
| Модель | `models/server_list.dart` | `SubscriptionOnUpdateAction` + поле `onUpdateAction` + трио toJson/fromJson/copyWith. Ключ `on_update_action` пишется только для не-дефолта; §221 — едет в backup вместе с подпиской |
| Фасад | `controllers/subscription_controller/subscription_entry.dart` | getter + setter (persist на стороне UI через `controller.persistSources()`, как `updateIntervalHours`) |
| Применение | `services/subscription/auto_updater.dart` | `bindOnUpdateReaction` + агрегация за проход: реакция зовётся ОДИН раз в конце, `reload` побеждает `rebuild`, `manual` исключён |
| Проводка | `screens/home_screen.dart` | `_reactToSubscriptionUpdate`, привязка в `initState` после создания `HomeController`; `_rebuildConfig({silent})` глушит snackbar для фоновой пересборки |
| Гейт | `controllers/home_controller/config_io.dart` | `changed && (tunnelUp \|\| prev)` вместо `(changed && tunnelUp) \|\| prev` |
| Фикс | `controllers/home_controller.dart` | `reloadVpn()` при `ok` сбрасывает `configChangedNeedRestart` |
| UI | `screens/subscription_detail_screen.dart` + `.../widgets/subscription_settings_tab.dart` | строка «On update» под Update interval + пикер с описанием режимов. `folder_detail_screen.dart` — no-op заглушка (у папки блок скрыт) |

### Почему реакция — callback, а не прямая ссылка

`AutoUpdater` создаётся в `initState` **раньше** `HomeController` (тот берёт
апдейтер в конструктор для VPN-transitions). Инъекция после создания —
единственный порядок, при котором обе стороны видят друг друга. Не привязана
(тесты, headless) → режимы деградируют до `none`: ноды свежие, `configDirty`
стоит, применится обычным путём.

## Тесты

`test/subscription/on_update_action_test.dart` — 19 кейсов: персист поля
(включая толерантный парс мусора и старую запись без ключа), агрегация действий
за проход, гейт `needRestart` (в т.ч. регресс sticky-флага) и решение о reload.

`AutoUpdater.maybeUpdateAll` и `saveParsedConfig` целиком в юнит-тесте не
поднимаются (сеть / native-каналы), поэтому агрегация и гейты проверяются на
копиях логики — тот же приём, что в §311 `running_config_epoch_test.dart`.

## Что осталось проверить на устройстве

1. Режим `reload` при живом туннеле: конфиг применился, плашки нет, разрыв ~3с.
2. Режим `reload`, когда провайдер отдал тот же список: reload **не** сработал
   (в логе `§323: reload skipped — config identical to running`), плашки нет.
3. Режим `rebuild`: плашка есть, Apply работает, snackbar'а после фонового
   обновления нет.
4. Гашение плашки: поднять её реальной правкой, затем дождаться автообновления
   с тем же составом — плашка должна исчезнуть.
5. ~~Ручной ⟳ в режиме `reload` туннель НЕ рвёт.~~ **Изменено в §331:** рвёт,
   если состав узлов реально изменился; при неизменном составе — не рвёт.

## Docs to update

- `CHANGELOG.md` — Unreleased: новая per-subscription настройка + фикс плашки.
- `docs/ARCHITECTURE.md` — не требуется (новых подсистем/контрактов нет).
- Release notes — на bump версии.
