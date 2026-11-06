# 386 — WARP wizard: combobox-пресеты у полей с кубиком

> **§420 (2026-09-05):** секция `masque` asset'а переложена по транспортам (`hosts_preset` общий, `h3.hosts_extra`, `h2.v4_cidr`+`exclude`); `h3_v4_cidr`/`ports_h3`/`ports_h2` — фолбэк для старого JSON. Рекомендуемый хост — `162.159.198.2`, не домен. См. [tasks/420](420-masque-pool-per-transport.md).


## Мотивация

Кейс 4PDA (dewch, 09.08.2026): конфиг WARP не заводится, потому что дефолтный
endpoint `engage.cloudflareclient.com:2408` у части операторов дропается целиком
(device-verified: тот же аккаунт на `162.159.192.192:934` работает). Кубик 🎲
даёт только рандом — известные/рекомендуемые значения выбрать нельзя, руками их
никто не помнит.

Решение: каждое поле с кубиком становится **комбобоксом** (свободный ввод +
выпадающий список известных значений) + кнопка-кубик рядом. Паттерн уже есть в
визарде: WG masquerade domain и MASQUE SNI (`DropdownMenu` + `IconButton`
casino). Задача — привести к нему два оставшихся поля.

## Изменения

| Поле | Было | Стало |
|---|---|---|
| WG Endpoint (Advanced) | `TextField` + кубик в suffixIcon (виден при обфускации) | `DropdownMenu` (пункты из `endpoints_preset`) + кубик `IconButton` рядом (по-прежнему только при обфускации) |
| MASQUE Endpoint IP | `TextField` + кубик в suffixIcon | `DropdownMenu` (пункты из `masque.hosts_preset`; фолбэк без ключа — /32-хосты `h3_v4_cidr`) + кубик рядом |
| WG masquerade domain | `DropdownMenu` + кубик | без изменений (эталон) |
| MASQUE SNI | `DropdownMenu` + кубик | без изменений (эталон) |

## Данные: `assets/warp_endpoints.json` → `wireguard.endpoints_preset`

Новый ключ — список строк `host:port`: официальный хост на достоверных портах
и представители IP-блоков. Порядок семантики НЕ несёт. Рекомендуемое значение —
ЯВНЫЙ соседний ключ `recommended_endpoint` (`engage.cloudflareclient.com:2408`,
официальный дефолт Cloudflare); UI помечает суффиксом ` (recommended)` пункт
списка с этим значением, на любой позиции. Для MASQUE симметрично:
`masque.hosts_preset` + `masque.recommended_host`
(`consumer-masque.cloudflareclient.com`). Нет ключа → нет пометки.

Парс: `ScanPool.wgEndpointsPreset` (обычный `strs`, отсутствие ключа в старом /
пользовательском JSON-override → пустой список → combobox без пунктов, поведение
как раньше). `WarpEndpointPicker.endpointsPreset` — тонкий проброс.

## Трекинг ручной правки endpoint

У `TextField` был `onChanged`, снимавший `_endpointAutoFilled`; у `DropdownMenu`
`onChanged` нет — и выбор пункта, и свободный ввод идут через контроллер.
Замена: listener на `_endpoint` + поле `_lastAutoEndpoint` (значение последнего
авто-рандома). Текст изменился и ≠ `_lastAutoEndpoint` → правка ручная, флаг
снимается. `_fillRandomEndpoint` пишет `_lastAutoEndpoint` ДО `text` (иначе
listener снимет флаг на собственном же авто-填е).

### Доработка 01.11.2026: выбранный `engage…:2408` не подменяется

**Проблема.** Пользователь выбирал в списке `engage.cloudflareclient.com:2408`,
а в узел уходил IP. Значение совпадает с `WarpAccount.defaultEndpoint`, и
«пользователь выбрал» везде считалось как «значение ≠ дефолту». Поэтому
выбранный дефолт считался невыбранным и подменялся:

1. мастер (`_endpointReplaceable`): при включении обфускации поле получало
   случайный `ip:port`;
2. `SubscriptionController.addWarp`: при обфускации в узел шёл случайный
   `ip:port`, даже если в поле на момент Register стоял выбранный
   `engage…:2408`; без обфускации у закешированного аккаунта оставался
   endpoint из кэша (например, прошлый рандом);
3. `WarpClient.register`: вместо значения брался `peer.endpoint.host` из ответа
   Cloudflare.

**Решение.** «Не выбран» = `null`, а не равенство дефолту.

- Мастер: стартовое значение поля тоже авто (`_endpointAutoFilled = true`,
  `_lastAutoEndpoint = defaultEndpoint`), выбор из списка или ввод снимают
  флаг тем же listener'ом. `_endpointReplaceable` = пусто или авто. В
  `addWarp` уходит `null`, если поле пустое или в нём нетронутый дефолт.
- `addWarp(endpoint: String?)`, `register(endpoint: String?)`: `null` → рандом
  при обфускации / host из ответа Cloudflare; любое заданное значение, включая
  `engage…:2408`, едет как есть и побеждает кэш.
- Debug API `POST /warp`: пустой `endpoint` → `null`, заданный — как есть.
- Генератор §284 регистрирует без endpoint (`null`), как и раньше по смыслу.

Видимое поведение мастера не меняется: поле открывается с `engage…:2408`,
галка обфускации по-прежнему подставляет рандом, пока пользователь сам ничего
не выбрал.

**Проверка.** `test/warp/warp_client_test.dart`: явный `engage…:2408` при
ответе Cloudflare с IP и рандоме обфускации остаётся `engage…:2408`; без
endpoint берётся host из ответа. Мастер на эмуляторе не проверялся.

## l10n

Новая строка `"(recommended)"` → `assets/l10n/ru/ui.json`.

## Правки по фидбэку

- Лейблы полей — в одну строку, без пометок «(optional)»: `Endpoint IP`,
  `SNI`, `WARP+ license key` (ключ `Endpoint IP (optional)` переименован в
  словаре).
- MASQUE-пресеты — отдельный ключ `masque.hosts_preset`, рекомендуемый —
  **домен** `consumer-masque.cloudflareclient.com`, не фиксированный IP.
- Пометка "(recommended)" — НЕ магия первого элемента: рекомендуемое значение
  задаётся явными ключами `recommended_endpoint` / `recommended_host` в asset.

## Не делаем

- Пресеты для MASQUE-порта — уже combo (`DropdownButtonFormField`).
- Пробу живости пунктов списка — это §284 (endpoint scanner), не UI-пресеты.
