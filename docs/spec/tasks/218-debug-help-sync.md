# §218 — Синхронизация `/help` Debug API с реально смонтированными роутами

> **СТАТУС: ВЫПОЛНЕНО.** Чисто документация — код API не меняется, только
> `handlers/help.dart` (текстовый раздел + машиночитаемый `endpoints[]`).

## Проблема

`GET /help` отстал от реально обслуживаемых роутов. Сверка `mount(...)` в
`transport/server.dart` + развилок в хендлерах против упоминаний в `help.dart`
выявила роуты, которые **работают**, но в хелпе не описаны (или описаны только в
одной из двух копий — текст vs `endpoints[]`).

Корень дрейфа: help — две руками поддерживаемые копии (человекочитаемый текст и
JSON `endpoints[]`). Роуты добавлялись в хендлеры, а обе копии обновлялись не
всегда.

## Что было пропущено

| Роут | Методы | Где отсутствовал |
|---|---|---|
| `/subs`, `/subs/{id}`, `/subs/{id}/refresh`, `/subs/reorder` | GET/POST/PATCH/DELETE | **весь CRUD** — ни текста, ни `endpoints[]` (был только read-only `GET /state/subs` и `POST /action/refresh-subs`) |
| `/settings/ping_options` | GET/PUT | нет |
| `/settings/ping_options/groups/{tag}` | GET/PUT/DELETE | нет |
| `/settings/tun_apps` | GET/PUT | нет |
| `/action/force-stop-vpn` | POST | был в `endpoints[]`, **нет в тексте** |
| `/action/set-transient-timeout` | POST | был в `endpoints[]`, **нет в тексте** |

`/files/external` — оказался УЖЕ задокументирован (legacy alias в строке про
`/files/local`), не дыра.

## Правка

`handlers/help.dart`, обе копии синхронно:

1. Новая текстовая секция `=== Subscriptions CRUD ===` (по образцу
   `=== Rules CRUD ===`): GET/POST/PATCH/DELETE/{id}/refresh/reorder + пометка
   `?rebuild=true` на write'ах, `?reveal=true` на read'ах.
2. В `=== Settings (scoped writes) ===` — три строки: `ping_options`,
   `ping_options/groups/{tag}`, `tun_apps` с телами.
3. В `=== Actions ===` — `force-stop-vpn` и `set-transient-timeout` (текст).
4. В `endpoints[]` — соответствующие записи для `/subs*`, `ping_options*`,
   `tun_apps` (force-stop/set-transient уже были).

## Тела (сверено с кодом)

- `POST /subs` → `{"input":"<url|URI|WG|JSON>"}`; `PATCH /subs/{id}` →
  `{enabled,name,url,tag_prefix,update_interval_hours,override_detour,
  register_detour_servers,register_detour_in_auto,use_detour_servers,
  replace_detour_chain}` (любое подмножество); `POST /subs/reorder` →
  `{"order":[id,...]}`.
- `PUT /settings/ping_options` → `{url?,timeout_ms?,groups?}`;
  `PUT /settings/ping_options/groups/{tag}` → `{url?,timeout_ms?}` (min один);
  `PUT /settings/tun_apps` → `{mode:"off|allow|deny", packages:[str]}`.

## Не делаем

- Автогенерацию help из mount-таблицы (соблазн) — вне scope; отдельная задача,
  если дрейф повторится.

## Связанные

- §032 Debug API (первичная спека).
- Роуты `/subs` реализованы в `handlers/subs.dart`, смонтированы
  `server.dart` — код был, документация отсутствовала.
