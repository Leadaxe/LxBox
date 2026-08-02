# §340 — Wake-нудж: `USER_PRESENT` → `rebindStaleEndpoints()` (потребитель SPEC 041 v2)

| | |
|---|---|
| Статус | Реализовано (AAR `v1.14.0-lx.19-rc.1`, сборка зелёная) — ждёт device-верификации на CPH2411 |
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
Intent.ACTION_USER_PRESENT -> {
    // §340 — wake-нудж SPEC 041 v2: разблокировка = «устройство проснулось»;
    // ядро само ребиндит только доказуемо стухшие WG/AWG-сессии
    // (стале-предикат + общий дебаунс 90 с — в ядре, вызов неблокирующий).
    Log.d(TAG, "[vpn] USER_PRESENT → rebindStaleEndpoints")
    runCatching { commandServer.get()?.rebindStaleEndpoints() }
        .onFailure { Log.e(TAG, "rebindStaleEndpoints failed", it) }
}
```

и регистрация в `IntentFilter` в `onStartCommand`:

```kotlin
addAction(Intent.ACTION_USER_PRESENT)   // §340 — вне when(mode), см. ниже
```

### Решения по месту

| вопрос | решение |
|---|---|
| Почему `USER_PRESENT`, не `SCREEN_ON` | Нудж нужен после снятия keyguard, когда реально пойдёт трафик; `SCREEN_ON` стреляет и на AOD/уведомлениях без разблокировки. Порядок при unlock: `SCREEN_ON` (в BG_MODE_ALWAYS будит паузу ядра §215) → `USER_PRESENT` (нудж) — wake успевает раньше нуджа сам собой |
| Почему **вне** `when(mode)` | `SCREEN_ON/OFF` гейтятся `BG_MODE_ALWAYS`, потому что обслуживают паузу ядра (энергорежим). Нудж — не энергорежим: стухший NAT одинаков во всех фоновых режимах, а цена подписки — ноль (broadcast только в момент разблокировки). Регистрируем всегда, пока сервис жив |
| Дебаунс на нативной стороне | Не нужен: в ядре общий дебаунс 90 с на девайс + стале-предикат (здоровые узлы = no-op); вызов возвращается сразу (обход — в горутине ядра). Прошивочные пачки броадкастов ядру безразличны |
| Почему native, не Dart-хук `Resumed` | Работает при убитом UI-процессе (у жалобщика `AutoPowerKill`); нет IPC; `Resumed` покрывает только сценарий «открыл приложение», разблокировка — надмножество. Dart-хук не добавляем — избыточен |
| manifest-регистрация | Невозможна и не нужна: `USER_PRESENT` в manifest зарезан с API 26; runtime-ресивер и так живёт ровно от `onStartCommand` до `doStop`/`onDestroy` |

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

1. CPH2411, VPN с WARP-узлами, сон ≥ 3 мин (сессии протухают по предикату).
2. Разблокировка → в `adb logcat`: `USER_PRESENT → rebindStaleEndpoints`,
   в логе ядра — строка rebind с триггером `nudge`.
3. Mass ping в первые секунды после разблокировки — зелёный (до таски: err
   до ~15 с у v2-ядра, до ~90 с у v1).
4. Контроль no-op: разблокировка при свежих сессиях (сон < 1 мин) — строк
   rebind в логе ядра нет.
5. Контроль энергорежима: BG_MODE_LAZY/дефолт — нудж работает так же
   (регистрация вне `when(mode)`).

Полевое закрытие — стенд жалобы (сон → разблокировка → пинг зелёный сразу);
это же закрывает device/field-остаток SPEC 041 v2.
