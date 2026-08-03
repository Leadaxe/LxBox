# §357 — Support-лента v2.1: полноэкранный показ, псевдопротокол lxbox://, Debug API

**Тип:** таска (расширение §356)
**Статус:** реализовано и DEVICE-VERIFIED 03.08.2026 (эмулятор sdk_gphone64_arm64: полноэкранный показ, таймер «Прочитал (N)», скрытие незнакомого действия, route:dns/route:profiler→Stats-Live, add:vless→prefill поля Servers, mark_read в read; Debug API /support/state|reset|preview прогнаны curl'ом)
**Связано:** §356 (support-лента — источник кнопок), §258 (`focusChannelTag` — прецедент открытия экрана «с прицелом»), §044/§316 (профайлер — вкладка Profiling на Debug-экране), §031/§238 (Debug API), `preview-empty-state` (прецедент UI-превью через Debug API)

## 0. Объём поверх §356 (решения юзера 03.08.2026)

1. **Полноэкранный показ** вместо AlertDialog: сообщение — отдельный
   fullscreen-маршрут (Scaffold), а не попап «поверх, занимает мало места».
2. **Псевдопротокол `lxbox://<action>:<payload>`** в кнопках (см. §2).
3. **`mark_read` у lxbox-кнопок** (default true) — тап по кнопке навигации
   закрывает сообщение и помечает прочитанным; `"mark_read": false` — не
   помечать (придёт снова).
4. **Таймер кнопки «Got it»** — `read_delay_seconds` на сообщении
   (default 10): первые N секунд кнопка неактивна и тикает «Got it (7)» —
   защита от смахивания не глядя. «Later» и кнопки-ссылки активны сразу.
5. **`add:`** открывает Servers с предзаполненным полем ввода — добавление
   подтверждает сам юзер (кнопка «+», обычный превью-флоу). Ничего не
   сохраняем автоматически: support.json приезжает с GitHub, авто-добавление
   узла при компрометации канала подсунуло бы юзерам чужой сервер.
6. **Debug API `/support/*`** — тестирование ленты без наработки часов (§6).
7. Гайд: en-версия `docs/USER_GUIDE.md` готова — en-кнопки ведут на неё.

---

## 1. Идея

Кнопка сообщения ленты может вести не только на URL, но и **внутрь приложения**:
рассказали про профайлер — кнопка сразу открывает его. Формат ссылки в
`support.json` не меняется (`links[].url`), меняется схема:

```jsonc
{ "label": "🔍 Открыть профайлер", "url": "lxbox://route:profiler" }
```

## 2. Грамматика

```
lxbox://<action>:<payload>
```

Действие отделяется от аргумента **двоеточием** (решение юзера): payload —
сырая строка «всё после первого `:`», поэтому аргументом может быть целый
URI со своими слешами/query/фрагментом, парсинг однозначен:

```
lxbox://route:dns
lxbox://route:debug/profiling
lxbox://add:vless://uuid@host:443?security=reality&sni=…#название
```

v1 реализует единственное действие — `route:<screen>[/<tab>]` (payload
делится по `/` уже внутри действия). `add:` и прочие — задел на будущее.
`Uri.parse` НЕ используется (он видит в `route:menu` пару host:port) —
парсим строкой: префикс `lxbox://` → до первого `:` действие, дальше payload.

**Forward-compat правило:** неизвестное действие, неизвестный экран или
нерезолвящийся маршрут → **кнопка не показывается вовсе**. Автор может слать
в JSON новые действия — старые версии приложения молча их спрячут, не упадут.
Известный экран + неизвестная вкладка → экран на дефолтной вкладке (мягкая
деградация).

## 3. Реестр маршрутов v1

| Маршрут | Экран | Вкладки (`<tab>`) |
|---|---|---|
| `route:servers` | SubscriptionsScreen | — |
| `route:routing` | RoutingScreen | `presets` (через `initialPresetsTab`) |
| `route:dns` | DnsSettingsScreen | — |
| `route:vpn-settings` | SettingsScreen | — |
| `route:app-settings` | AppSettingsScreen | `general`/`subscriptions`/`diagnostics`/`automation` → `initialTab` 0–3 |
| `route:speedtest` | SpeedTestScreen | — |
| `route:stats` | StatsScreen | `overview`/`connections`/`live` → `initialTab` (гейт: туннель поднят, иначе кнопка скрыта — как пункт drawer) |
| `route:config` | ConfigScreen | — |
| `route:debug` | DebugScreen | `log`/`crashes`/`oom`/`profiling` → `initialTab` 0–3 (**new** параметр) |
| `route:about` | AboutScreen | — |
| `route:profiler` | **семантический алиас** = `stats/live` (гейт туннеля) | — |

`profiler` — алиас по назначению, а не по месту в UI: слаг в опубликованных
JSON переживёт переезд фичи. Сегодня «куда ходят приложения» — вкладка Live
на Statistics (§264-266); Debug/Profiling — это pprof-слепки ядра, НЕ то.

## 4. Реализация

- `app/lib/services/support/support_nav.dart` — `SupportLinkAction.parse(url)`
  (pure: `lxbox://<action>:<payload>` строкой, БЕЗ `Uri.parse`; иначе null),
  `isResolvableSupportAction` (route + экран из `kSupportRouteScreens`, или
  add с непустым payload), `routeSegments`.
- Модель (§356 support_message.dart): `links` → `SupportLinkSpec
  {label, url, markRead=true}`; сообщение + `readDelaySeconds=10`.
- **`SupportMessageScreen`** (`app/lib/screens/home/support_message_screen.dart`)
  — fullscreen-маршрут вместо AlertDialog: AppBar (X = закрыть без пометок,
  придёт снова), крупный title + текст + кнопки-ссылки; низ — «Later»
  (снуз ленты) и «Got it (N)» (таймер → markRead). https-кнопки открывают
  браузер и экран НЕ закрывают; lxbox-кнопки: `markRead` по флагу +
  `pushReplacement` целевого экрана.
- `home_screen`: `_maybeShowSupport` пушит SupportMessageScreen;
  `_buildSupportScreen(SupportLinkAction)` — резолв маршрута (все контроллеры
  там; `stats` гейтится `tunnelUp`; `add:` → SubscriptionsScreen с prefill);
  слушает `HomeController.takeSupportPreview()` (Debug API §6).
- `debug_screen.dart` — новый параметр `initialTab` (clamp 0–3,
  `DefaultTabController.initialIndex`, паттерн `AppSettingsScreen.initialTab`).
- `subscriptions_screen.dart` — новый параметр `initialInput` (prefill поля
  «URL подписки или proxy-ссылка», рядом с прецедентом `focusEntryId`).
- `home_dialogs.showSupportDialog` удалён (заменён экраном).

## 5. Тесты

- `test/services/support_nav_test.dart`: parse (валид/битые/без payload/
  вложенный URI с `://` в payload), резолвабельность (route+известный экран;
  неизвестное действие → false; route/unknown → false), routeSegments.
- support_message_test: парс `mark_read`/`read_delay_seconds` + дефолты.
- widget-тест `SupportMessageScreen`: таймер «Got it» (N сек disabled →
  enabled), скрытие кнопки с неизвестным действием, «Later» активна сразу.

## 6. Debug API `/support/*` (тестирование ленты)

| Endpoint | Что |
|---|---|
| `GET /support/state` | сырое `support_state.json` + `app_version` + `total_active_seconds` |
| `POST /support/reset` | сброс `read`/`baseline_*`/`snooze_after_seconds`/`cache_json` (query `?keep_active=false` дополнительно обнуляет счётчик наработки) |
| `POST /support/preview` | body = JSON одного сообщения формата ленты → немедленный полноэкранный показ ВНЕ гейтов (туннель/пороги/очередь не проверяются). Query `?dry=true` (default) — кнопки работают, но `markRead`/`snooze` НЕ пишутся в state; `?dry=false` — пишут (сквозной тест очереди) |

Механика показа — паттерн `preview-empty-state`: handler → `ctx.home.
requestSupportPreview(...)` → `notifyListeners` → home_screen забирает
одноразовый запрос и пушит экран. UI-процесс обязателен (headless → 409).
