# §311 — Running config от ядра (клиентская часть SPEC 036)

**Тип:** таска (bug-fix через новый kernel-RPC)
**Статус:** реализовано; работоспособно с ядра `v1.14.0-lx.17-rc.1`
(device-verified 27.07.2026). На `lx.16-rc.3` и stable `lx.16` — **не
работало**: см. «Ядро» ниже.
**Ядро:** sing-box-lx [SPEC 036 GetRunningConfig](../../../../sing-box-lx/SPECS/TASKS/036-RUNNING_CONFIG_RPC/SPEC.md)
+ [SPEC 038](../../../../sing-box-lx/SPECS/TASKS/038-GOMOBILE_STRING_RETURN_FRAME_KILL/SPEC.md)
(фикс), AAR `v1.14.0-lx.17-rc.1`

> ⚠️ **SPEC 038.** Первая редакция RPC возвращала голый `string`, и это
> **убивало процесс ядра на android/arm64 при каждом вызове** (`throw:
> bulkBarrierPreWrite: unaligned arguments` — gomobile кладёт строку в
> packed-фрейм, тот теряет 8-выравнивание, write-barrier делает fatal
> throw). Фича была мертва в rc.3 и в stable `lx.16` — то есть **в
> релизе v2.18.0 §311 фактически не работал**, хотя заметки утверждали
> обратное. Так падало ядро 26.07 (три репорта, найдены каналом §316).
> С `lx.17-rc.1` метод возвращает `RunningConfig` с геттером `content()`;
> клиент правится в `BoxCommandClient.getRunningConfig()`.
**Связано:** §309 (первая попытка, ревертнута — 5b3722e8/5f9655d4), §116 (плашка restart), §091 (`ParsedConfig`), §122 (CommandClient), §302/§307 (import-rules — типовой источник смены тегов)

---

## 1. Симптом и корень

Long-press по ноде → «View details» → `Not found: L: 🇫🇷zФранция`, при том что
нода видна в списке и активна. Device-verified 26.07.2026; воспроизводится
заменой §302 (`⚡`→`z`) / сменой `tag_prefix` на живом туннеле.

Корень — смешение срезов:

```
Nodes list   ← ccGroups (CommandClient)  = память ядра (старый конфиг)
resolve тега ← configRaw (файл)          = последняя пересборка (новый конфиг)
```

В окне между пересборкой и рестартом теги двух срезов расходятся.

### Почему §309 был неправильным и ревертнут

§309 разводил `configRaw` на actual/pending **в памяти Dart**, но у «actual»
не было собственного источника: наполнение шло из того же файла
(`getConfig()`), который пересборка перезаписывает. После рестарта приложения
поверх живого туннеля поле лгало о себе — «actual» на деле был pending.
Фундаментально: правда о работающем конфиге есть только у ядра, а ядро её
до SPEC 036 не отдавало (`getOutbounds()` — лишь tag/type/delay).

## 2. Решение

**Правду о ядре спрашивать у ядра.** SPEC 036 добавил
`CommandClient.GetRunningConfig` — канонический снапшот запущенных options,
захваченный один раз на старте ядра. Клиент держит его отдельным полем и
резолвит по нему всё, что отвечает на вопрос «как устроен узел, который
прямо сейчас крутится». `configRaw` возвращает исторический смысл —
«свежий сохранённый файл» — и не трогается вовсе.

javap rc.3 (проверено до сборки, §178):

```
public native java.lang.String getRunningConfig() throws java.lang.Exception;
```

gomobile развернул `RunningConfig{content}` в плоскую строку.
`PlatformInterface` / `CommandClientHandler` между lx.15 и rc.3 не изменились.

## 3. Модель данных

```
HomeState:
  configRaw        — сохранённый файл (редактор, старт, §116-дифф)   КАК БЫЛО
  runningConfigRaw — снапшот от ядра (nullable)                      НОВОЕ
  runningModel     — ParsedConfig от него (парс 1 раз в copyWith)    НОВОЕ

  activeModel     => tunnelUp && runningModel != null ? runningModel : configModel
  activeConfigRaw => tunnelUp && runningConfigRaw != null ? runningConfigRaw : configRaw
```

`activeModel` — единственная точка выбора среза. Никаких pending, никаких
промоушенов, флаг §116 (`configChangedNeedRestart`) не трогается.

## 4. Раскладка потребителей

### → activeModel / activeConfigRaw («что реально крутится»)

| Место | Что берёт |
|---|---|
| [node_actions.dart](../../../app/lib/screens/home/node_actions.dart) View/Copy JSON | `outboundChain`/`rawOf`/`detourOf` — ровно баг из симптома |
| [node_list_presenter.dart](../../../app/lib/screens/home/node_list_presenter.dart):62,72,141,208,214 | протокол/detour-метки строк ← строки из `ccGroups` |
| [home_state.dart](../../../app/lib/models/home_state.dart) `isControlTag`, `sortedNodes` pin-by-type | тип узла для списка из ядра |
| [ping_orchestration.dart](../../../app/lib/controllers/home_controller/ping_orchestration.dart):25,250 | block-guard — пингуем то, что в ядре |
| [home_controller.dart](../../../app/lib/controllers/home_controller.dart) `_pushNotificationLabels` | `route.final` для шторки (activeConfigRaw) |
| [traffic_bar.dart](../../../app/lib/screens/home/widgets/traffic_bar.dart), [home_drawer.dart](../../../app/lib/screens/home/widgets/home_drawer.dart) → StatsScreen | routing-цепочки трафика (activeConfigRaw) |

### → configRaw (файл) — НЕ трогаем

| Место | Почему |
|---|---|
| редактор ([config_screen.dart](../../../app/lib/screens/config_screen.dart)) | правишь то, что сохранится; снапшот — re-marshal |
| §116-дифф в `saveParsedConfig` | сравнение saved-vs-saved; см. инвариант ниже |
| «есть что стартовать» (home_controls / home_screen) | вопрос о файле |
| `PUT /config`, экспорт, dump_builder | пишем/отдаём файл |
| `_applyGroups` → `RouteConfig.finalTag` | вызывается ДО lazy-fetch снапшота (это его же триггер) — на первом проходе снапшота ещё нет; выбор группы по тегам селекторов, их переименование и так требует рестарта |

### Инвариант: снапшот не участвует в diff'ах

`content` — **re-marshal распарсенных options**, не байты клиента: порядок
полей, omitempty, `[]→null`, post-override мутации tun
(`IncludePackage`/OOM-killer). Любое сравнение с файлом даст вечный
«изменился» → плашка горит всегда. Снапшот — только чтение структуры узлов
для resolve/показа. §116-логика остаётся на паре saved-vs-saved.

Следствие для UI: View details показывает **каноническую форму ядра**
(другой порядок полей, подмешанный tun) — это правда о запущенном,
ожидаемое поведение, не баг.

## 5. Жизненный цикл снапшота

| Событие | Действие |
|---|---|
| Переход в `connected` (не дубль) | **прямой** захват `_captureRunningConfig()` — `unawaited`, с ретраем шагами groups-pull (новый box становится STARTED не мгновенно) |
| `reloadVpn()` | сброс + тот же прямой захват |
| любой сброс снапшота | `_invalidateRunningConfig()` — bump epoch'а + сброс **одним движением** (см. epoch-гейт ниже) |
| Переход в down (disconnected/revoked / force-stop timeout / heartbeat-dead) | сброс в null — те же copyWith, что чистят `ccGroups` |
| Холодный старт приложения поверх живого туннеля | CC приаттачился → `connected` → захват → **дыра §309 закрыта**: правда от ядра, файл не при чём |

**Почему триггер прямой, а не от groups.** Первая редакция вешала захват на
`_applyGroups` — device-тест 26.07 показал дыру: при in-place reload
groups-push может не прийти вовсе (CommandClient переживает reload, дерево
групп то же, `_startGroupsPull` заводится только на переходе в connected,
которого при reload нет — §049 F4). Снапшот залипал в `null` до конца сессии,
и весь UI молча деградировал на saved-файл. Захват обязан висеть на **своём**
событии, а не быть побочным эффектом чужого пути.

### Epoch-гейт (найдено ревью диффа)

`tunnelUp` **не различает сессии ядра**: in-place reload идёт без status-flap
(§049 F4 — ядро остаётся `Started`), `CommandServer` его переживает, groups-стрим
не гасится, а `reloadVPN` — асинхронный broadcast (native возвращает управление
до подмены box'а). Значит fetch, стартовавший до/во время reload'а, отвечает
конфигом **старого** box'а; пост-await проверки `_disposed || !tunnelUp`
пропустили бы его, и он закоммитился бы ПОСЛЕ сброса. Дальше pre-check
`runningConfigRaw != null` блокирует refetch — stale-снапшот управляет
`activeModel` до конца сессии, т.е. баг §311 воспроизводится изнутри фикса.

Решение: счётчик `_runningConfigEpoch`, снимается перед `await`, сверяется
после; расхождение → ответ дропается (следующий groups-push перезапросит).
Сброс снапшота и bump — только через `_invalidateRunningConfig()`, который
возвращает `null` для `copyWith`, поэтому «сбросил, но забыл bump'нуть»
невыразимо. Образец — epoch-гейт mass-ping'а в этом же контроллере.

## 6. Матрица деградации

| Ситуация | activeModel | Поведение |
|---|---|---|
| туннель up, ядро rc.3+ | снапшот ядра | точный resolve всегда |
| туннель up, старое ядро / `Unavailable` / attached-путь | configModel | сегодняшнее поведение: окно есть, плашка предупреждает — не хуже |
| туннель down | configModel | как сегодня |

Контракт обвязки (модель §209): `CcChannel.getRunningConfig()` →
`Future<String?>`, `null` = недоступен по любой причине
(`FailedPrecondition`/`Unavailable`/`Unimplemented`/канал down/старый
native). Kotlin: `runCatching` + `Dispatchers.IO` (unary на main = ANR).

## 7. Изменения по файлам

1. [home_state.dart](../../../app/lib/models/home_state.dart) — поля
   `runningConfigRaw`/`runningModel` (`_unset`-паттерн в copyWith, парс 1 раз),
   геттеры `activeModel`/`activeConfigRaw`; `isControlTag`+`sortedNodes` → activeModel.
2. [cc_channel.dart](../../../app/lib/vpn/cc_channel.dart) — unary
   `getRunningConfig()` (null-контракт).
3. [home_controller.dart](../../../app/lib/controllers/home_controller.dart) —
   `_ensureRunningConfig` + вызов из `_applyGroups`; сбросы (connected, down×3,
   `reloadVpn`); шторка → activeConfigRaw.
4. [node_actions.dart](../../../app/lib/screens/home/node_actions.dart) —
   resolve по activeModel; Copy JSON перестаёт молчать при промахе
   (анти-паттерн §277/§278), общий `_showTagMissing`.
5. [node_list_presenter.dart](../../../app/lib/screens/home/node_list_presenter.dart),
   [ping_orchestration.dart](../../../app/lib/controllers/home_controller/ping_orchestration.dart),
   [traffic_bar.dart](../../../app/lib/screens/home/widgets/traffic_bar.dart),
   [home_drawer.dart](../../../app/lib/screens/home/widgets/home_drawer.dart) — activeModel/activeConfigRaw.
6. [VpnPlugin.kt](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt) —
   handler `ccGetRunningConfig` (образец `ccGetGroups`; no-throw, IO).
7. Debug API — `GET /config/running` (409 при отсутствии; + в `/help`),
   `running_config_length` в `GET /state`
   ([handlers/config.dart](../../../app/lib/services/debug/handlers/config.dart),
   [serializers/home_state.dart](../../../app/lib/services/debug/serializers/home_state.dart)).
8. `app/android/libbox.version` → `v1.14.0-lx.17-rc.1` (SPEC 038; на
   `lx.16*` метод фатален — см. шапку).
9. Доки: debug-api-reference, DIAGNOSTICS, KERNEL (rc-история).

## 8. Секреты

Снапшот содержит приватные ключи as-is (SPEC 036 §4). Новой поверхности нет:
`GET /config` и так отдаёт файл с ключами, канал тот же (localhost + Bearer).

## 9. Тесты

`test/models/home_state_running_config_test.dart`:

1. activeModel: down → configModel; up+снапшот → runningModel; up без снапшота → configModel.
2. activeConfigRaw — симметрично.
3. **Регресс §311** (переформулированный регресс §309): туннель up, saved
   переименовал тег (`⚡`→`z`), снапшот держит старый → тег ядра резолвится
   через activeModel, тега из saved в activeModel нет.
4. copyWith: set / clear (null) / preserve; `runningModel` шарится между
   copyWith без смены raw (identity, §091) и пересоздаётся при смене.
5. Парс kernel-style JSON (re-marshal форма: null вместо [], endpoints).
6. `isControlTag`/`sortedNodes` берут тип из снапшота при tunnelUp.

`test/controllers/running_config_epoch_test.dart` — epoch-гейт:
регресс «ответ старого box'а не переживает reload», разблокировка refetch
после дропа, guard от параллельных, инвариант «сброс ⟺ bump».

## 10. Device-verify (после сборки rc.3)

1. Рецепт §309: живой туннель → правка import-rule `substitute` → плашка →
   long-press → View details: **JSON открывается** (старый срез от ядра),
   Copy JSON копирует. После рестарта — данные нового конфига.
2. Дыра §309: убить приложение (swipe) поверх живого туннеля → переоткрыть →
   View details по ноде: работает (снапшот от ядра, не файл).
3. `GET /config/running` отдаёт снапшот; `running_config_length` в `/state`;
   при туннеле down — 409.
4. `reloadVpn` → снапшот перезахвачен (не stale).
