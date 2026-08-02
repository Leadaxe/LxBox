# §340 — Wake-нудж: `SCREEN_ON` → `rebindStaleEndpoints()` (потребитель SPEC 041 v2)

| | |
|---|---|
| Статус | v1 (`USER_PRESENT`) вошло в v2.19.2 (AAR `v1.14.0-lx.19-rc.3`). **v2 (`SCREEN_ON`, 02.08) — переезд события по итогам device-прогонов**: на `USER_PRESENT` нудж стабильно опаздывал (см. HISTORY ниже), ловилcя только `trigger=early` ядра. Device-верификация самого нуджа — остаток |
| Дата | 2026-08-02 |
| Связанные | ядро [SPEC 041 v2](https://github.com/Leadaxe/sing-box-lx/blob/lx/SPECS/TASKS/041-WG_HANDSHAKE_GIVEUP_REBIND/SPEC.md) (сам механизм, все гейты там), [`086`](086-stale-connections-network-change-doze.md) (root-cause, failure mode 2), [`087`](087-network-change-force-reset.md) (сосед: failure mode 1), [`088`](088-wake-heal-escalation.md) (остаётся заморожен — эта таска реализует только его entry-событие), §304/§313 (keepalive — профилактика, пока телефон не спит) |
| Жалоба | «варпы протухают со временем» (повторная, 4PDA); дамп `lxbox-dump-2026-08-01T18-49-34` |

## Проблема

После сна устройства NAT/DPI-состояние 5-tuple всех WG/AWG-узлов умирает.
Ядро лечит это само (SPEC 041): v1 — rebind по give-up (~90-я секунда после
первого спроса), v2 — досрочно (~15-я секунда). Но юзер меряет пинг в первые
5–35 с после разблокировки (в дампе — три mass ping за полминуты) и видит ERR.

SPEC 041 v2 добавил для этого третий триггер — событийный нудж
`CommandServer.RebindStaleEndpoints()`: ядро проходит по endpoint'ам и
ребиндит **только** доказуемо мёртвые сессии (нет keypair / handshake старше
180 с), остальным — no-op. Окно ERR схлопывается до одного RTT рукопожатия.
Ядро готово; не хватает вызывающего — этой таски.

## Решение

Одна ветка в **существующем** runtime-ресивере `BoxService` (тот же, что
обслуживает `ACTION_RESET_NETWORK` и `SCREEN_ON/OFF`):

```kotlin
Intent.ACTION_SCREEN_ON -> {
    // wake() — только в BG_MODE_ALWAYS: пара к SCREEN_OFF → pause (§215).
    if (BootReceiver.getBackgroundMode(service) == BootReceiver.BG_MODE_ALWAYS) {
        commandServer.get()?.wake()
    }
    // §340 — нудж: ядро ребиндит только доказуемо стухшие WG/AWG-сессии
    // (стале-предикат + дебаунс 90 с — в ядре, вызов неблокирующий).
    Log.d(TAG, "[vpn] SCREEN_ON → rebindStaleEndpoints")
    runCatching { commandServer.get()?.rebindStaleEndpoints() }
        .onFailure { Log.e(TAG, "rebindStaleEndpoints failed", it) }
}
```

и регистрация в `IntentFilter` в `onStartCommand` — `SCREEN_ON` переезжает
**из** `when(mode)` наружу (`SCREEN_OFF` остаётся режимным):

```kotlin
addAction(Intent.ACTION_SCREEN_ON)   // §340 — вне when(mode), см. ниже
```

### Решения по месту

| вопрос | решение |
|---|---|
| Почему `SCREEN_ON`, а не `USER_PRESENT` | **Гонка со спросом трафика.** Приложения лезут в сеть сразу по включению экрана, до снятия keyguard: в device-прогоне 02.08 при разблокировке уже шли `outbound connection` через WARP-узел, ядро начинало цикл ретраев, и сессию чинил досрочный rebind — нудж приходил на всё готовое. Нудж обязан успеть ДО первого спроса, поэтому событие сдвинуто на включение экрана. Ложные срабатывания (AOD, экран включили и погасили) безопасны: гейт стухлости в ядре делает их no-op |
| Что с `wake()` (§215) | Остаётся строго в `BG_MODE_ALWAYS` — он пара к `SCREEN_OFF → pause`, который подписан только в этом режиме. Разбужено внутренним `if`, а не режимной подпиской |
| Почему **вне** `when(mode)` | Стухший NAT от энергорежима не зависит, нудж нужен во всех режимах. Цена подписки нулевая: broadcast приходит только при включении экрана, а гейт стухлости отсекает работу |
| Дебаунс на нативной стороне | Не нужен: в ядре общий дебаунс 90 с на девайс + стале-предикат (здоровые узлы = no-op); вызов возвращается сразу (обход — в горутине ядра). Прошивочные пачки броадкастов ядру безразличны |
| Почему native, не Dart-хук `Resumed` | Работает при убитом UI-процессе (у жалобщика `AutoPowerKill`); нет IPC; `Resumed` покрывает только «открыл приложение» — включение экрана надмножество и раньше по времени |
| manifest-регистрация | Не нужна: runtime-ресивер живёт ровно от `onStartCommand` до `doStop`/`onDestroy`, а `SCREEN_ON` в manifest не доставляется с Android 8 |

### История события (v1 → v2)

v1 вешал нудж на `ACTION_USER_PRESENT` — рассуждение было «нужен момент, когда
реально пойдёт трафик». Device-прогоны 02.08 (CPH2411, 4 цикла сон→разблокировка,
verbose-логи §345) показали обратное: **ни одного `trigger=nudge`**, зато 8
срабатываний `trigger=early` — трафик стартовал раньше события и запускал
ретраи сам. Событие сдвинуто на `SCREEN_ON`; ветка `USER_PRESENT` удалена.

### Файлы

- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt` — ветка
  в `receiver.onReceive` + строка `addAction` (2 места, тот же паттерн, что
  `ACTION_RESET_NETWORK`/§087)

## Зависимость

AAR с ядром, где есть SPEC 041 v2 (`CommandServer.RebindStaleEndpoints`,
submodule `1255464` + ядро `768398e12`; ближайший lx-тег после rc.5). До бампа
`libbox` метода в биндингах нет — код не компилируется, поэтому реализация
строго после выката AAR. gomobile-имя: `rebindStaleEndpoints()` (как
`ResetNetwork` → `resetNetwork()`).

## Верификация

Юнитов нет (ветка ресивера тривиальна, паттерн §087); проверка — device:

Наблюдать core-лог обязательно с verbose (§345) — строки rebind пишутся на
debug-уровне; и **опросом раз в 1–2 с** (в verbose буфер 500 строк живёт
секунды, разовый `GET /logs/core` после факта уже пуст).

1. CPH2411, VPN с WARP-узлами, `route_idle_suspend=off` на время теста
   (иначе узел уснёт и триггер недостижим), сон ≥ 4 мин (сессия старше
   `RejectAfterTime`=180 с).
2. Включение экрана → в логе ядра строка rebind с `trigger=nudge` **раньше**
   первых `sending handshake initiation` (нудж выиграл гонку у спроса трафика).
3. Mass ping в первые секунды — зелёный.
4. Контроль no-op: включение экрана при свежих сессиях (сон < 1 мин) — строк
   rebind нет.
5. Контроль энергорежима: BG_MODE_LAZY/дефолт — нудж работает так же
   (`SCREEN_ON` подписан вне `when(mode)`); в BG_MODE_ALWAYS `wake()`
   по-прежнему вызывается (регрессия §215 недопустима).

Полевое закрытие — стенд жалобы (сон → разблокировка → пинг зелёный сразу);
это же закрывает device/field-остаток SPEC 041 v2.
