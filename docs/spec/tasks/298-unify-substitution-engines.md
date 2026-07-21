# §298 — Слить два движка подстановки vars

**Тип:** cross-cutting refactor (фича [§291](../features/291%20layered-architecture-facades/spec.md)) · **Статус:** Реализовано (§120) — приёмка де-факто выполнена, кода не потребовалось · **Размер:** M · **Риск:** высокий blast-radius (был)

> **Уточнение диагноза (при закрытии):** «два движка, которые могут разъехаться»
> — состояние ДО §120. К моменту разбора задачи слияние **уже сделано**: под
> обоими call-convention'ами лежит один walker `walk()`
> ([`if_engine.dart`](../../../app/lib/services/builder/if_engine.dart)), а сама
> спека это предвидела («под ними один `walk()`-core»). Отдельного рефактора
> билд-пути не потребовалось — приёмка выполняется текущим кодом. Остаточная
> «двойственность» — это две тонкие обёртки и две политики резолвера (разные
> контракты, by design), а НЕ два параллельных движка. Device-verified
> генерацию конфига не трогали. См. память [[project_two_substitution_engines]].

## Что было (исходный диагноз)

Два движка подстановки: `substituteVars` (`preset_expand.dart`, return-value)
и `_substituteVars` (`build_config.dart`, mutate-in-place). Одна концептуальная
работа, две реализации, которые могли разъехаться (drift).

**Оговорка ресёрча:** «два движка» — во многом non-issue: под ними один `walk()`
-core с двумя тонкими call-convention'ами. Слияние трогало бы build-путь —
**высокий blast-radius на device-verified генерации конфига**.

## Что по факту (§120 уже свёл к одному ядру)

Единственный walker — `walk()` в
[`if_engine.dart`](../../../app/lib/services/builder/if_engine.dart). Всё
остальное — тонкие call-convention-обёртки над ним:

| Обёртка | Файл | Поверх `walk` |
|---|---|---|
| `_substituteVars` | `build_config.dart` | `walk(obj, resolve)` — отбрасывает результат (mutate-in-place) |
| `substituteVars` | `preset_expand.dart` | `walk(obj, resolver)` — возвращает результат + резолвер с drop-семантикой optional-var §033 |
| прямой `walk` + `makeResolver` | `settings_screen.dart`, `preset_on_change.dart`, `post_steps/dns_servers.dart`, тесты | зовут ядро напрямую |

Резолверы тоже общие — `makeResolver` в `if_engine.dart`. `build_config` строит
свой через `makeResolver(vars, byName)`; `preset_expand.substituteVars` строит
инлайновый резолвер лишь потому, что ему нужна **другая политика**: для
unknown-имени — keep-placeholder, для known-`null` — drop (optional-var §033).
Это не «второй движок», а вторая легитимная политика резолва одного движка.

## Приёмка — выполнена

- ✅ Один walker (`walk`), обе call-convention как тонкие обёртки.
- ✅ Полная параллель на config-generation тестах: общее ядро исключает drift
  by construction; ядро покрыто `test/builder/if_engine_test.dart`.

## Решение (если бы drift всё же всплыл)

Свести резолверы к именованным фабрикам рядом с `makeResolver` (напр.
`makePresetResolver` с keep-placeholder + drop-null). Мелкий низкорисковый
рефактор — **брать только если конкретный баг вынудит** (drift между
обёртками), иначе не трогать: две call-convention отличаются намеренно (разные
контракты mutate-vs-return и политики резолва), а не по недосмотру.

**Итог: закрыто по факту §120. Кода не потребовалось.**
