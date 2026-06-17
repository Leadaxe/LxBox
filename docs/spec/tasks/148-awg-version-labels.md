# 148 — Лейблы уровня AWG: `awg1.5` (i1) + masquerade-суффикс `+` (ip/id/ib)

| Field | Value |
|------|----------|
| Status | Implemented |
| Started | 2026-06-18 |
| Trigger | Subtitle/variant-фильтр (§102/§103) различал только `awg` / `awg2`, причём весь набор `i1`–`i5` падал в `awg2`. По **официальному версионированию AmneziaWG** (у Amnezia это явные версии формата конфига): signature-пакеты `i1`–`i5` (CPS) — это 1.5 (водораздел 1.0→1.5 = появление `I1`); 2.0 — динамика: ranged-заголовки `h1`–`h4` (`"N-M"`, §112) + transport-padding `s3`/`s4`. Плюс masquerade-sugar `ip`/`id`/`ib` (§143) — надстройка над любой базой, которую полезно видеть отдельно. |
| Related | [§097](../features/097%20awg2-amneziawg2/spec.md) (поля Awg, эмит/парс); [§102](102-node-subtitle-transport-security.md)/[§103](103-variant-filter.md) (subtitle + variant-фильтр); [§143](143-warp-masquerade-id-ip-ib.md) (masquerade ip/id/ib); [§112](112-ranged-magic-headers.md) (ranged h1–h4) |
| Files touched | `models/config_node.dart` (`_deriveSecurity` + doc), `screens/home/node_list_presenter.dart` (`_variantOrder` + `_variantRank`), `test/models/config_node_test.dart`, `docs/PROTOCOLS.md` |

## Семантика детекции

Лейбл считается **структурно по сырому JSON** (до валидации ядром), в `ConfigNode._deriveSecurity` — один раз на парс конфига (eager). База — по старшему присутствующему маркеру; затем суффикс.

### База (приоритет старший → младший, ранний return на первом совпадении)

По официальным версиям AmneziaWG:

| Лейбл | Версия | Условие |
|-------|--------|---------|
| `awg2` | 2.0 | ranged-заголовок `h1`–`h4` (значение `"N-M"`, §112) **или** `s3`/`s4` |
| `awg1.5` | 1.5 | любой signature-пакет `i1`–`i5` (и нет awg2-маркеров) |
| `awg` | 1.0 | базовое 1.0-поле: `jc`/`jmin`/`jmax`/`s1`/`s2`/одиночные `h1`–`h4` |
| `null` | — | ни одного AWG-поля → обычный WG |

Реальный 2.0-экспорт может нести одновременно ranged-H, `s3`/`s4` и `i*` → `awg2` (старший выигрывает). Ranged-заголовок детектится в сыром JSON по `String`-значению с дефисом (одиночный приходит числом/строкой без дефиса — критерий тот же, что `Awg._parseHeader`).

### Суффикс `+` (masquerade, §143)

Если присутствует хоть одно из `ip` / `id` / `ib` — к базе дописывается `+`:
`awg+` / `awg1.5+` / `awg2+`.

> На уровне ядра (009) `ip/id/ib` **взаимоисключающи с явным `i1`** — ядро само разворачивает их в `i1` и отвергает оба сразу. Поэтому реальный конфиг `awg1.5+` (i1 + ip) ядро не примет. Но лейбл считается по сырому JSON до валидации, поэтому суффикс проверяется независимо от базы — корректность лейбла не зависит от того, дойдёт ли конфиг до ядра.

## Изменения

### `_deriveSecurity` ([config_node.dart](../../../app/lib/models/config_node.dart))
Было: `awg2Keys = {s3,s4,i1..i5}` → `awg2`, иначе `numKeys` → `awg`. Стало три ветки: `awg2` = `_hasRangedHeader(raw)` (h1–h4 = String с `-`) или `s3`/`s4`; `awg1.5` = `_signatureKeys = {i1..i5}`; `awg` = `Awg.numKeys`. После выбора базы — проверка `{ip,id,ib}` → суффикс `+`. Добавлены хелперы `_hasRangedHeader` и константа `_signatureKeys` (подмножество `Awg.strKeys` без masquerade-sugar).

### `_variantOrder` / `_variantRank` ([node_list_presenter.dart](../../../app/lib/screens/home/node_list_presenter.dart))
`_variantOrder` += `awg1.5` между `awg` и `awg2`. `_variantRank` отбрасывает trailing `+` и ранжирует по базе — `awgN` и `awgN+` стоят рядом, новые `+`-варианты не валятся в хвост.

### Потребители (без правок)
Subtitle ноды ([node_list.dart:243](../../../app/lib/screens/home/widgets/node_list.dart)) и variant-фильтр читают `securityLabel`/`variantsOfTag` напрямую — новые лейблы и суффикс прорастают автоматически.

## Тесты
`config_node_test.dart` — endpoints дополнены кейсами: `awg2h`(ranged h1=`"10-20"`), `awg2s`(s3/s4), `awg15i1`(i1), `awg15i2`(i2→тоже 1.5), `awg2over`(i1+ranged-H→awg2), `awg1`(база+одиночный h1=1), `awgp`(ip→awg+), `awg15p`(i1+id→awg1.5+), `awg2p`(s3+ib→awg2+). Два теста: база-детекция и суффикс.
