# §210 — libbox rc.14 → rc.15: sticky_hash sentinel ["none"] + фиксы балансировщика

> **СТАТУС: РЕАЛИЗОВАНО (29.06.2026).** Ветка `feat/urltest-balancer-208`.
> 1402 теста, analyze чист, javap rc.15 OK. НЕ device-verified.

## Контекст — ядро rc.15 чинит наш device-баг

На устройстве (отладка §208) видели **перекос трафика в один узел** (89/3/2/1) и
расхождение «один (process,domain) → 2 узла». Ядро rc.15 (SPEC 019) исправило
ровно эти баги — наш перекос был **багом ядра**, не нашего билдера:

1. **Sticky `domain` всегда пустой → весь трафик в один узел.** Роутер
   перезаписывает `metadata.Destination` ДО балансировщика → `destination.Fqdn`
   пуст. Фикс: читать `metadata.Domain` (fallback на Fqdn для direct). Это и был
   наш «UDP с пустым Fqdn», но шире — затрагивал и TCP.
2. **Слоты сдвигались при health-check** (нарушение «фиксированных слотов»):
   `balancePoolFirstLive`/`planTolerantPool`/manual-urltest чинены на
   fixed-length copy + сохранение индексов.
3. **`sticky_hash: []` молча игнорировался** → новый sentinel **`["none"]`**.

## Наша часть — фикс контракта sticky_hash (BREAKING)

**Корень (из кода ядра `urltest_balance_lx.go:72-75` + `option/group.go:31`):**
конфиг проходит через `badjson.UnmarshallExcludedContext`, который **ре-маршалит**
структуру → пустой JSON `[]` схлопывается в `nil`, неотличимо от «поле опущено».
Поэтому различить nil-vs-`[]` на проде НЕЛЬЗЯ. Контракт ядра rc.15:

| `sticky_hash` | результат |
|---|---|
| опущен / `[]` | дефолт `["process","domain"]` (липкость ВКЛ) |
| `["none"]` | липкость ВЫКЛ (чистая ротация) |
| `["none", X]` | **ошибка старта** («none» must be only component) |
| непустой набор | липкость по компонентам |

**Наш билдер (§208) эмитил `sticky_hash: []` для «выкл»** → на rc.15 это даёт
ДЕФОЛТНУЮ липкость, а не выключение. Фикс: пустой `stickyHash` → `["none"]`.

```dart
// build_config.dart (round_robin balancer)
final sticky = a.stickyHash.isEmpty
    ? const ['none']                          // sentinel: липкость выкл
    : a.stickyHash.map((k) => k.wire).toList();
```

Безопасность sentinel: `StickyHashKey` enum не содержит `none` → юзер не может
случайно выбрать компонент-коллизию. `["none"]` появляется ТОЛЬКО из пустого
набора.

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| пин | `app/android/libbox.version` | `rc.14` → `rc.15` |
| AAR | `app/android/app/libs/libbox.aar` | fetch (SHA256 OK, gitignored) |
| билдер | `services/builder/build_config.dart` | пустой stickyHash → `["none"]` |
| тест | `test/builder/channel_groups_test.dart` | кейс пустого набора ждёт `["none"]` |

**javap rc.15:** CommandClient API идентичен rc.14
(`getPool`/`getGroups`/`urlTestOutbound`/`PoolSlot{getSlot/getTag/getDelay}`) —
native НЕ трогаем. Релиз-ноуты: «CommandClient: no changes».

## НЕ трогаем

- Модель `ChannelAuto.stickyHash` (`List<StickyHashKey>`) — пустой список как был.
  `["none"]`-маппинг живёт ТОЛЬКО в билдере (граница с ядром). UI/storage не
  знают про sentinel — снятие всех чипов = пустой список = «выкл», как и раньше.
- enum `StickyHashKey` — без `none` (sentinel не пользовательский компонент).

## Device-verify (после фиксов ядра)

1. Канал в Load balance, дефолтный sticky → трафик размазан по слотам, домен
   держится на одном узле (фикс #1 — перекоса больше нет).
2. `/pool` несколько замеров → слоты держат номера (фикс #2).
3. Снять все sticky-чипи → `/config` показывает `sticky_hash:["none"]`, трафик
   крутится по чистой ротации (домен может прыгать между узлами — это норма при
   выключенной липкости).

## Связанные

- [§208 round-robin balancer](208-urltest-balancer-round-robin.md) — здесь
  эмиссия balancer; device-перекос = ядровый sticky-domain баг (теперь фикшен).
- [§205 rc.12](205-libbox-rc12-cold-urltest.md) — предыдущий бамп ядра (паттерн).
- ядро SPEC 019 (`sing-box-lx/SPECS/019-URLTEST_MODE_STICKY/SPEC.md`) — журнал п.1
  (`["none"]` sentinel, почему не `[]`).
