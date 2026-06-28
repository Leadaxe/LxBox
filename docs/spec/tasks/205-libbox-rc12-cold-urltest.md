# §205 — libbox rc.10 → rc.12: фикс холодного urltest Now()

> **СТАТУС: РЕАЛИЗОВАНО (28.06.2026).** Бамп пина ядра, наш код не меняется.
> Ветка `feat/conns-routing-unify-204`.

## Контекст / баг

На холодном старте urltest-группа (`vpn-1-auto`, §125 auto-двойник) отдавала
`Now() == ""`, пока первый URL-test не заполнит историю задержек. Трафик при
этом уже шёл через `Select()`-fallback (первый рабочий outbound), но UI
показывал пустой выбор: строка «Auto» на главной без `→ <сервер>`, цепочка в
профайлере обрывалась на `vpn-1-auto`. Подтверждено по Debug API (selected
пустой спустя часы аптайма) — это поведение **ядра**, не нашего UI
(`urltestNowOf`/`ccGroups`/Kotlin-сериализация корректны, §122/§125).

## Фикс (на стороне ядра sing-box-lx)

`v1.14.0-lx.1-rc.12` (SPEC 019): `urltest.Now()` cold-start fallback. Пока
`selectedOutbound*` ещё nil, `Now()` проваливается в `Select(tcp)`/`Select(udp)`
— тот же источник истины, что и dial-path (`DialContext`). Теперь группа
сообщает узел, который реально набирает, а не пустую строку. Затрагивает только
`least_test` (дефолт); `round_robin`/`ttlmap` уже отдавали последний тег.
**No data-path change** — чисто UI-facing.

## Наша часть

- Бамп пина `app/android/libbox.version`: `v1.14.0-lx.1-rc.10` → `v1.14.0-lx.1-rc.12`.
- `scripts/fetch-libbox.sh` качает AAR (SHA256 OK), кладёт в `app/android/app/libs/libbox.aar` (gitignored).
- **javap-проверка:** API CommandClient идентичен rc.10 — `OutboundGroup.getSelected()`/`getTag()`/`getType()`, `CommandClient.getGroups()`/`urlTestOutbound()` на месте. Kotlin (`BoxCommandClient.serializeGroup` читает `g.getSelected()`) и Dart (`urltestNowOf` → `group.selected`) НЕ меняются — просто получат непустой `selected` на холодную.

rc.11 (SPEC 019 load-balancing) пропущен как пин — берём сразу rc.12 (rc.11 + Now()-fallback).

## Тесты

Без кода → без unit-тестов. Верификация на устройстве: после старта строка
«Auto» сразу показывает `→ <сервер>`, профайлер-цепочка доходит до узла,
§203 «Select server» работает (urltestNow непустой).

## Связанные

- [§125 configurable-channels](../features/125%20configurable-channels/spec.md) — auto-двойник канала (urltest).
- [§203](203-select-server-on-auto.md) — Select server (зависит от непустого urltestNow — теперь работает с холодной).
- [§048 rc.10](048*) и предыдущие бампы ядра — паттерн «бамп пина + fetch + javap».
