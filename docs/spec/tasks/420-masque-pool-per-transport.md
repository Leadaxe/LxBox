# 420 — MASQUE-пул по транспортам: общие хосты, h3-only адреса, исключения для h2

| Поле | Значение |
|------|----------|
| Статус | Done (unit) · DEVICE-PENDING (визард на телефоне: combobox по транспорту, сброс хоста) |
| Дата старта | 2026-09-05 |
| Дата завершения | 2026-09-05 |
| Коммиты | см. ветку задачи |
| Связанные spec'ы | [tasks/418](418-warp-api-host-failover.md) (замеры), [tasks/305](305-masque-endpoint-h2-pool-and-override.md), [tasks/386](386-warp-endpoint-preset-combobox.md), [tasks/284](284-warp-endpoint-scanner.md), [features/130](../features/130%20masque-warp-transport/spec.md) |

## Повод

Замер §418 (живые туннели через sing-box-lx, 05.09.2026) показал, что в
блоках `162.159.198.0/24` и `162.159.199.0/24` транспорт зависит от адреса:

| Адрес | h3 (QUIC/UDP) | h2 (HTTP/2/TCP) |
|---|---|---|
| `.1` | да | нет — по TCP 443 обычный CDN-edge, ядро: `remote endpoint has a different …` |
| `.2` | да | да |
| `.0`, `.3` и далее | нет — `CRYPTO_ERROR 0x12a` | да |

Проверено на 198.0/1/2/3/77 и 199.0/1/2/3/120. Это выборка, не весь /24,
поэтому закономерность «по последней цифре» в файл НЕ зашита — только явные
списки.

## Что было не так

- `hosts_preset` один на все транспорты и содержал `.198.1`/`.199.1`. Выбор
  h2 + такой хост = мёртвый узел; в `auto` фолбэк на h2 падал.
- `recommended_host` = `consumer-masque.cloudflareclient.com`. У имени нет ни
  A, ни AAAA (NOERROR с пустым ответом на 1.1.1.1/8.8.8.8/77.88.8.8) — как SNI
  оно живёт, как `server` узла резолвиться не может. Текст combobox уходит в
  `server` как есть → рекомендуемый пункт был мёртвым.
- h2-рандом (кубик и генератор §284) шёл по всему блоку и с шансом 1/256
  выдавал `.1`.
- Смена транспорта в визарде пересинхронизировала только порт; выбранный хост
  оставался.

## Что стало

**Asset `app/assets/warp_endpoints.json`**, секция `masque`:

```json
"masque": {
  "hosts_preset": ["162.159.198.2", "162.159.199.2"],
  "recommended_host": "162.159.198.2",
  "h3": { "hosts_extra": ["162.159.198.1", "162.159.199.1"], "ports": [...] },
  "h2": { "v4_cidr": ["162.159.198.0/24", "162.159.199.0/24"],
          "exclude": ["162.159.198.1", "162.159.199.1"], "ports": [...] },
  "recommended_sni": "consumer-masque.cloudflareclient.com",
  "sni_pool": [...]
}
```

| Ключ | Смысл |
|---|---|
| `hosts_preset` | адреса, где живут оба транспорта; показываются при любом выборе |
| `recommended_host` | элемент `hosts_preset`; `162.159.198.2` — его же отдаёт регистрация |
| `h3.hosts_extra` | h3-only адреса, добавляются к списку только для h3 |
| `h2.v4_cidr` + `h2.exclude` | источник h2-рандома минус h3-only адреса |
| `h3.ports` / `h2.ports` | были `ports_h3` / `ports_h2` |

Ключи `h3_v4_cidr`, плоские `v4_cidr`, `ports_h3`, `ports_h2` из файла ушли.

**`ScanPool`** — поля `masqueH3HostsExtra`, `masqueH2Exclude` (вместо
`masqueH3V4Cidr`), производные `masqueH3Hosts` (общие + extra, без дублей),
`masqueHostsFor(network)` (`h3` → все h3-хосты; `h2`/`auto` → общие),
`randomMasqueIp(network, rng)` (h3 — из h3-хостов; h2 — блок минус exclude,
до 16 попыток, иначе null). `hasData` считает MASQUE валидным при h2-блоке
ИЛИ h3-хостах.

**Фолбэк старого формата** (JSON-override окна эксперимента §305 у людей):
`v4_cidr` → h2-блок, `ports_h3`/`ports_h2` → порты, /32-записи `h3_v4_cidr`
→ h3-хосты сверх `hosts_preset` (не-/32 отбрасываются), `hosts_preset` — как
был. Старый override работает ровно как раньше, лучше не становится.

**Генератор §284** — h3 сеется только при непустых h3-хостах (раньше при
пустом h3-списке падал на весь блок = мёртвые ноды), h2 — при h2-блоке; IP
через `randomMasqueIp`.

**Визард** — combobox «Endpoint IP» показывает `masqueHostsFor(транспорт)`;
при смене транспорта пресет-хост, которого нет в новом списке, сбрасывается
(пустое поле = endpoint регистрации, он живёт на обоих). Ручной IP не
трогаем.

## Вне задачи

- Узлы, уже созданные с `.198.1`/`.199.1` и h2/auto, не мигрируются.
- IPv6-endpoint MASQUE (`2606:4700:103::2` из регистрации) не мерился и в
  пуле по-прежнему отсутствует.
- Блок `.197` consumer-ключом отвергается на логине (§418) — в пул не входит.

## Проверка

- `flutter analyze` чисто; `test/warp`, `test/services/warp_endpoint_picker_test.dart`
  зелёные. Новые/переписанные: `scan_pool_test` (новый формат, старый фолбэк,
  `randomMasqueIp` с exclude и вырожденными пулами), `candidate_generator_test`
  (h2 не выдаёт h3-only, без h3-хостов только h2), `warp_endpoint_picker_test`
  (asset: preset/recommended/`masqueHostsFor`).
- DEVICE-PENDING: визард на CPH2411 — список по транспорту, сброс хоста при
  переключении, узел с рекомендуемым хостом поднимается.

## Docs to update

- [x] `CHANGELOG.md` — Unreleased / Changed
- [x] `docs/ARCHITECTURE.md` — ключи пула
- [x] `tasks/305`, `tasks/386` — пометка о новой раскладке
