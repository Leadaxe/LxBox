# L×Box Automation API

Управление L×Box из **Tasker / Macrodroid / Llama / Automate** и shell-скриптов
(`am broadcast`) через Android **broadcast intents** (§047 Public Intent API).

Фича **opt-in**: по умолчанию приём команд выключен, события наружу не шлются.
Включается в **App Settings → Automation**.

---

## Быстрый старт

1. **L×Box → App Settings → Automation** → включить «Принимать команды
   автоматизации» (подтвердить explainer).
2. (Опционально, рекомендуется) включить «Требовать пропуск» — тогда команды
   принимаются только от приложений с пропуском
   `com.leadaxe.lxbox.permission.AUTOMATION`. Строка пропуска показывается с
   кнопкой копирования.
3. Включить нужные **Emit**-категории, если хотите получать события L×Box
   наружу (Lifecycle / State / Subscription / Health).
4. В Tasker: **Send Intent** → Action = одна из команд ниже, Target =
   **Broadcast Receiver**.

---

## Incoming actions (команды → L×Box)

Все — broadcast intents. Префикс `com.leadaxe.lxbox.`.

| Action | Extra | Эффект |
|---|---|---|
| `START_VPN` | — | Запустить VPN (идемпотентно: noop если уже up) |
| `STOP_VPN` | — | Остановить VPN |
| `TOGGLE_VPN` | — | Toggle относительно текущего статуса |
| `SWITCH_NODE` | `tag` (String) | Переключить активную ноду в текущей группе |
| `SET_GROUP` | `group` (String) | Сменить активную группу |
| `REBUILD_CONFIG` | — | Пересобрать config из подписок (respects §037 lock) |
| `REFRESH_SUBS` | `force` (Bool) | Обновить подписки |
| `RESET_NETWORK` | — | closeAll + DNS flush + dialer rebind (нужен tunnel up) |
| `URLTEST_GROUP` | `group` (String) | Форсировать URLTest группы (нужен tunnel up) |

> **`START_VPN` первый раз** требует системного VPN-consent — его можно дать
> только из UI. Нажмите Connect в приложении один раз; дальше automation
> работает без диалога.

---

## Outgoing events (L×Box → наружу)

Префикс `com.leadaxe.lxbox.event.`. Эмитятся только если включена
соответствующая категория в Emit-настройках.

| Event | Extras | Категория | Когда |
|---|---|---|---|
| `VPN_CONNECTED` | — | Lifecycle | Туннель поднят |
| `VPN_DISCONNECTED` | `reason` (`user`/`error`/`revoked`) | Lifecycle | Туннель упал |
| `VPN_ERROR` | `code`, `message` | Lifecycle | Любой error path / провал automation-команды |
| `VPN_REVOKED` | — | Lifecycle | Другая VPN-app перехватила туннель |
| `UPDATE_AVAILABLE` | `version`, `url` | Lifecycle | Найдена новая версия |
| `PERMISSION_NEEDED` | `permission` | Lifecycle | Требуется runtime-permission (резерв) |
| `ACTIVE_NODE_CHANGED` | `old_tag`, `new_tag`, `group`, `reason` | State | Сменилась активная нода |
| `ACTIVE_GROUP_CHANGED` | `old_group`, `new_group`, `reason` | State | Сменилась активная группа |
| `SUB_REFRESHED` | `sub_id`, `nodes_count`, `delta_count` | Subscription | Подписка обновилась |
| `SUB_REFRESH_FAILED` | `sub_id`, `error` | Subscription | Подписка не обновилась (throttle 1/min на sub_id) |

### Future (с §042 health watchdog)

`HEARTBEAT_FAILED` · `LATENCY_DEGRADED` · `UNATTRIBUTED_BURST` — namespace
зарезервирован, источники появятся вместе с §042. Категория **Health** в UI
уже есть.

---

## Symmetric request-response

Главная сила outgoing-событий — Tasker может **wait'ать** на ответ:

```
Task "Switch to Russia with confirmation":
  1. Send Intent: SWITCH_NODE extra tag="🇷🇺Россия"
  2. Wait Event: ACTIVE_NODE_CHANGED (new_tag ~ "🇷🇺.*")  OR  VPN_ERROR   (timeout 10s)
  3. If ACTIVE_NODE_CHANGED → Vibrate + Notify "✅"
     If VPN_ERROR          → Notify "❌ %code: %message"
     If timeout            → Notify "⚠️ нет ответа"
```

При провале команды (нет группы, tunnel down и т.п.) L×Box эмитит `VPN_ERROR`
с `code` (`conflict` / `bad_request` / …) и `message` — ждущий Tasker узнаёт
о провале вместо тихого fire-and-forget.

---

## Безопасность

- **Default OFF.** Без мастер-toggle receiver disabled — никакая app не может
  слать команды.
- **«Требовать пропуск».** При ON — команды и события только от/к приложениям
  с granted `com.leadaxe.lxbox.permission.AUTOMATION` (`protectionLevel
  normal`: барьер «знать имя + declare», не криптозащита).
- **События не содержат секретов** подписок / config — только лейблы (теги,
  имена групп, статус).
- **Логи.** Весь обмен виден в App Settings → Diagnostics → log filter
  `automation` (`[automation] received …` / `[automation] emit …`).

---

## Рецепты Tasker

### 1. Auto-disable VPN на домашнем Wi-Fi
- Profile: Wi-Fi connected = `MyHomeWiFi`
- Task: Send Intent `com.leadaxe.lxbox.STOP_VPN` (Broadcast)

### 2. Auto-enable на любом другом Wi-Fi
- Profile: Wi-Fi connected = NOT `MyHomeWiFi`
- Task: Send Intent `com.leadaxe.lxbox.START_VPN`

### 3. Switch на Russia-node при запуске банка (с подтверждением)
- Profile: App launched = `ru.bank.app`
- Task:
  1. Send Intent `SWITCH_NODE` extra `tag=🇷🇺Россия`
  2. Wait Event `ACTIVE_NODE_CHANGED` (new_tag ~ `🇷🇺.*`) OR `VPN_ERROR`, timeout 10s
  3. If matched → Vibrate(50); else → Notify error

### 4. Уведомление при падении подписки
- Profile: Event Received `com.leadaxe.lxbox.event.SUB_REFRESH_FAILED`
- Task: Notify «📡 Sub %sub_id failed: %error»

### 5. Periodic mass-ping каждые 30 минут
- Profile: Time = every 30 min
- Task: Send Intent `URLTEST_GROUP` extra `group=vpn-1`

### 6. Auto reset-network при высоком ping
- Profile: Variable `%CURR_PING > 1000` (set externally)
- Task: Send Intent `RESET_NETWORK`

### 7. Notification на часы при падении VPN
- Profile: Event Received `com.leadaxe.lxbox.event.VPN_ERROR`
- Task: Notify Wear «❌ VPN: %code — %message»

---

## Troubleshooting

| Симптом | Причина | Решение |
|---|---|---|
| Команда не доходит | Мастер-toggle OFF | Включить в App Settings → Automation |
| Тоже, но toggle ON | «Требовать пропуск» ON, а Tasker не declare'ил permission | Выключить галку **или** добавить `com.leadaxe.lxbox.permission.AUTOMATION` в permissions Tasker |
| `SWITCH_NODE` не выбирает ноду | tag не существует / typo | Проверить log filter `automation` |
| `START_VPN` не работает первый раз | VPN consent не давали | Один раз нажать Connect в app |
| На MIUI / ColorOS receiver мёртв | OEM auto-start restriction | Добавить L×Box в «Автозапуск» системных настроек |

---

## Ссылки

- [§047 — Public Intent API spec](spec/features/047%20public%20intent%20api/spec.md)
- [Android BroadcastReceiver guide](https://developer.android.com/develop/background-work/background-tasks/broadcasts)
- [Tasker — Send Intent](https://tasker.joaoapps.com/userguide/en/help/ah_send_intent.html)
