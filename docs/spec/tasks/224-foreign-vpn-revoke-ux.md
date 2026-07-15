# 224 — Foreign-VPN revoke: честный UX вместо «taken by another app»

| Поле | Значение |
|------|----------|
| Статус | Done (закрыт в §276) |
| Дата старта | 2026-07-02 |
| Дата завершения | 2026-07-16 |
| Связанные spec'ы | [`012 native vpn service`](../features/012%20native%20vpn%20service/spec.md) |
| Связанные задачи | [002](./002-blocking-stopvpn-intent-reset.md) (blocking stopVPN), [129](./129-vpnservice-force-stop-on-stuck-core.md)/[140](./140-force-stop-port-race-and-connecting-timeout.md) (force-stop), [182](./182-notification-action-buttons.md) (native reconnect) |

## Жалоба (4PDA, dewch)

> Выгружаю все, запускаю заново, жму старт. Она говорит что tun занят другим приложением, а ведь это еще не отпустило предыдущее включение. Значок впн горит вверху. Получается она считает свое же предыдущее подключение за чужое и не дает подключить новое.

Сценарий: обновление подписки зависает → Reconnect не стартует → ручной Stop → Start → «VPN taken by another app».

## Диагноз: саморевока НЕ существует

Проверено двумя независимыми разборами механики Android Service/VpnService (high confidence). **Наш собственный Stop→Start НЕ может вызвать `onRevoke` нашего же сервиса.** Три независимых основания:

1. **Один instance на процесс.** `BoxVpnService` объявлен без `android:process` → ровно один `ServiceRecord`. `startForegroundService(ACTION_START)` поверх ещё-живого-но-останавливающегося сервиса Android доставляет как `onStartCommand` **тому же** Java-объекту (pending `stopSelf` отменяется) — второй instance НЕ создаётся. Нет второго `establish()`, которому система могла бы ревокнуть первый.

2. **fd закрывается синхронно ДО разблокировки Dart.** В `doStop` (`BoxService.kt`) `closeFileDescriptor()` выполняется в `serviceScope.launch` **перед** `withContext(Main){ setStatus(Stopped) }`. `stopVPN()`/`stopAwait` разблокируются на `setStatus(Stopped)` → к моменту нового `establish()` наш прежний tun уже не активный owner.

3. **`onRevoke` физически адресуется только когда системный VPN-слот перехватил ДРУГОЙ `VpnService`** (или юзер сменил VPN в системных настройках). Пере-establish своего же fd на том же instance система делает молча, без `onRevoke`.

### Настоящая причина у юзера

**Сторонний Always-on / kill-switch VPN (WGtunnel — упомянут юзером) перехватывает единственный системный VPN-слот в окне Stop→Start.** Android держит ОДИН VPN-слот. Во время нашего reconnect LxBox на короткое окно освобождает слот (`closeFileDescriptor`). Always-on второго VPN в это окно пере-захватывает слот → нам прилетает **настоящий** `onRevoke`. Текст «revoked by another app» **корректен по факту** — но вводит юзера в заблуждение, потому что он не понимает, что сработал ЕГО же второй VPN, и думает «приложение считает своё прошлое подключение за чужое».

`isForeignVpnActive()` (pre-check `ConnectivityManager` `TRANSPORT_VPN`) не ловит: он проверяется только на ручном UI-старте и только ПЕРЕД стартом, а перехват происходит ВНУТРИ окна reconnect.

## Что НЕ делаем и почему

- **Teardown НЕ трогаем.** Он корректен. Порядок `closeFileDescriptor` → `setStatus(Stopped)` → `stopSelf`, независимый `forceStopScope` (§140), синхронное закрытие fd — всё решает реальные проблемы (bind-already-in-use, зависшее ядро) и работает.
- **`stopCompleter` остаётся на `setStatus(Stopped)`.** Рассмотренный ранее перенос в `onDestroy` сломал бы reconnect/§129/§140: `onDestroy` НЕ гарантирован при reuse instance → `stopVPN` виснет до таймаута. `setStatus(Stopped)` — единственная детерминированная точка всех teardown-путей.
- **Авто-recovery на revoke НЕ добавляем.** После устранения путаницы любой `onRevoke` = настоящий чужой VPN; авто-переподнятие = драка за слот с легитимным сторонним VPN (пинг-понг).
- **Имя пакета-перехватчика НЕ показываем.** Android не отдаёт owner UID VPN-сети через публичный API (`getOwnerUid` = `@hide`). Показать «WGtunnel» невозможно легитимно.
- **Сужение окна через `serviceReload` (in-place reload без освобождения слота) — отдельная бóльшая задача.** Reload не переживает изменения, требующие пере-`establish` tun (MTU / routes / inet-адреса / per-app include-exclude / allow_bypass / http-proxy). Замена reconnect→reload требует различать «нужен ли пере-establish» — вне скоупа этой таски.

## Фикс: самодостаточный объясняющий текст

Единственная достижимая и безопасная правка — сделать три видимые revoke-строки самодостаточными: объяснить, что системный VPN-слот перехватило **другое активное VPN-приложение** (частая причина — Always-on / kill-switch у второго VPN), и что нужно нажать Start, чтобы вернуть туннель. Без имени приложения (Android не даёт), без ссылок на внутренние причины.

### Изменения (только строки, логика не меняется)

| Файл | Было | Стало |
|------|------|-------|
| `home_dialogs.dart` (SnackBar) | `VPN taken by another app` | `Another VPN app took over the connection. Tap Start to reconnect.` |
| `home_controller.dart` (`lastError`) | `VPN revoked by another app` | `Another VPN app took the system VPN slot (e.g. an always-on VPN). Start again to reconnect.` |
| `tunnel_status.dart` (label) | `Revoked by another VPN` | `Taken by another VPN` |

SnackBar уже имеет action «Start» → `controller.start()` — оставляем.

> **Post-mortem (§276, 16.07.2026).** Коммит `528484d` переписал только Dart-строки и
> пропустил четвёртую — нативную (`BoxService.kt`, `onRevoke`). Но главное вскрылось
> позже: **ни одна из этих строк никогда не показывалась**. `TunnelStatus.revoked` был
> недостижим — Dart ждал статус-строку `'Revoked'`, которой native не слал ни разу за всю
> историю репозитория (`VpnStatus` = 4 значения). Юзер вместо текстов §224 видел сырую
> native-строку с префиксом `Stopped: `. Контракт починен в [276](./276-revoked-status-contract.md)
> (revoke = `Stopped` + флаг `revoked`), там же дописана нативная строка — после чего
> тексты этой таски наконец заработали.

Правила проекта соблюдены: строки английские; нет §NNN в видимом тексте; самодостаточны (юзер понимает причину без знания внутренностей).

## Верификация

- `flutter analyze lib/` — clean
- Строковые тесты (если ссылаются на старый текст) — обновить
- Manual (юзер): включить второй Always-on VPN, сделать Stop→Start в LxBox → SnackBar объясняет, что слот перехватило другое VPN-приложение, а не «баг»

## Follow-up (отдельные задачи, не здесь)

- Сужение окна освобождения слота при reconnect через `serviceReload` там, где не нужен пере-`establish` tun.
- (Опц.) детект «наш собственный слот ещё активен» при старте для случая зависшего ядра (§129/§140 патология, не штатный путь).
