[English](direction-groups-in-config.md) · [Русский](direction-groups-in-config.ru.md)

# Группы Направления в конфиге — как Направление становится селектором и auto-двойником

Каждое включённое Направление пишется в конфиг sing-box группой `selector`, а с «Include auto»
— ещё и двойником `urltest` с именем `<tag>-auto`; Default traffic становится `route.final`.

| Поле | Значение |
|------|----------|
| Фича | [026-DIRECTIONS](../FEATURE.ru.md) |
| Обещания | P8 P9 P10 P11 P12 P13 P14 |
| Состояние | ✅ написана по коду, 2026-09-29 |

## Что делает

Превращает сохранённый список в группы конфига в порядке списка. Для каждого Направления
сборка берёт узлы, прошедшие фильтр, вычитает цепочки, проходящие через это Направление,
ставит служебные опции вперёд и пишет `selector`; если галка auto включена и пул не пуст,
первым пишется двойник `urltest`, и он становится умолчанием селектора. Состав общий у
селектора и двойника, кроме групп (узлов автовыбора, свёрток источников) — они входят только
в селектор. Default traffic пишется как `route.final`.

## Параметры

| Ручка | Значения | Умолчание | Ключ ядра |
|---|---|---|---|
| Node filter (regex), Exclude matching | регистронезависимый regex по итоговым тегам узлов | пусто = все | состав `outbounds` |
| Default (regex) | первый совпавший член | пусто | `selector.default` |
| Include direct-out / Include block / Other directions | опции | выкл / выкл / нет | голова `outbounds` |
| Interrupt connections on switch | вкл/выкл | вкл | `selector.interrupt_exist_connections` |
| Include auto (urltest) | вкл/выкл | выкл | группа `<tag>-auto` |
| Test URL / Interval / Tolerance (ms) / Idle timeout | — | `cp.cloudflare.com/generate_204` / `15m` / 50 / `30m` | `url`, `interval`, `tolerance`, `idle_timeout` |
| Interrupt connections (двойник) | вкл/выкл | выкл | `urltest.interrupt_exist_connections` |
| Mode: Fastest · Load balance | — | Fastest | `mode: round_robin` + `balancer{}` только для Load balance |
| Pool size / Pool tolerance (ms) / Sticky session by | ≥ 1 / 0–65535 / набор | 3 / 0 / process + domain | `balancer.pool`, `pool_tolerance`, `sticky_hash` |
| Default traffic | `direct` · Направление · `block` | `vpn-1` | `route.final` |

`tolerance` и `pool_tolerance` клэмпятся в 0–65535 при чтении, сохранении и в редакторе;
`pool` — в ≥ 1. «Passive health check» из Settings попадает в каждый двойник как
`passive_check`. Сохранённое Направление без `interval` читается как `5m`, новое получает
`15m` (272).

## Входы / Выходы

**Входы:** список Направлений; итоговые теги узлов всех источников (после разрешения detour,
свёрток и цепочек); позиции цепочек; имена эмитированных свёрток (они тоже законные цели
`include`); Passive health check.
**Выходы:** `outbounds[type=selector]` на каждое включённое Направление (и `vpn-1` всегда);
`outbounds[type=urltest]` на каждый двойник; `route.final`; предупреждения сборки; список
Направлений без узлов для снекбара главного экрана.

## Правила и инварианты

- **Порядок состава нормативен:** `<tag>-auto`, `direct-out`, `block`, теги «Other
  directions», затем узлы в порядке конфига. Первая опция — неявное умолчание селектора, и
  узел подписки не должен молча стать умолчанием Направления, собранного из опций.
- Тег `include` входит, только если то Направление включено и уже эмитировано выше (или это
  эмитированная свёртка); ссылка вниз, на выключенное или отсутствующее вычёркивается с
  предупреждением «option … dropped — it must be another direction listed above this one
  (and enabled)». Направление никогда не включает свой двойник или само себя.
- Направление не берёт цепочку, проходящую через него, в том числе транзитивно
  ([006-DETOUR_AND_BALANCE · P9](../../006-DETOUR_AND_BALANCE/FEATURE.ru.md#обещания));
  вычет не вменяется фильтру.
- Пустой состав (фильтр ничего не поймал или инверсия исключила всё) → состав `[block,
  direct-out]`, `default: block`, предупреждение «node filter matched no nodes — traffic is
  blocked (default)»; при включённом `Include direct-out` без узлов предупреждение говорит
  «traffic goes direct (no VPN hop)». Невалидный regex → все узлы. Пустой фильтр при нуле
  узлов (нет подписки) — не предупреждение.
- `default` — первый член, совпавший с Default regex; не член или нет совпадения — ключа нет,
  ядро берёт первую опцию; при эмитированном двойнике и без явного умолчания умолчание —
  двойник.
- Двойник эмитится только при включённой галке и непустом пуле узлов-не-групп: `urltest`
  без членов — fatal ядра. «Fastest» не пишет ни `mode`, ни `balancer`; «Load balance»
  пишет оба, пустой набор липкости — как `["none"]`
  ([006-DETOUR_AND_BALANCE · P13](../../006-DETOUR_AND_BALANCE/FEATURE.ru.md#обещания)).
- `route.final` на отсутствующее Направление, выключенное или на неэмитированный двойник →
  `vpn-1` с предупреждением «Route final … no longer exists — switched to vpn-1»;
  `direct-out`, `block` и живой двойник — законные цели.
- Теги каждого Направления и его двойника резервируются до раздачи тегов узлам, поэтому узел
  никогда не сталкивается с Направлением.
- `interval` больше `idle_timeout` поднимается санитайзером сборки и подсказывается в
  редакторе ([009-NODE_HEALTH · P7](../../009-NODE_HEALTH/FEATURE.ru.md#обещания)).

## Границы

- Хранение, лечение ссылок и правила тегов — [direction-model.md](direction-model.ru.md).
- Параметры замера двойника, массовый пинг и переселект —
  [direction-health.md](direction-health.ru.md); режимы балансировки, detour-кольца —
  [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.ru.md).
- Приложение клэмпит `pool_tolerance` в 65535, а ядро отвергает значения выше 15000 — такой
  конфиг не стартует (588).
- Свёртки источников и группы подписок — группы другого рода —
  [007-NODE_LIST](../../007-NODE_LIST/FEATURE.ru.md).

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [125F](../../../tasks/125F-configurable-channels/spec.md) | РЕАЛИЗОВАНО | Regex-фильтр на Направление, default, деградация `route.final` |
| 2 | [141](../../../tasks/141-deep-code-audit-hardening.md) | — | `default` обязан быть членом; Default regex |
| 3 | [197](../../../tasks/197-channel-node-filter-invert.md) | РЕАЛИЗОВАНО | Инверсия фильтра узлов |
| 4 | [201](../../../tasks/201-block-outbound-for-channels.md) | РЕАЛИЗОВАНО | Опция `block`; fallback `[block, direct-out]` |
| 5 | [208](../../../tasks/208-urltest-balancer-round-robin.md) | РЕАЛИЗОВАНО | Режим Load balance, `balancer{}` |
| 6 | [272](../../../tasks/272-idle-suspend-urltest-energy.md) | РЕАЛИЗОВАНО | `passive_check`, interval `15m` у новых двойников |
| 7 | [301](../../../tasks/301-regex-filter-case-insensitive.md) | ✅ реализовано | Фильтры регистронезависимы |
| 8 | [393F](../../../tasks/393F-directions/spec.md) | released v2.21.0 | `include`, нормативный порядок, двойник как умолчание, цепочки через Направление |
| 9 | [442](../../../tasks/442-urltest-interval-idle-pair.md) | Released v2.24.0 | Пара `interval`/`idle_timeout`, подсказка в редакторе |
