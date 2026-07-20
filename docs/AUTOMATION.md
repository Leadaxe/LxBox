# L×Box Automation API

Управление L×Box из **Tasker / MacroDroid / Llama / Automate** (§047 Public
Intent API) — двумя способами:

- **Plugin** (рекомендуется) — L×Box виден в списке плагинов host'а, выбираешь
  команду мышкой (Locale/Tasker-стандарт);
- **Raw broadcast intents** — `am broadcast` / Send Intent с нашей action-строкой
  (для shell / ADB / не-plugin приложений).

Фича **opt-in**: по умолчанию приём команд выключен, события наружу не шлются.
Включается в **App Settings → Automation**.

> **Два канала автоматизации — не путать.** Этот документ описывает **Public
> Intent API**: телефон автоматизирует сам себя по событиям (Tasker/MacroDroid,
> Wi-Fi-триггеры) — без ПК, без USB, без токена. Если же нужно управлять L×Box
> **снаружи скриптом** (CI, отладка, adb-forward с компьютера) — это **Debug
> API** (HTTP, Bearer-токен, порт 9269, полный CRUD подписок/правил): см.
> [api/debug-api-reference.md](api/debug-api-reference.md) и живой `GET /help`.
> Общий обзор всех каналов управления — в [индексе документации](README.md).

---

## Быстрый старт

1. **L×Box → App Settings → Automation** → включить «Принимать команды
   автоматизации» (подтвердить explainer). Пока этот toggle OFF, receiver'ы
   `enabled=false` — команды не принимаются вообще. Это и есть барьер приёма
   (отдельного per-app пропуска нет — см. §157).
2. Включить нужные **Emit**-категории, если хотите получать события L×Box
   наружу (Lifecycle / State / Subscription / Health).
3. В host-приложении выбрать L×Box:
   - **Plugin** (проще): Action / State → **Plugin → L×Box** → выбрать команду;
   - **Raw**: **Send Intent** → Action = одна из команд ниже, Target =
     **Broadcast Receiver**.

---

## Два способа интеграции

L×Box поддерживает **оба** механизма — выбирайте по удобству:

| | Plugin (рекомендуется) | Raw broadcast intents |
|---|---|---|
| Как | Host → **Action / State → Plugin → L×Box** | руками Send Intent + строка action |
| Кому | большинству — кликаешь в списке плагинов | shell `am broadcast`, ADB, не-plugin apps |
| Настройка | выбор из списка + селектор ноды/группы | вписать action и extras вручную |

Оба требуют включённого мастер-toggle в **App Settings → Automation**. Plugin-способ описан сразу ниже; raw-actions — в таблицах далее.

### Хосты

Plugin-стандарт (`twofortyfouram` Locale) понимают:

| Хост | Цена | Plugin-блок |
|---|---|---|
| **MacroDroid** | бесплатно | ✅ доступен (проверено) |
| **Tasker** | ~€3.5 разово | ✅ |
| **Llama** | бесплатно | ✅ |
| **Automate** (LlamaLab) | бесплатно | ⚠️ plugin-блок за premium; raw-actions через «Broadcast send» бесплатны |

Raw-actions (Шаг 1) работают **откуда угодно** — Termux / shell / ADB через `am broadcast`, без host-приложения.

### Plugin — действия (Setting)

В списке плагинов host'а L×Box даёт **4 строки**:

| Строка плагина | Что делает |
|---|---|
| **L×Box: Start VPN** | one-tap — выбрал, готово, без экрана |
| **L×Box: Stop VPN** | one-tap |
| **L×Box: Toggle VPN** | one-tap |
| **L×Box: Custom…** | открывает экран выбора остальных команд |

«Custom…» — список команд (Switch node · Set group · URL-test group · Refresh
subscriptions · Rebuild config · Reset network). Для **Switch node** показывается
**выпадающий список реальных нод** активной группы; для **Set group** /
**URL-test group** — список реальных групп (подтягиваются из приложения — нужно
один раз открыть L×Box после установки/смены подписки, чтобы список закешировался;
иначе — ручной ввод тега).

Пример (MacroDroid): Action → **Плагин Tasker/Locale** → **L×Box: Custom…** →
выбрать «Switch node» → в Value выбрать ноду из списка → **Save**.

### Plugin — условия (State)

Host → State / Condition → Plugin → **L×Box** → выбрать проверку:

| Условие | Значение |
|---|---|
| **VPN is up** | — |
| **Active node =** | выбрать ноду |
| **Active group =** | выбрать группу |

Profile активируется, пока условие истинно. Host опрашивает периодически.

> **Как узнать текущую активную ноду.** Событий-«ответов» ждать не обязательно:
> условие **Active node =** — это pull-проверка активной ноды прямо сейчас
> (читает кеш, который L×Box обновляет при каждой смене). Ставите его в State
> сценария и сравниваете с нужным тегом — истинно, пока эта нода активна. То же
> для **Active group =**. Событие `ACTIVE_NODE_CHANGED` (ниже) — это push «нода
> сменилась», а condition — pull «какая нода сейчас»; выбирайте по задаче.

> Под капотом plugin использует стандарт
> `com.twofortyfouram.locale.intent.action.FIRE_SETTING` / `QUERY_CONDITION` и
> те же команды, что raw-actions ниже. UI плагина — на английском.

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
| `VPN_ERROR` | `code`, `message` | Lifecycle | Любой error path / провал automation-команды. `code` = `tunnel_error` (аварийный обрыв туннеля) либо `conflict`/`bad_request`/`not_found`/… (провал команды) |
| `VPN_REVOKED` | — | Lifecycle | Другая VPN-app перехватила туннель |
| `UPDATE_AVAILABLE` | `version`, `url` | Lifecycle | Найдена новая версия |
| `ACTIVE_NODE_CHANGED` | `old_tag`, `new_tag`, `group`, `reason` | State | Сменилась активная нода |
| `NODE_ALREADY_ACTIVE` | `tag`, `group` | State | `SWITCH_NODE` пришёл на уже активную ноду — нода **не** менялась (подтверждение вместо смены) |
| `ACTIVE_GROUP_CHANGED` | `old_group`, `new_group`, `reason` | State | Сменилась активная группа |
| `SUB_REFRESHED` | `sub_id`, `nodes_count`, `delta_count` | Subscription | Подписка обновилась |
| `SUB_REFRESH_FAILED` | `sub_id`, `error` | Subscription | Подписка не обновилась (throttle 1/min на sub_id) |

### Зарезервированные (namespace есть, источника пока нет)

- `HEARTBEAT_FAILED` · `LATENCY_DEGRADED` · `UNATTRIBUTED_BURST` (категория
  **Health**) — появятся вместе с §042 health watchdog. Категория в UI уже есть.
- `PERMISSION_NEEDED` (`permission`, категория **Lifecycle**) — зарезервировано
  под runtime-permission промпты; источника эмиссии пока нет.

---

## Symmetric request-response

Главная сила outgoing-событий — Tasker может **wait'ать** на ответ:

```
Task "Switch to Russia with confirmation":
  1. Send Intent: SWITCH_NODE extra tag="🇷🇺Россия"
  2. Wait Event: ACTIVE_NODE_CHANGED (new_tag ~ "🇷🇺.*")
       OR  NODE_ALREADY_ACTIVE (tag ~ "🇷🇺.*")
       OR  VPN_ERROR                                        (timeout 10s)
  3. If ACTIVE_NODE_CHANGED  → Vibrate + Notify "✅ переключено"
     If NODE_ALREADY_ACTIVE  → Notify "✅ уже на этой ноде"
     If VPN_ERROR            → Notify "❌ %code: %message"
     If timeout              → Notify "⚠️ нет ответа"
```

При провале команды (нет группы, tunnel down, несуществующая нода/группа и т.п.)
L×Box эмитит `VPN_ERROR` с `code` (`conflict` / `bad_request` / `not_found` / …)
и `message` — ждущий Tasker узнаёт о провале вместо тихого fire-and-forget.

> **Важно: для request-response включите обе категории — `Lifecycle` и
> `State`.** Успех переключения приходит в категории **State**
> (`ACTIVE_NODE_CHANGED` / `NODE_ALREADY_ACTIVE`), а провал — как `VPN_ERROR` в
> категории **Lifecycle**. Если включить только State, ждущий сценарий не
> получит `VPN_ERROR` на ошибке и уйдёт в timeout вместо ветки ошибки.
> (App Settings → Automation → Outbound events.)

**`SWITCH_NODE` на уже активную ноду** не рвёт соединения и не делает re-select
(это была бы лишняя нагрузка), но всё равно шлёт `NODE_ALREADY_ACTIVE` —
поэтому wait-сценарий получает детерминированный ответ, а не уходит в timeout.
Если ждать только `ACTIVE_NODE_CHANGED`, повторная команда той же ноды повиснет
до таймаута — добавляйте `NODE_ALREADY_ACTIVE` в Wait Event.

---

## Безопасность

- **Default OFF.** Без мастер-toggle receiver disabled — никакая app не может
  слать команды. **Это единственный барьер приёма.** Когда toggle ON, команды
  принимаются от любого приложения на устройстве.
- **Per-app пропуска нет** (§157). Прежняя галка «Требовать пропуск» удалена:
  `checkCallingPermission` в broadcast-`onReceive` недетерминирован (broadcast
  не несёт caller-identity), поэтому никакой реальной защиты не давал. Если
  нужна модель «только доверенным приложениям» — это отдельная задача
  (shared-secret токен / UID-allowlist на Android 14+).
- **События не содержат секретов** подписок / config — только лейблы (теги,
  имена групп, статус); outgoing-broadcast открыт всем подписчикам.
- **Логи.** В App Settings → Diagnostics → log filter `automation` видны строки
  `[automation] action <name> → ok / ERROR …` (обработанные команды) и
  `[automation] emit <event> …` (исходящие события). Сам факт приёма broadcast'а
  (включая прямые `START_VPN` / `STOP_VPN` / `TOGGLE_VPN`, которые вообще не доходят
  до Dart) пишется только в logcat под тегом `LxBoxIntent`:
  `adb logcat -s LxBoxIntent`.

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
| Тоже, но toggle ON | Неверный action / target не Broadcast Receiver / опечатка в `com.leadaxe.lxbox.…` | Сверить со списком команд; факт приёма — в logcat `adb logcat -s LxBoxIntent` (строка `received <action>`); результат команд — log filter `automation` |
| **Событие не приходит** (напр. `ACTIVE_NODE_CHANGED` не ловится) | **Категория события OFF** — проверять первым | Включить нужную категорию (для `ACTIVE_NODE_CHANGED` / `NODE_ALREADY_ACTIVE` — **State**) в App Settings → Automation → Outbound events. Пока категория выключена, событие не эмитится вовсе |
| Событие приходит, но переменные (`%new_tag` и пр.) пустые | Экстры не объявлены в Tasker | В `Event → System → Intent Received` вручную добавить имена переменных-экстр (см. ниже) — Tasker не подхватывает их автоматически |
| `SWITCH_NODE` не выбирает ноду | tag не существует / typo | Проверить log filter `automation` |
| В плагине «Custom…» вместо списка нод/групп — поле ввода | Кеш пуст (L×Box не открывался после установки/смены подписки) | Открыть L×Box, зайти в группу (список закешируется), переоткрыть плагин |
| L×Box не виден в списке плагинов host'а | Host без plugin-блока (напр. бесплатный Automate) | Использовать MacroDroid (бесплатно) или raw `am broadcast` |
| `START_VPN` не работает первый раз | VPN consent не давали | Один раз нажать Connect в app |
| На MIUI / ColorOS receiver мёртв | OEM auto-start restriction | Добавить L×Box в «Автозапуск» системных настроек |

> **Объявление экстр в Tasker.** Событие несёт данные в intent-экстрах, но
> Tasker не создаёт из них переменные сам — имена нужно прописать вручную в
> `Event → System → Intent Received` (фильтр action — полное имя события, напр.
> `com.leadaxe.lxbox.event.ACTIVE_NODE_CHANGED`), после чего они доступны как
> `%new_tag` и т.д. Ключи по событиям:
> - `ACTIVE_NODE_CHANGED` — `old_tag`, `new_tag`, `group`, `reason`;
> - `NODE_ALREADY_ACTIVE` — `tag`, `group`;
> - `ACTIVE_GROUP_CHANGED` — `old_group`, `new_group`, `reason`.
>
> `old_tag` пуст на **первом** переключении после старта приложения (предыдущей
> ноды ещё нет — экстра не кладётся); `new_tag` / `group` / `reason` заполнены
> всегда. Это норма, не баг.

---

## Ссылки

- [§047 — Public Intent API spec](spec/features/047%20public%20intent%20api/spec.md)
- [Android BroadcastReceiver guide](https://developer.android.com/develop/background-work/background-tasks/broadcasts)
- [Tasker — Send Intent](https://tasker.joaoapps.com/userguide/en/help/ah_send_intent.html)
- [Locale plugin API (twofortyfouram)](https://github.com/twofortyfouram/android-plugin-api-for-locale) — стандарт plugin-способа (FIRE_SETTING / QUERY_CONDITION)
