# §238 — Debug API: CRUD каналов (§125) и папок серверов (§234)

> СТАТУС: реализовано (04.07.2026). Расширение Debug API (§031/§043 A.11).

## Что

Debug API умел мутировать rules / subs / settings, но два более новых домена
оставались read-only (видны только сквозь `/state/storage`):

1. **Каналы роутинга §125** (`channels[]` в `lxbox_settings.json`) — теперь
   полный CRUD `/channels/*` поверх `SettingsStorage.getChannels /
   addChannel / updateChannel / deleteChannel` (та же семантика, что у UI:
   vpn-1 неудаляем и всегда enabled, лимит 10, деградация ссылок
   route_final / custom-rule → vpn-1 при удалении/выключении — §202-механика
   внутри storage).
   > С [§275](275-channel-mutations-detour-resync.md) (v2.15.6) хендлер зовёт не
   > storage напрямую, а `ChannelMutations.add/update/delete` — heal и зеркальный
   > ресинк `_entries` контроллера одной операцией. Семантика эндпоинтов та же.
2. **Папки серверов §234** (`FolderServers` в `server_lists`) — CRUD
   `/folders/*` поверх публичных методов `SubscriptionController`
   (addFolder / deleteFolderAt / addMembersToFolder / addUrlSnapshotToFolder /
   setMembersEnabled / updateMemberAt / removeMemberAt / applyMembersOrder /
   ungroupMemberAt / setMemberDetour (§237) / moveMemberToFolder /
   moveServerToFolder), плюс `POST /folders/{id}/probe` — headless «Test
   servers» (§236, `FolderProbeRunner`) с результатами в ответе — удалённая
   диагностика достижимости нод папки.

## Поверхность

### `/channels/*`

| Метод | Путь | Семантика |
|---|---|---|
| GET | `/channels` | список `Channel.toJson()` (storage-shape, snake_case) |
| GET | `/channels/{tag}` | один канал |
| POST | `/channels[?rebuild]` | `addChannel(label)` — первый свободный `vpn-N`; остальные поля body применяются как PATCH после создания. 201 + ресурс |
| PATCH | `/channels/{tag}[?rebuild]` | частичный update: `label,enabled,include_direct,include_block,node_filter,node_filter_invert,default_filter,interrupt_exist_connections,auto` |
| DELETE | `/channels/{tag}[?rebuild]` | `deleteChannel` (ссылки деградируют на vpn-1) |
| POST | `/channels/reorder[?rebuild]` | body `{"order":[tag,...]}` — полный набор текущих тегов |

Решения:

- **`auto` в PATCH — merge, не replace**: `{"auto":{"url":...}}` мержится в
  текущий `ChannelAuto` (или дефолтный, если галка была выкл), включая
  вложенный `balancer{}` одним уровнем. `"auto": null` (ключ присутствует,
  значение null) = снять галку (`clearAuto`). Иначе PATCH одним полем
  сбрасывал бы остальные urltest-опции в дефолты.
- **Инварианты — 409 Conflict**: `DELETE vpn-1`, `PATCH vpn-1 {"enabled":false}`,
  создание сверх лимита 10.
- **`tag` immutable**: `tag` в body PATCH → 400 (в UI юзер правит только label).
- **Regex-валидация**: `node_filter`/`default_filter` компилируются `RegExp` в
  хендлере; невалидный → 400 (битый regex ронял бы сборку конфига).
- Порядок каналов = порядок эмита в конфиге → reorder тоже принимает
  `?rebuild=true`. `_setChannels` сам ставит `markConfigDirty`.

### `/folders/*`

Папка — это entry в общем списке `/subs` (kind=FolderServers), поэтому
адресация по стабильному `id` entry. **Члены адресуются позиционным
индексом** (у `FolderMember` нет id) — после remove/ungroup/reorder индексы
съезжают; каждый write-ответ возвращает свежий снапшот папки, по нему и
строить следующий вызов.

| Метод | Путь | Семантика |
|---|---|---|
| GET | `/folders[?reveal]` | только folder-entries; члены без `raw` (credentials), `?reveal=true` — с raw |
| POST | `/folders[?rebuild]` | body `{"name":"..."}` → `addFolder`. 201 + ресурс |
| GET | `/folders/{id}[?reveal]` | одна папка + члены |
| DELETE | `/folders/{id}[?keep_servers=true][?rebuild]` | `deleteFolderAt`; `keep_servers=true` выносит членов одиночными серверами на место папки (default false) |
| POST | `/folders/{id}/members[?rebuild]` | ровно одно из: `{"input":"..."}` (paste, опц. `name_fallback`) → `addMembersToFolder`; `{"url":"..."}` → `addUrlSnapshotToFolder` (одноразовый снапшот, URL не хранится) |
| PATCH | `/folders/{id}/members/{idx}[?rebuild]` | subset `{raw, enabled, detour}`; `raw` валидируется парсером (битый → 400, член не трогается); `detour` — §237 личный detour (display-form тег, `''` = снять) |
| DELETE | `/folders/{id}/members/{idx}[?rebuild]` | `removeMemberAt` |
| POST | `/folders/{id}/members/reorder[?rebuild]` | body `{"order":[старые индексы в новом порядке]}` — полная перестановка |
| POST | `/folders/{id}/members/{idx}/ungroup[?rebuild]` | `ungroupMemberAt` — член → одиночный сервер сразу после папки; личный detour переезжает в `override_detour` |
| POST | `/folders/{id}/members/{idx}/move[?rebuild]` | body `{"to":"<folder id>"}` → `moveMemberToFolder` |
| POST | `/folders/{id}/move-server[?rebuild]` | body `{"server_id":"<subs entry id>"}` → `moveServerToFolder` — одиночный UserServer въезжает членами (1:1 по нодам), запись удаляется |
| POST | `/folders/{id}/probe` | headless «Test servers» §236; body опц. `{"url":"...","timeout_ms":N}` (default — глобальные ping_options) |

Решения:

- **Meta папки (name/enabled/tag_prefix/detour_policy) — через уже
  существующий `PATCH /subs/{id}`** (folder-entry — обычный sub-entry,
  сеттеры `SubscriptionEntry` работают через sealed `_copy`). `/folders`
  не дублирует.
- **`entry есть, но не папка` → 409** (не 404): диагностируемее при путанице
  id (`.../subs/{id}` vs `.../folders/{id}`).
- **Ошибки-строки контроллера**: paste/`raw`-парсинг → 400; URL-снапшот
  (сетевой fetch) → 502 upstream_error.
- **Probe синхронный**: результаты в ответе (`results[]` по индексам члена +
  `summary`). Статусы — wire-форма `ok|failed|broken|invalid|not_in_config|
  pending` (§236 `ProbeStatus`). При запущенном VPN выключенные члены не в
  конфиге → `not_in_config` (гейт нативной probe-сессии, как в UI). Фатальный
  старт probe → 502. Большая папка при малом `timeout_ms` укладывается легко;
  worst-case ~`members/6 × timeout_ms` — при дефолтных 3000мс и >60 членах
  можно упереться в request-timeout сервера (30с) — снижать `timeout_ms`.
- Сериализация члена: `{index, enabled, detour, tag, protocol, broken}`;
  `raw` — только под `?reveal=true` (симметрия со скраббером §234 в
  `/state/storage`: raw несёт credentials).

## Файлы

| Файл | Изменение |
|---|---|
| `services/debug/handlers/channels.dart` | новый — `/channels/*` |
| `services/debug/handlers/folders.dart` | новый — `/folders/*` + probe |
| `services/debug/serializers/subs.dart` | + `serializeFolderEntry` / `serializeFolderMember` |
| `services/debug/transport/server.dart` | mount `/channels`, `/folders` |
| `services/debug/handlers/help.dart` | секции Channels / Folders (text + json) |
| `docs/api/debug-api-reference.md` | разделы Channels CRUD / Folders CRUD |
| `test/services/debug/channels_handler_test.dart` | новый — storage-backed |
| `test/services/debug/folders_handler_test.dart` | новый — real controller |

## Связанные

- §125 configurable-channels (модель Channel, storage-семантика);
- §234 server-folders, §236 folder-server-testing, §237 member node settings;
- §043 A.11 (CRUD-паттерн Debug API), §218 (help — единственный источник
  правды о поверхности).
