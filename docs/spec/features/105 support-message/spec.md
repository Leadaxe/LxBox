# 105 — Support message («поддержи автора», remote-managed)

| Поле | Значение |
|------|----------|
| Тип | Feature (новый сервис + диалог на старте) |
| Статус | **DONE** (входит в v2.0.0) |
| Источник | Юзер: «при открытии спустя 3 часа активного времени работы выдавало сообщение, которое бы забиралось с GH» |
| Зависит от | §036 (update check — паттерн raw-манифеста), §038 (SettingsStorage vars) |

## 1. Идея

После **3 часов суммарного времени работы туннеля** (решение юзера: метрика =
VPN реально работал, не foreground) приложение при открытии показывает диалог
«поддержи автора»: текст + кнопки-ссылки (GitHub-репы Android/Desktop/ядро,
тема 4PDA, донат). Контент **забирается с GitHub** — автор меняет текст/ссылки
без релиза приложения.

## 2. Remote-контент: `docs/support.json`

Тот же паттерн, что `docs/latest.json` (§036): файл в репо, раздаётся через
`https://raw.githubusercontent.com/Leadaxe/LxBox/main/docs/support.json`
(CDN-кэширован, anti-abuse лояльный).

```jsonc
{
  "id": "support-2026-06",        // смена id = новая «кампания»: покажется
                                   // заново даже после «Не показывать»
  "min_active_hours": 3,           // порог первого показа
  "snooze_active_hours": 10,       // «Позже» → повтор через +N часов АКТИВНОГО времени
  "title": "Привет! Я автор этого приложения",
  "message": "…текст…",            // \n-абзацы, без markdown
  "links": [                       // кнопки в порядке списка
    {"label": "⭐ LxBox (Android)", "url": "https://github.com/Leadaxe/LxBox"},
    {"label": "⭐ sing-box-lx (ядро)", "url": "https://github.com/Leadaxe/sing-box-lx"},
    {"label": "💬 Тема на 4PDA", "url": "…"},
    {"label": "💰 Поддержать деньгами", "url": "…"}
  ]
}
```

Fetch — best-effort (timeout 10s, UA как §036): успешное тело кэшируется в
SettingsStorage (`support_cache_json`) → следующий показ работает офлайн.
Нет ни сети, ни кэша → диалог не показывается (никакого bundled-фолбэка:
сообщение без актуальных ссылок бессмысленно).

## 3. Учёт активного времени — `ActiveTimeTracker`

`lib/services/active_time_tracker.dart` (singleton, persist через
`SettingsStorage` var `active_tunnel_seconds`):

- `onTunnelChanged(bool up)` — на транзишене `connected → не-connected`
  доливает `now − sessionStart` в счётчик и персистит.
- `tick()` — периодический флаш во время сессии (раз в ≥60 сек по факту
  вызова), чтобы kill процесса не терял хвост. Вызовы дешёвые: хук в
  `home_screen._onControllerChange` (он и так дёргается traffic-poll'ом
  каждые ~1с при подключении; tick сам решает, пора ли писать).
- `totalSeconds` — счётчик для решения о показе.

## 4. Решение о показе — `SupportMessageService`

`lib/services/support_message.dart`:

```
shouldShow = remote != null
  && totalActiveSeconds >= min_active_hours*3600
  && remote.id != var('support_dismissed_id')
  && totalActiveSeconds >= var('support_snooze_after_seconds', 0)
```

- **«Позже»** → `support_snooze_after_seconds = total + snooze_active_hours*3600`
  (повтор не по календарю, а по фактически наработанному времени).
- **«Не показывать»** → `support_dismissed_id = remote.id` (навсегда для этой
  кампании; новая кампания = новый id в support.json).
- Fetch — на старте (unawaited), показ — post-frame после прочих стартовых
  диалогов (`maybeShowNotificationPermissionDialog`-паттерн), не чаще
  одного раза за процесс.

## 5. UI — `maybeShowSupportDialog` (home_dialogs.dart)

`AlertDialog`: title + message (SelectableText, \n-абзацы) + колонка
кнопок-ссылок (`launchUrl`, external) + actions: «Позже» / «Не показывать».
Тап по ссылке диалог НЕ закрывает (юзер может пройтись по нескольким).

## 6. Тесты

`test/services/support_message_test.dart`:
- порог: 2ч59м → false, 3ч → true;
- dismiss по id; новая кампания (другой id) показывается;
- snooze: «Позже» при 3ч → false до 13ч, true после;
- malformed JSON → null (не падает);
- ActiveTimeTracker: транзишены/tick доливают корректно.

## 7. Решения (зафиксировано с юзером)

- Метрика = tunnel-up (не foreground).
- Повторы: «Позже» (+10ч активного) / «Не показывать» (по id кампании).
- Входит в релиз v2.0.0.
