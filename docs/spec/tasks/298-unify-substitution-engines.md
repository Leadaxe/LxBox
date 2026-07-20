# §298 — Слить два движка подстановки vars (DEFER, RISKY)

**Тип:** cross-cutting refactor (фича [§291](../features/291%20layered-architecture-facades/spec.md)) · **Статус:** spec — **отложено indefinitely** · **Размер:** M · **Риск:** высокий blast-radius

Два движка подстановки: `substituteVars` (`preset_expand.dart:531`, return-value)
и `_substituteVars` (`build_config.dart:773`, mutate-in-place). Одна
концептуальная работа, две реализации, которые могут разъехаться (см. память
[[project_two_substitution_engines]]).

**Оговорка ресёрча:** «два движка» — во многом non-issue: под ними один `walk()`
-core с двумя тонкими call-convention'ами. Слияние трогает build-путь —
**высокий blast-radius на device-verified генерации конфига**.

## Решение (когда/если)

Свести к одному walker'у с явной политикой mutate-vs-return. **Только если**
конкретный баг вынудит (drift между движками) — иначе не трогать.

## Приёмка (когда возьмём)

- Один walker, обе call-convention как тонкие обёртки.
- Полная параллель на config-generation тестах (никакого drift).

Пока: **defer.** Отмечено в §291 как RISKY.
