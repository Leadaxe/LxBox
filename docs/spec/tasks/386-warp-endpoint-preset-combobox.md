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
