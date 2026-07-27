# §228 — FakeIP DNS-пресет (+ preset-cleanup: outbound-vars, ремап id)

> **СТАТУС: РЕАЛИЗАЦИЯ.** Ядро/шаблон FakeIP — только `wizard_template.json`
> (билдер пропускает `type: fakeip`/`store_fakeip` verbatim). Device-проверка
> вскрыла смежные правки: магическая var `dns_server`, UI-гейт outbound-picker,
> outbound-vars для роутинг-пресетов + ремап переименованных `preset_id`
> (storage-миграция). Полный список — «Файлы».

## Зачем

Пользователи просят FakeIP ради **скорости DNS** и **анти-утечки**:

- **Скорость** — на запрос имени резолвер мгновенно отдаёт placeholder-IP из
  пула `198.18.0.0/15` (v4) / `fc00::/18` (v6), не ходя в интернет. DNS-latency
  ≈ 0.
- **Анти-утечка** — реальный резолв домена происходит уже внутри туннеля (по
  фейк-IP ядро вспоминает домен и резолвит через нужный outbound). До туннеля
  ISP не видит реальных DNS-запросов.

**Это НЕ анти-DPI.** DPI режет по SNI в ClientHello, а не по DNS. Для DPI —
`tls_fragment`/`tls_record_fragment` (секция DPI Bypass). Формулировка в
`description` пресета это проговаривает.

## Решение — пресет `selectable_rules[]`

Data-plane FakeIP выражается чисто пресетом (как `ru-direct`):

```json
{
  "preset_id": "fakeip",
  "label": "FakeIP",
  "default": false,
  "dns_servers": [
    {"type": "fakeip", "tag": "fakeip", "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18", "description": "FakeIP allocator"}
  ],
  "dns_rule": {"query_type": ["A", "AAAA"], "server": "fakeip"}
}
```

- `dns_servers` → вливается в `config.dns.servers[]` (билдер, verbatim).
- `dns_rule` → вливается в `config.dns.rules[]` (билдер, verbatim; нужен
  только `server`). `query_type: [A, AAAA]` заворачивает на fakeip все
  обычные запросы имён.

Диапазоны захардкожены (дефолты sing-box) — менять их незачем, отдельный var
только путал бы.

## Критично: ПОРЯДОК в каталоге (разводка с ru-direct/geoip)

`fakeip` в `selectable_rules[]` стоит **ПОСЛЕ `ru-direct`**. Билдер сохраняет
порядок пресетов при склейке `dns.rules[]`, sing-box берёт первое сматчившее
dns-правило. Поэтому:

1. ru-dns-rule (`ru-domains`/`ru-services` → yandex) — **раньше** → русские
   домены резолвятся по-настоящему.
2. fakeip-rule (всё остальное A/AAAA → fakeip) — **позже**.

**Почему это важно:** fakeip-правило матчит всё. Если бы оно стояло раньше
ru-правила, русские домены тоже получили бы фейк-IP, и route-правило
`geoip-ru` (матчит по реальному IP) по фейку `198.18.x.x` не сработало бы →
русские CDN без домена в списках поехали бы через VPN вместо direct.

**Остаточный компромисс (неустраним):** `geoip-ru` как чистый IP-fallback
(ловить CDN/QUIC/ECH, где домен не виден) с FakeIP всё равно слабеет — по
фейк-IP geoip не матчит. Домены из `ru-domains`/`ru-services` разведены
корректно (см. выше), но чисто-IP-случаи — цена FakeIP. Это осознанный
trade-off, обойти в рамках FakeIP нельзя.

## Порядок системных route-правил — sniff ПЕРЕД resolve

Помимо пресета, изменён порядок базовых `config.route.rules`:

**Было:** `resolve` → `sniff` → `hijack-dns`
**Стало:** `sniff` → `hijack-dns` → `resolve`

**Почему:** для FakeIP приложение стучится на фейк-IP `198.18.x.x`. Домен надо
извлечь снифом ДО того, как сработает `resolve` — иначе `resolve` пытается
резолвить фейковый литерал (бессмысленно/мусор). Канонический порядок FakeIP —
sniff (достать домен) → hijack-dns (DNS-запросы в наш движок, где fakeip-сервер)
→ resolve (реальный резолв уже с известным доменом).

**Безопасность для не-FakeIP режима** (проверено): прежний порядок
`resolve`-первым был **не осознанным** — скопирован verbatim из рабочего
launcher-конфига (commit `20457f3`), намеренным было лишь «все три до
hijack-dns». Обоснования relative-порядка нет ни в спеке (§121), ни в коде.
Билдер не зависит от позиции (системные правила идут в голову, пресеты
append'ятся после; поиска по индексу нет). Тесты не падают: `vpn_mode_test`
ищет правило по `action`, не по позиции; positional-асерты
`rule_set_registry_test` используют свои inline-фикстуры, не шаблон.
Для обычного IP/geoip-роутинга sniff-первым нейтрально-или-лучше (домен
извлекается раньше, `resolve` затем честно применяет `@resolve_strategy` =
`prefer_ipv6`). §121 не затрагивается — обе action'ы всё равно идут перед
outbound-матчингом.

## Персистентность — `store_fakeip` в базе

`experimental.cache_file.store_fakeip: true` добавлен в базовый `config`
(не пресетом — статичный флаг вне досягаемости `selectable_rules`).

**Зачем:** таблица «фейк-IP ↔ домен» живёт в памяти ядра. При реконнекте
(Stop→Start, моргание сети) она стирается, но приложения кэшируют выданный
фейк-IP дольше — стучатся на `198.18.x.x`, не перезапрашивая DNS, ядро уже не
знает домена → залипшие/рваные соединения на несколько минут. Особенно больно
на мобильном (частые реконнекты). `store_fakeip` пишет таблицу в наш `cache.db`
(`cache_file` уже включён), при реконнекте она поднимается с диска.
Безвредно, когда fakeip не используется — ядру просто нечего писать.

## Что НЕ ставим — `independent_cache`

`dns.independent_cache` **deprecated в sing-box 1.14** (мы на `v1.14.0-lx.1`).
В новой DNS-модели 1.14 (серверы-объекты с `type`) он не нужен. Билдер его и
так не генерит (см. §121: «0 occurrences, не генерируем»). Не добавляем.

## Билдер (проверено, изменений не требует)

- Валидатор (`validator.dart`) НЕ имеет whitelist типов DNS-серверов — только
  проверка dangling tag-ref для `dns.final` / `default_domain_resolver`.
  `type: fakeip` проходит.
- `preset_expand.dart` вливает `dns_servers` → `dns.servers[]`, `dns_rule` →
  `dns.rules[]` verbatim (через `deepCopyJson` + `substituteVars`); `query_type`
  проходит passthrough.
- Билдер НЕ трогает `experimental`/`cache_file` — `store_fakeip` в базе
  доживает до итогового конфига нетронутым.

## Магическая переменная `dns_server` (device-фикс)

При первой проверке на устройстве FakeIP **не работал**: `/config` показывал,
что fakeip-сервер не влит в `dns.servers`, а dns-правило `server: fakeip`
дропнуто. Причина — механизм вливания пресетного `dns_servers[]`
(`preset_expand.dart`) эмитит сервер **только если у пресета есть var
`dns_server`** (`type: dns_servers`), чьё значение = tag сервера. Без неё цикл
не запускается, сервер не эмитится, `dns_rule.server: fakeip` виснет на
несуществующий сервер → guard молча дропает правило. Пресет не делает ничего.

**Фикс:** добавлен var `dns_server` (`default_value: "fakeip"`,
`wizard_ui: "hidden"`), `dns_rule.server` завязан на `@dns_server`. Теперь
сервер и правило эмитятся атомарно (как у ru-direct). Это «магическая
переменная» — см. новый раздел в TEMPLATE.md.

## UI-правки (побочные, вскрыты на устройстве)

1. **Hidden preset-vars не рисуются в редакторе.** `preset_params_tab.dart`
   игнорировал `wizard_ui: hidden` для preset-vars (в отличие от sections).
   Без фильтра новый `dns_server` рисовал мёртвый dropdown-из-одного-пункта.
   Добавлен `.where((v) => v.wizardUI != 'hidden')`.
2. **Outbound-picker в строке — строго по наличию var:outbound.** Раньше
   строка рисовала picker безусловно. Добавлен геттер
   `SelectableRule.hasOutboundAffordance = vars.any((v) => v.type ==
   'outbound')` → picker показывается ⟺ у пресета есть var:outbound. Критерий
   строгий и единый: наличие var = явный опт автора шаблона «тут выбирается».
   DNS-only (FakeIP) и чистый `block-ads` (reject) picker не получают.

## Preset-cleanup: outbound-vars + ремап id

Механизм: билдер применяет выбранный outbound к пресету через
`varsValues['outbound']` (override-ветка в `preset_expand.dart`) — даже без
`@outbound`-плейсхолдера. Четыре роутинг-пресета имели захардкоженный
`outbound: direct-out` в `rule`, но БЕЗ var:outbound. После строгого гейта
(UI-правка 2) picker у них бы пропал. Правильно — дать им явный var:outbound,
раз выбор осмыслен:

- `ru-inside` — + var:outbound (часто хотят VPN в РФ, а не direct). Id не
  меняем (нет суффикса `-direct`).
- `bittorrent-direct` → **`bittorrent`** + var:outbound (торрент в отдельный
  канал).
- `private-ip-direct` → **`private-ip`** + var:outbound (LAN к удалённым
  роутерам через VPN).
- `block_unknown` → **`unknown-traffic`** (kebab-case; var:outbound уже был).
- `block-ads` — не трогаем (чистый reject, роутить нечего).

**Переименование id требует storage-миграции** (иначе сохранённые правила →
«Preset not found»). One-shot `_migrateRenamedPresetIds` (guard
`preset_ids_remapped`) переписывает `presetId` в `custom_rules`, **`varsValues`
не трогает** → выбранный юзером outbound переживает ремап (детали механизма —
STORAGE.md Migration history). Добавление var:outbound миграции значений НЕ
требует: и read-path (`presetOut`), и build-path уже читают
`varsValues['outbound']` первым; кто не трогал picker → подхватит
`default_value: "direct-out"` (поведение идентично прежнему).

## Файлы

- `app/assets/wizard_template.json`:
  - `selectable_rules[]` — новый пресет `fakeip`, ПОСЛЕ `ru-direct`, с
    hidden-var `dns_server` и `dns_rule.server: @dns_server`;
  - `ru-inside`/`bittorrent`/`private-ip` — + var:outbound, `rule.outbound:
    @outbound`; переименованы `bittorrent-direct`→`bittorrent`,
    `private-ip-direct`→`private-ip`, `block_unknown`→`unknown-traffic`;
  - `config.route.rules` — порядок изменён на `sniff → hijack-dns → resolve`
    (было `resolve → sniff → hijack-dns`);
  - `config.experimental.cache_file` — добавлен `"store_fakeip": true`.
- `app/lib/models/parser_config.dart` — геттер
  `SelectableRule.hasOutboundAffordance` (строго: есть var:outbound).
- `app/lib/screens/routing_screen.dart` + `.../widgets/custom_rule_tile.dart`
  — `showOutbound`-гейт для outbound-picker в строке правила.
- `app/lib/screens/custom_rule_edit/tabs/preset_params_tab.dart` — фильтр
  hidden-vars в редакторе пресета.
- `app/lib/services/settings_storage/sources_rules.dart` — миграция
  `_migrateRenamedPresetIds` + маппинг `_renamedPresetIds`.
- `app/lib/services/settings_storage.dart` — static-обёртка
  `migrateRenamedPresetIds` + guard-ключ `preset_ids_remapped`.
- `app/lib/main.dart` — вызов миграции в init (до seed дефолтов).
- `app/test/services/builder/preset_expand_test.dart` — тесты вливания
  fakeip-сервера + `hasOutboundAffordance`.
- `app/test/migration/preset_id_remap_test.dart` — тесты ремапа id (сохранение
  varsValues, идемпотентность, не-трогание чужих пресетов).
- `docs/TEMPLATE.md` — матрица пресетов (новые id + outbound-vars) + раздел
  «Магические переменные пресетов» + порядок route.rules + store_fakeip.
- `docs/STORAGE.md` — migration history + guard-ключ `preset_ids_remapped`.

## Связано

- §229 (техдолг, ВЫПОЛНЕН 2026-07-26) — one-shot миграция preset_id удалена,
  guard-ключ `preset_ids_remapped` сохранён. Список файлов выше описывает
  состояние на момент §228:
  [`229-remove-preset-id-migration.md`](229-remove-preset-id-migration.md).
- §121 (routing = король над DNS; там же зафиксировано «independent_cache не
  генерируем»).
- Пресет `ru-direct` (порядок относительно него критичен).
- §227 (IPv6 в туннеле — `strategy: prefer_ipv6`; FakeIP выдаёт и AAAA-фейки,
  конфликта нет — фейки роутятся, реальный резолв внутри туннеля).
