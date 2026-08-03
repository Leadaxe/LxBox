# §356 — Support-лента: очередь сообщений, i18n, версионный повторный показ, нативный учёт наработки

**Тип:** таска (rework §105)
**Статус:** реализовано 03.08.2026 (юниты; device-verify pending)
**Связано:** §105 (support-message v1 — заменяется этой таской), §036 (паттерн raw-манифеста), §187 (`getTunnelUptimeMs` — нативный аптайм туннеля), §279/§285 (l10n, `effectiveTag`)

---

## 1. Проблемы v1 (§105)

1. **Один язык.** `title`/`message`/`links[].label` в `support.json` — плоские
   русские строки; англоязычный юзер получает кириллицу.
2. **«Не показывать» вечное.** `dismissed_id` гасит кампанию навсегда; смена
   версии приложения на это не влияет. Хотелось: прочитал на версии X →
   после обновления можно показать снова (управляемо автором).
3. **Одна кампания.** Файл описывает единственное сообщение; лента
   (последовательный сторителлинг) невозможна.
4. **Счётчик наработки слеп к смахнутому UI.** `active_seconds` копится только
   пока жив Flutter-процесс; типичный паттерн «включил VPN и смахнул» даёт
   малую долю реальной наработки → пороги в часах реально означают недели.

Обратная совместимость формата НЕ держится (решение юзера): старые версии
не распарсят новый файл (нет верхнеуровневого `id`) → фолбэк на их локальный
кэш → доживают на старой кампании.

## 2. Формат `docs/support.json` (v2)

```jsonc
{
  "snooze_active_hours": 10,       // «Later» — общий для всей ленты
  "messages": [                     // порядок массива = очередь показа
    {
      "id": "01-thanks-star",       // постоянный ключ; по нему хранится «прочитано»
      "since_version": "2.0.0",     // с какой версии приложения сообщение существует
      "skip": false,                // true = вывести из ротации для всех (опц.)
      "min_active_hours": 3,        // наработка туннеля ОТ BASELINE до показа
      "min_session_minutes": 5,     // текущая сессия VPN не короче N минут
      "i18n": {                     // en обязателен (фолбэк); прочие опциональны
        "en": { "title": "…", "message": "…", "links": [{ "label": "…", "url": "…" }] },
        "ru": { "title": "…", "message": "…", "links": [ … ] }
      }
    }
  ]
}
```

- `since_version` — двойная роль: (а) таргетинг «версии старше не видят»;
  (б) повторный показ: бамп выше версии, записанной при «Прочитал», делает
  сообщение непрочитанным для обновившихся (и только для них).
- Сообщение без валидного `en`-блока отбрасывается парсером целиком.
- Ссылки — свои у каждой локали (en может вести на README.md, ru — на README_RU.md).
- Языковой блок выбирается **в момент показа** (`LocaleController.I.effectiveTag`),
  не при fetch — кэш один на все языки, смена языка в приложении не протухает.
- `docs/support.test.json` (develop) — тот же формат, для проверки кампании до
  публикации (`--dart-define=LXBOX_SUPPORT_URL=…`).

## 3. Состояние клиента (`support_state.json`)

| Ключ | Семантика |
|---|---|
| `active_seconds` | суммарная наработка туннеля (сек) — как в v1 |
| `session_credited` | **new** — сколько секунд ТЕКУЩЕЙ сессии туннеля уже зачислено в `active_seconds` (нативный учёт, §5) |
| `read` | **new** — `{id → версия приложения в момент «Прочитал»}` |
| `baseline_seconds` | **new** — точка отсчёта для `min_active_hours` |
| `baseline_version` | **new** — версия приложения, на которой baseline ставился |
| `snooze_after_seconds` | порог «Later» — как в v1 |
| `cache_json` | офлайн-кэш файла — как в v1 |
| `dismissed_id` | v1, мёртвый — игнорируется, не мигрируется |

**Baseline** двигается на текущее значение счётчика в трёх случаях:
первый запуск (нет `baseline_version`), смена версии приложения (любая —
сравнение строковое «не равно»), нажатие «Прочитал». Гарантия анти-спама:
после любого обновления и после каждого прочитанного сообщения следующее
ждёт свои `min_active_hours` наработки. «Later» baseline НЕ двигает (иначе
отложенное отодвигалось бы дважды).

## 4. Выбор сообщения (`SupportMessageService.pick`, pure)

```
если наработка < snooze_after_seconds → null          // глобальный «Later»
идём по messages по порядку:
  skip → перешагиваем
  isNewer(since_version, app_version) → перешагиваем   // версия юзера не доросла
  read[id] есть И НЕ isNewer(since_version, read[id]) → перешагиваем  // прочитано
  ← первое видимое непрочитанное; очередь строгая — дальше не идём:
    сессия < min_session_minutes·60 → null
    наработка − baseline < min_active_hours·3600 → null
    иначе → показать это сообщение
```

Один показ за запуск процесса (`_supportShown`, как v1). Сравнение версий —
существующий `isNewer` (update_checker.dart, semver, `-dev`-суффикс режется).
Удаление сообщения из файла безопасно: запись в `read` повисает мёртвой.

## 5. Нативный учёт наработки (`ActiveTimeTracker` v2)

Первичный источник — `BoxVpnClient.getTunnelUptimeMs()` (§187): монотонный
аптайм текущей сессии туннеля, живёт в native-сервисе, переживает смахивание
приложения. Схема зачисления:

```
credit():
  uptime ≤ 0 → выход
  uptime < session_credited → session_credited = 0    // туннель перезапускался
  delta = uptime − session_credited
  delta > 0 → active_seconds += delta; session_credited = uptime
```

- Вызовы: `onTunnelChanged(true)`, `tick()` (не чаще раза в минуту),
  `totalSeconds()` (перед каждым решением о показе).
- `onTunnelChanged(false)` → `session_credited = 0` (сессия закрыта; хвост с
  последнего кредита ≤ 1 мин теряется — как v1).
- Открыли приложение после суток VPN при мёртвом UI → `uptime − credited`
  доливается одним куском. Кейс «смахнул → VPN отработал → VPN остановлен →
  открыл приложение» не доливается (аптайм уже 0) — честная потеря.
- Детектор новой сессии — `uptime < credited` (без wall-clock ключей: скачки
  системных часов не задваивают). Быстрый рестарт за спиной мёртвого UI даёт
  недосчёт (безопасное направление), не двойной счёт.
- Гонка параллельных `credit()` (tick + totalSeconds) снята in-flight-замком.
- `uptimeMsProvider` не подключён (тесты) → legacy wall-clock учёт v1
  (`_lastFlush`) без изменений.

## 6. UI

`showSupportDialog(context, feed, m)`: контент = `m.contentFor(effectiveTag)`;
кнопки **«Later»** (TextButton → `snooze(feed)`) и **«Got it»** (FilledButton →
`markRead(m)`). Кнопки-ссылки диалог не закрывают. Ключ «Don't show again»
удалён из кода и ru-словаря; добавлен «Got it» (ru: «Прочитал»).

## 7. Файлы

| Файл | Что |
|---|---|
| `app/lib/services/support/support_message.dart` | `SupportContent`/`SupportMessage`/`SupportFeed` + `SupportMessageService` (pick/nextToShow/markRead/snooze/_syncBaseline; test seams `httpClientForTesting`, `appVersionForTesting`) |
| `app/lib/services/support/active_time_tracker.dart` | нативный учёт (§5) + legacy fallback |
| `app/lib/services/support/support_state.dart` | `getStringMap`/`setAll`, обновлён список полей |
| `app/lib/screens/home/home_dialogs.dart` | диалог: локаль в момент показа, кнопки Later/Got it |
| `app/lib/screens/home_screen.dart` | `_supportFeed`, wiring `uptimeMsProvider = _vpn.getTunnelUptimeMs` |
| `docs/support.json`, `docs/support.test.json` | формат v2, лента из 10 сообщений (EN+RU) |
| `app/assets/l10n/ru/ui.json` | −«Don't show again», +«Got it» |
| `app/test/services/support_message_test.dart` | переписан под v2 (§8) |

## 8. Тесты

- `pick`: строгая очередь (гейт первого непрочитанного блокирует, не
  перескакиваем); `since_version`-таргетинг перешагивает; бамп `since_version`
  выше `read[id]` → показ обновившемуся; `skip`; baseline-порог; session-gate;
  глобальный снуз.
- `fromJson`: feed/дефолты; сообщение без `en` отбрасывается; `contentFor`
  фолбэк en; битые links скипаются; malformed → null.
- `fetchOrCached`: 200 → парс+кэш; офлайн → кэш; ни сети ни кэша → null.
- baseline: смена версии сдвигает (та же — нет); `markRead` пишет версию и
  сдвигает; `snooze` поднимает порог от total.
- `ActiveTimeTracker` native: доливка delta; рестарт (`uptime<credited`);
  параллельные credit не задваивают; legacy path без провайдера жив.

## 9. Решения (зафиксировано с юзером)

- Обратной совместимости формата нет.
- `en` — язык по умолчанию/фолбэк; блок обязателен.
- Пороги (`min_active_hours`, `min_session_minutes`) — на каждом сообщении;
  `snooze_active_hours` — общий.
- Очередь строгая: гейты первого непрочитанного не пройдены → в этот раз ничего.
- Обновление приложения само по себе ничего не «распрочитывает» — только
  двигает baseline; повторный показ — исключительно бампом `since_version`.
- Кнопки: «Got it» (= прочитал) / «Later»; «Don't show again» упразднена —
  вывод сообщения из ротации теперь авторский (`skip: true`).
