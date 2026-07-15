# 276 — Revoked: починить контракт статуса native↔Dart

| Поле | Значение |
|------|----------|
| Статус | Done — device-verified (CPH2411, `2.15.7-dev.2`, 16.07.2026) |
| Дата старта | 2026-07-16 |
| Дата завершения | 2026-07-16 |
| Связанные spec'ы | [`012 native vpn service`](../features/012%20native%20vpn%20service/spec.md), [`003 home screen`](../features/003%20home%20screen/spec.md) |
| Связанные задачи | [003](./003-revoke-ux.md) (revoke UX), [224](./224-foreign-vpn-revoke-ux.md) (честный текст, In progress), [241](./241-foreign-vpn-settings-button.md) (VPN settings), [211](./211-foreign-vpn-switch-dialog.md) (pre-check), [140](./140-force-stop-port-race-and-connecting-timeout.md) (stopCompleter) |

## Проблема

Жалоба (Telegram, 15.07.2026): Samsung J4, Android 10, 3 ГБ RAM — VPN раз в 5-10 минут
отваливается, в UI плашка **`Stopped: VPN revoked by another app`**. На планшете и
телефоне того же юзера при тех же конфигах — стабильно.

Разбор жалобы вскрыл **рассинхрон контракта статусов между Kotlin и Dart**.

### Ветка `TunnelStatus.revoked` мертва с первого коммита

| Слой | Факт |
|------|------|
| [`VpnStatus.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnStatus.kt) | enum = `Stopped/Starting/Started/Stopping`. Значения `Revoked` **нет** |
| [`BoxService.kt:273`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt) | `onRevoke` шлёт `setStatus(VpnStatus.Stopped, error = "VPN revoked by another app")` |
| [`VpnPlugin.kt:129-147`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt) | `statusReceiver` перекладывает имя дословно → `{"status": "Stopped", "error": "..."}` |
| [`tunnel_status.dart:20-29`](../../../app/lib/models/tunnel_status.dart) | `fromNative` ждёт raw `'Revoked'` → `revoked`. Native такого **не шлёт никогда** |
| [`home_controller.dart:331-333`](../../../app/lib/controllers/home_controller.dart) | `tunnel != revoked` → ветка else → `'Stopped: ${errorReason}'` = **текст со скриншота** |

Проверено археологией: `git log -S "Revoked" -- app/android/` — **пусто за всю историю
репозитория**. Ожидание `'Revoked'` в Dart есть с первого коммита `b5cfa4e`. Контракт
разошёлся в день рождения проекта, это не регресс.

### Последствия

1. **Весь revoke-UX — мёртвый код.** SnackBar с кнопкой Start (§003), честный текст §224,
   подсказка «VPN settings» (§241) не срабатывали ни на одном устройстве ни разу.
2. **Юзер видит сырую внутреннюю строку** с префиксом `Stopped: ` — читается как баг
   приложения. Отсюда «непонятное.. при одинаковых конфигах».
3. **Статус-чип врёт**: revoke маппится в `disconnected` → «Disconnected», как будто юзер
   сам нажал Stop.
4. **Тест кодирует ложный контракт**: [`home_last_start_error_test.dart:52`](../../../app/test/controllers/home_last_start_error_test.dart)
   сам фабрикует `'Revoked'` → зелёный поверх сломанного моста.
5. **Спека 012 противоречит себе**: стр. 51 объявляет `"Revoked"` в EventChannel-контракте,
   стр. 125 описывает отправку `Stopped`.

### Почему не заметили на dev-устройстве

§003 закрыт со статусом «Done / **pending manual verification**» — ручной тест с двумя VPN
не делался. В кейсе с v2rayNG на CPH2411 (§241) диагностировали через `dumpsys`, на текст
плашки не смотрели — а там была та же сырая строка.

## Диагноз жалобы J4 (отдельно от этой таски)

Строку может породить **только** реальный системный `VpnService.onRevoke()` — его Android
адресует лишь при захвате единственного VPN-слота **другим** `VpnService`. LMK-смерть даёт
`SIGKILL`: Java-код не исполняется, broadcast не уходит, `START_NOT_STICKY` не рестартит →
юзер увидел бы молча пропавший туннель **без** этой строки. Саморевок исключён (§224: один
`ServiceRecord` без `android:process`, fd закрывается синхронно до разблокировки Dart).

**Эта таска жалобу НЕ чинит** — причина внешняя (кандидаты: второй VPN с Always-on;
Samsung Secure Wi-Fi `com.samsung.android.fast` — встроенный VpnService с автовключением на
Wi-Fi, которого нет на других устройствах юзера). Таска делает причину **видимой юзеру**,
чтобы он нашёл перехватчика сам.

## Дизайн: `Revoked` — метка поверх `Stopped`, НЕ пятая фаза

Наивное «добавить `Revoked` в enum и слать его из `onRevoke`» **сломает teardown**. Разведка
поверхности (`grep VpnStatus\.` по Kotlin) — ~10 мест сравнивают `== VpnStatus.Stopped`:

| Точка | Что сломается при наивном `setStatus(Revoked)` |
|-------|------------------------------------------------|
| [`BoxService.kt:565`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt) `completeStopIfWaiting()` | **Критично.** `stopCompleter` висит на `Stopped` → `stopVPN()`/`stopAwait` не разблокируется → виснет до таймаута, ломает reconnect (§182) и force-stop (§129/§140) |
| `BoxService.kt:194` `onStartCommand` guard | `status != Stopped` → **старт после revoke молча игнорируется** |
| `BoxService.kt:439/489` `doStop` guard | повторный stop не отсекается |
| `BoxVpnService.kt:85` `setCurrentStatus` | `tunnelStartedElapsedMs` не обнулится → врёт uptime (§187) |
| `VpnPlugin.kt:1097` `isForeignVpnActive` | `currentStatus != Stopped` → вернёт false → pre-check §211 сломан |
| `LxBoxTileService.kt:74/146`, `QuickShortcuts.kt:48` | `when` без ветки → плитка/шорткаты не отрисуют состояние |

§224 прямо предупреждает: `setStatus(Stopped)` — **единственная детерминированная точка всех
teardown-путей**, `stopCompleter` переносить нельзя.

**Решение:** revoke остаётся `VpnStatus.Stopped` (весь lifecycle/teardown не меняется), а
факт перехвата едет **отдельным булевым extra** в том же broadcast. Dart собирает `revoked`
из пары `(status=Stopped, revoked=true)`.

Почему не string-sniffing по тексту ошибки: §224 эту строку как раз переписывает — матчить
по ней = поставить UI в зависимость от формулировки. Булев флаг явный и переживает правки
текста.

### Native

1. **`BoxService.kt`** — поле `private var revokedFlag = false`; `setStatus` принимает
   `revoked: Boolean = false` и кладёт `putExtra(EXTRA_REVOKED, true)` только когда флаг
   стоит. `onRevoke` → `setStatus(VpnStatus.Stopped, error = <текст §224>, revoked = true)`.
   Сбрасывать флаг в `onStartCommand` (новый старт = состояние больше не revoked).
2. **`BoxVpnService.kt`** — companion `@Volatile var currentRevoked: Boolean`, обновляется
   рядом с `setCurrentStatus`; сброс в `false` на `Starting`/`Started` и в `onDestroy`.
3. **`VpnPlugin.kt`** — `statusReceiver` прокидывает `revoked` в event-map;
   `getVpnStatus` возвращает не голую строку, а map `{"status": ..., "revoked": ...}` —
   иначе pull на resume теряет факт revoke (кейс §003 «намеренно не покрыто»).

`VpnStatus` enum **не трогаем** — ни одна из ~10 точек сравнения не меняется.

### Dart

4. **`tunnel_status.dart`** — `TunnelStatusEvent.fromNative`: если `status == 'Stopped'` и
   `raw['revoked'] == true` → `TunnelStatus.revoked`. Мёртвую ветку `'Revoked' => revoked`
   в `fromNative` убрать (native такой строки не шлёт).
5. **`box_vpn_client.dart:157`** `getVpnStatus` — разобрать map вместо строки.
6. **`home_controller.dart:331`** — ветка `revoked` уже готова (текст §224), заработает сама.

### Хвост §224 (закрывает спеку)

7. **`BoxService.kt:273`** — единственная не переписанная строка §224:
   `"VPN revoked by another app"` → `"Another VPN app took the system VPN slot (e.g. an
   always-on VPN). Start again to reconnect."` (совпадает с Dart-текстом; после фикса
   контракта Dart её перекроет, но native-строка не должна оставаться сырой — она уходит в
   `lastStartError`/Debug API §250).

### Доки и тесты

8. **`features/012`** стр. 51 + 125 — привести контракт к реальности: статусы = 4 значения,
   `revoked` — булев extra рядом с `error`.
9. **`tasks/224`** — статус → Done.
10. **`home_last_start_error_test.dart:52`** — убрать фабрикацию `'Revoked'`, эмитить
    `(Stopped, revoked: true)`.
11. **Новый тест** (`test/vpn/`): `(Stopped, revoked=true)` → `TunnelStatus.revoked` +
    текст §224; `(Stopped, revoked=false)` → `disconnected`; `getVpnStatus`-pull сохраняет
    revoked.

## Что НЕ делаем

- **Teardown не трогаем** (§224) — `stopCompleter` остаётся на `setStatus(Stopped)`.
- **Авто-recovery на revoke не добавляем** (§224) — драка за слот с легитимным чужим VPN.
- **Имя перехватчика в UI не показываем** (§241) — `getOwnerUid` = `@hide`; юзеру даём
  системный VPN-экран.
- **`VpnStatus` enum не расширяем** — см. таблицу поломок выше.

## Верификация

- `flutter analyze` (весь проект, не только `lib/`) — clean
- `flutter test` — 1768+ зелёных, включая новые
- **Device (CPH2411, там уже стоит v2rayNG):** поднять LxBox VPN → включить VPN в v2rayNG →
  ожидание: плашка `lastError` с текстом §224 **без** префикса `Stopped: ` + SnackBar
  «Another VPN app took over the connection» с кнопкой Start.
  **Первая в истории проекта живая проверка revoke-UX.**

  Чип при этом показывает **«Disconnected»** — это НЕ баг: §003 намеренно маппит revoked в
  нейтральный off-state (`status_chip.dart:35`), чтобы не пугать красной пилюлей; факт
  перехвата несут плашка и SnackBar. `TunnelStatus.revoked.label` («Taken by another VPN»)
  до чипа не доезжает — он используется в других местах.

  **Результат (16.07.2026, `2.15.7-dev.2`):** плашка показывает текст §224 — контракт
  починен, ветка `revoked` достижима впервые. Чип «Disconnected» — как задумано выше.
- Регресс teardown: Stop→Start, Reconnect из шторки (§182), force-stop (§129/§140) — не
  виснут (проверяем, что `stopCompleter` цел).

## Follow-up

- `docs/DIAGNOSTICS.md` — рецепт поиска перехватчика слота: `dumpsys vpn_management`
  (Active package + VpnTransportInfo) и `dumpsys usagestats` (FOREGROUND_SERVICE_START).
  Сейчас живёт только в памяти сессий (кейс CPH2411/v2rayNG).
- Сужение окна освобождения слота при reconnect через `serviceReload` (из §224).
