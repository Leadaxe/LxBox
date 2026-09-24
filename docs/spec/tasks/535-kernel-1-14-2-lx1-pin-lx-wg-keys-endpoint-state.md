# 535 — Ядро v1.14.2-lx.1 (SPEC 098: блок `lx` + SPEC 097: endpointState + SPEC 101/102)

| Поле | Значение |
|------|----------|
| Статус | **Реализовано** (бамп пина, переезд ключей, биндинг endpointState). Проверено: javap-дельта, `option/`-дифф, golden, `flutter analyze`, l10n-чекеры, CI зелёный, эмулятор (а–д все сняты) — см. «Проверка на устройстве». **Не снято:** см. «Что осталось» |
| Дата | 2026-09-24 |
| Ядро | `v1.14.2-lx.1` — lx.13 (**SPEC 097** ленивая сборка WG, **SPEC 098** корневой блок `lx`, **SPEC 101** шум GSO) плюс апстрим sing-box `1.14.2` (**SPEC 102**: сброс сети только по реальной смене интерфейса, `route/network.go` переписан; hysteria2 realm; resolved D-Bus) |
| Связанные | §526 (предыдущий бамп, lx.10), §215/§272/§128 (ключи сна), §519 (таймаут connecting), §122 (CommandClient), `docs/KERNEL.md` («Gotchas when bumping the version»), память `kernel-bump-emulator-verify` |

## Зачем

Три независимых повода, все закрываются одним пином.

**Смена сети дёргала туннель впустую.** До 1.14.2 ядро сбрасывало сетевое
состояние на каждое системное оповещение, а не только когда интерфейс правда
сменился. На телефоне, который постоянно переключается между Wi-Fi и мобильной,
это лишние разрывы. SPEC 102 переписывает `route/network.go`: сброс идёт по
настоящей смене интерфейса.

**Ключи сна жили не на своём месте.** `route.lx_idle_*` были ручками форка
внутри апстримной секции `route`. SPEC 098 собирает все глобальные ручки форка
в корневой блок `lx`, сгруппированные по подсистеме. Старые имена ядро
принимает **один релиз** и пишет WARN на каждый ключ — то есть приложение,
которое продолжает писать по-старому, засоряет лог каждого старта.

**Лог AWG-узла состоял из шума.** `failed to send handshake initiation:
disabled UDP GSO` писалось как ошибка на каждую неудачную отправку (LxBox #95).
На связь не влияло никогда, но за шумом не видно настоящей причины — в
поддержку приходили дампы, где полезного не осталось.

## Решение

### 1. Пин

- `app/android/libbox.version`: `v1.14.1-lx.10` → `v1.14.2-lx.1`;
  AAR приносит `scripts/fetch-libbox.sh` с проверкой SHA256 против релизного
  `SHA256SUMS` (маркер `.libbox.version` в `libs/`, сам AAR в git не идёт).
- Контракт (§460, готча 2 в `KERNEL.md`) **не трогаем**: новые ключи —
  корневой блок `lx`, а реестр контракта описывает поля **тела узла**
  (`registry/protocols/*.json` → `body`, `tls`, `transports`, `multiplex`,
  `dialer`). Ни `route.lx_idle_*`, ни `lx.wg.*` в реестре не встречаются
  (`grep` по `app/contract/registry/` пуст), поэтому синк контракта этот бамп
  не требует.
- Готча 6 (`vless.encryption`) ни при чём: `lx_encryption.go` в диффе релиза
  не участвует.

### 2. Переезд ключей сна (`build_config.dart`)

Ключи пишутся в новое место и **только** в него:

| Старый ключ | Новый ключ |
|---|---|
| `route.lx_idle_suspend` | `lx.wg.idle_suspend` |
| `route.lx_idle_suspend_reachable` | `lx.wg.idle_suspend_reachable` |
| `route.lx_idle_teardown` | `lx.wg.idle_teardown` (приложение не пишет) |

Условие эмиссии не менялось: блок пишется только когда порог задан, reachable —
только вместе с базовым (ядро: `lx.wg.idle_suspend_reachable requires
lx.wg.idle_suspend`). Пустой порог = блока `lx` в конфиге нет вовсе, то есть
прежний kill-switch (идл-тик не запускается).

**Почему не пишем оба имени.** Ядро принимает старые ключи ещё один релиз, но
на каждый пишет WARN; одно и то же значение в обоих местах — тоже WARN, разные
значения — ядро не стартует (`route.lx_idle_suspend conflicts with
lx.wg.idle_suspend`). Единственная форма без шума — писать только новые имена.

**Чего НЕ включаем.** `lx.wg.lazy_build`, `lx.wg.build_max`,
`lx.wg.build_overflow` (SPEC 097) по умолчанию не пишутся — это отдельное
решение владельца (см. «Вопросы владельцу»). `lx.masque.idle_timeout`
(глобальный дефолт для masque-узлов) не пишется тоже: у узлов WARP MASQUE свой
`idle_timeout` 5m в самом узле, а он приоритетнее глобального.

**Хранение не переезжало.** Ключи storage (`route_idle_suspend`,
`route_idle_suspend_reachable`) и их набор в экспорте бэкапа не менялись —
сменилось только имя в JSON конфига. Экспорт/импорт бэкапа и Debug API `/config`
читают storage, а не конфиг, поэтому правок не потребовали.

### 3. `endpointState` в биндинге и UI

Ядро (SPEC 097) отдаёт по каждому WG/AWG-endpoint'у состояние
(`never_built` / `building` / `up` / `asleep` / `torn_down` / `down`) и секунды
простоя.

**Ключевая деталь маршрута.** Поля заполняет **только** ответ `GetOutbounds`:

| Путь | Несёт поля? | Почему |
|---|---|---|
| `GetOutbounds` (unary pull) | **да** | `daemon/started_service_command_lx.go:341-345` заполняет из `adapter.IdleStateReporter`, конвертер `outboundGroupItemListFromGRPC` копирует |
| `SubscribeOutbounds` (поток) | нет | список собирается апстримным кодом, поля не ставятся |
| `GetGroups` / `SubscribeGroups` (дерево) | нет | конвертер `outboundGroupIteratorFromGRPC` поля не копирует |

Поэтому `serializeGroup` (общий для дерева и push'а) трогать нечего, а заведён
отдельный unary-pull:

- **Kotlin**: `BoxCommandClient.getOutbounds()` через `ensurePingClient()`
  (§209 — lifecycle-независим, читается и из фона), no-throw (`runCatching`):
  `null` = не прочитали, `[]` = пусто. Метод канала `ccGetOutbounds` в
  `VpnPlugin` на `Dispatchers.IO` (unary RPC на main = ANR, §122).
- **Dart**: `CcOutbound` получил `endpointState` / `idleSinceSeconds` с
  дефолтами `''` и `0` — старое ядро и остальные пути деградируют в «состояние
  неизвестно», не в ошибку. Имена состояний — в `CcEndpointState` одним местом.
- **Контроллер**: `_refreshEndpointStates()` на здоровом heartbeat-тике (5 с,
  туннель живой). `null` от ядра прошлую карту не стирает; `emit` только когда
  карта изменилась (иначе будили бы UI каждые 5 с). Карта глобальна по тегу, а
  не per-Направление: одно устройство обслуживает все Направления сразу.
- **UI**: `NodeRow` показывает `Node not built yet` (`never_built`/`torn_down`)
  и `Node asleep` (`asleep`) в левой части подзаголовка. Правый бейдж узкий и
  моноширинный — фраза туда не влезает; подпись идёт последней и при нехватке
  ширины уступает протоколу и выбранному серверу. Состояния `up`/`building`/
  `down` подписи не требуют.

«Не собран» — **состояние, а не ошибка**: ядро поднимет узел на первом дайле за
0,5–1 с, поэтому вместо таймаута показываем словами.

### 4. Таймаут connecting (§519) — ложно не срабатывает

Проверено по коду, правок не потребовалось. Порог §519 —
`min(15с + 10с × N, 4 мин)`, где N — число узлов `kind == 'endpoint'`
(`home_controller.dart:583/588/594/601`). Ложное срабатывание на ленивой сборке
исключено дважды:

1. **Таймер туннельного уровня, а не поузловой.** Ставится в
   `_armTransientTimeout` на статусе `Starting` и снимается на любом
   нетранзитном терминальном событии, то есть на `Started`
   (`home_controller.dart:557-569`). Ленивый первый дайл происходит **после**
   `Started` — окно к тому моменту уже закрыто.
2. **Запас на порядок больше.** Надбавка 10 с на endpoint снималась против
   замеров 6,8–9,3 с; 0,5–1 с сборки в неё укладывается с запасом.

Настоящий риск у формулы противоположный и к §535 отношения не имеет: при
N ≥ 24 упирается в потолок 4 мин, и линейный рост прекращается.

## Проверка API

javap по `classes.jar` из **релизных** AAR обеих версий (lx.10 скачан из
Releases, а не взят из `libs/` — там он мог протухнуть), обход всех классов
одной командой:

- списки классов совпадают: **253 класса** в обеих версиях, дифф имён пуст;
- дифф сигнатур — **3494 → 3498**, ровно четыре добавленные строки:

```
2222a2223,2226
>   public final native java.lang.String getEndpointState();
>   public final native void setEndpointState(java.lang.String);
>   public final native long getIdleSinceSeconds();
>   public final native void setIdleSinceSeconds(long);
```

  объявлены в `io.nekohasekai.libbox.OutboundGroupItem`. Дельта чисто
  аддитивная: ничего не удалено и не изменено;
- sha256 релизных AAR (оба совпали с `SHA256SUMS` своих релизов):
  - lx.1 — `ba470fee1b5ec6c112b64533abc0aefc72e7e5a27988330b223aba9cc8d8e2a3`
  - lx.10 — `1ff7f0ee1497513ce0dbd9d450945dd98b35d5710bc0d5785ec24db0314a6a5c`

  sha256 `classes.jar` показателем не является — gomobile AAR не
  байт-воспроизводим (готча 3).

## Проверка `option/`

`git diff v1.14.1-lx.10 v1.14.2-lx.1 -- option/` — 6 файлов. По ключам, которые
пишет LxBox (`DisallowUnknownFields`: любой ушедший ключ = ошибка старта):

| Файл | Что изменилось | Для LxBox |
|---|---|---|
| `option/lx.go` (новый) | блок `LXOptions` (`lx.wg.*`, `lx.masque.idle_timeout`), `ResolveLX` с алиасами и валидацией | пишем `lx.wg.idle_suspend[_reachable]` |
| `option/options.go` | `+ LX *LXOptions \`json:"lx,omitempty"\`` | корневой ключ `lx` признан |
| `option/route.go` | три `lx_idle_*` помечены Deprecated, тела прежние | старые ключи ещё читаются (WARN) |
| `option/masque.go` | `IdleTimeout` стал `*badoption.Duration` | форма JSON не изменилась: `"5m"` как было; указатель нужен ядру, чтобы отличать явный `"0"` от отсутствия |
| `option/hysteria2.go` | `+ STUNServersIsDomain()` (realm, серверная часть) | не используем |
| `option/lx_test.go` | тесты нового блока | — |

**Ни один ключ, который пишет LxBox, не удалён и не переименован без алиаса.**
Единственное изменение формы (`masque.idle_timeout` → указатель) на JSON не
влияет.

## Проверка golden

`UPDATE_GOLDEN=1 flutter test test/storage_migration/` — дифф ровно переезд
ключей, значения те же:

```
-    "lx_idle_suspend": "1m",            (route)
-    "lx_idle_suspend_reachable": "10m"
+  "lx": { "wg": { "idle_suspend": "1m", "idle_suspend_reachable": "10m" } }
```

То же для `avd_v0` (`30s` / `5m`). В `rich_v0.backup_roundtrip.json` прежняя
запись о расхождении значений круга бэкапа осталась той же по сути и сменила
путь (`$.route.lx_idle_suspend` → `$.lx.wg.idle_suspend`) — это довыездная
разница (категории экспорта), задачей не вносилась.
`avd_v0.backup_roundtrip.json` относительно HEAD **не изменился**.

## Регресс

- `flutter analyze` — `No issues found!`.
- `flutter test test/builder/build_config_test.dart test/storage_migration/` —
  **80/80**. Тесты §215/§272 переписаны на новый путь: проверяют значения в
  `lx.wg`, отсутствие старых ключей в `route`, отсутствие `lazy_build` /
  `build_max` / `build_overflow` и отсутствие блока `lx.masque`.
- Полный `flutter test` локально не гоняется (регламент: прогон — в CI).

## Проверка на устройстве

Эмулятор `emulator-5554` (AVD `LxBox_test`, Android 14 / arm64-v8a), вход **A** —
AmneziaWG 3 из демо-набора. APK собран регламентом (`scripts/build-local-apk.sh`,
`--build-number` руками не передаётся), 42,8 МБ.

| Шаг | Ожидание | Факт |
|---|---|---|
| **(а)** версия ядра | `1.14.2-lx.1` в APK и на устройстве | `strings` по `lib/arm64-v8a/libbox.so` — **ровно одна** строка `1.14.2-lx.1`, `lx.10` не встречается; `GET /device` → `core_version: 1.14.2-lx.1`, app `2.25.3-dev.14` (build 22503502) ✅ |
| **(б)** старт с AWG-узлом | лог ядра без WARN о `lx_idle_*`, без ошибок старта | Сначала туннель поднялся на **сохранённом старом** конфиге — и ядро честно написало обе строки `route.lx_idle_suspend[_reachable] is deprecated`. После `POST /action/rebuild-config` конфиг стал `lx.wg.{idle_suspend: 30s, idle_suspend_reachable: 5m}`, `route.lx_idle_*` — пусто. На перезапуске туннеля в свежем логе (418 записей): `lx_idle` — **0**, `deprecated` — **0**, `conflicts with` — **0**, `panic` — **0**, `unknown field` — **0**, `mobile-only feature` — **0** ✅ |
| **(в)** смена сети при живом туннеле | туннель переживает, одно обновление интерфейса на смену | `svc wifi disable` → `enable`: `tunnel: connected` до, между и после. В логе окна **одна** строка `network: updated default interface wlan0, index 16, type wifi` — не на каждый тик ✅ (SPEC 102) |
| **(г)** `endpointState` виден для WG-узла | `up` → после `idle_suspend` → `asleep` | `GET /state` → `endpoint_states` сразу после старта: все три WG/AWG-узла `up`. На t≈100 с два простаивающих ушли в **`asleep`** (`WARP (AWG 1.5)`, `WireGuard-1`), а несущий трафик `WireGuard` остался `up` ✅ Цепочка целиком: ядро `GetOutbounds` → Kotlin `getOutbounds()` → канал → Dart `CcOutbound.endpointState` → pull на heartbeat → `HomeState.endpointStates` → Debug API |
| **(д)** heap сессии ядра | цифра в отчёт | `GET /diag/pprof?profile=heap&query=debug=1` при живом туннеле, 12 узлов: **HeapAlloc 85,4 МБ**, HeapInuse 92,5 МБ, HeapSys 125,4 МБ, Sys 135,4 МБ, HeapReleased 24,5 МБ, NumGC 13 |

**Шум GSO (SPEC 101) — подтверждён попутно.** В свежем логе три строки
`disabled UDP GSO`, и все три уровня **`debug`**; в старой части буфера (сессия
от 14.09, ядро lx.10) та же ситуация писалась уровнем `ERROR`. Три строки
`ERROR ... failed to send handshake initiation: ... sendmsg: input/output error`
в новом логе относятся к **чужим** простаивающим пирам (`WireGuard`,
`WireGuard-1`, `WARP (AWG 1.5)`) из прежнего хранения стенда — известный артефакт
эмулятора, к пину и к узлу A отношения не имеет.

**Дополнительно понадобилось:** состояния endpoint'ов видны только в UI, а
headless наблюдать их было нечем — `GET /state` их не отдавал. Добавлено поле
`endpoint_states` (карта `тег → состояние`) плюс строка в
`docs/api/debug-api-reference.md`.

## Что осталось

**Подпись в UI глазами не снята.** `Node not built yet` / `Node asleep`
проверены по коду и по данным (состояние `asleep` до виджета доезжает —
`endpoint_states` тому подтверждение), но скриншота списка узлов с подписью в
этом прогоне нет: состояние снималось через Debug API, а не тапами по экрану.

**`never_built` / `torn_down` на стенде не воспроизводились.** Оба требуют
`lx.wg.lazy_build` либо разборки по `idle_teardown`, а приложение ни того, ни
другого по умолчанию не пишет (решение владельца отложено). Ветка UI для них
написана и разобрана тестом компилятора, но живого состояния на стенде не было —
только `up` и `asleep`.

## Вопросы владельцу — закрыты в §536

Оба решены 24.09.2026: `lazy_build: true` и `build_max: 5` пишутся всегда
рядом с `idle_suspend`; probe-сессии эти ключи не получают (свой конфиг, своя
защита батчами). См. [спеку §536](536-lx-wg-lazy-build-build-max.md).

<details><summary>Исходная формулировка</summary>

1. **`lx.wg.lazy_build` по умолчанию?** Даёт экономию на старте (устройство
   каждого AWG-узла ≈17,5 МБ приёмных батчей, собираются все сразу), платит
   0,5–1 с на первом дайле узла. Требует включённого `idle_suspend` (у нас он
   по умолчанию `30s`, то есть условие выполнено). Сейчас не пишем.
2. **`lx.wg.build_max` для probe-сессий?** Ядро прямо рекомендует потолок
   именно для сессий с массовыми пробами, а не как общую ручку памяти: потолок
   ниже числа одновременно используемых узлов заставляет узлы разбирать друг
   друга на каждом переключении. Probe-сессия (`ProbeSession.kt`) — ровно тот
   случай. Ставить ли, и какое N?

</details>
