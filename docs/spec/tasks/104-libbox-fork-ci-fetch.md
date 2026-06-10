# 104 — Ядро sing-box-lx: постоянная схема поставки AAR (local + CI)

**Дата:** 2026-06-10 · **Статус:** DONE
**Контекст:** §097 Phase 0 свапнул ядро на fork `Leadaxe/sing-box-lx`
dev-override'ом (`libs/libbox.aar` руками, gitignored; CI оставался на
Maven-libbox 1.13.11). Релиз v2.0.0 с AWG/XHTTP невозможен на стоковом ядре —
оно отвергает конфиги с AWG-полями / `transport.type=xhttp`. Fork публикует
`libbox-<ver>.aar` + `SHA256SUMS` в своих GitHub Releases (`lx-release.yml`,
теги `v*-lx.*`).

## Схема

| Кусок | Роль |
|---|---|
| `app/android/libbox.version` | **Пин версии ядра** (single source of truth), сейчас `v1.13.13-lx.5` |
| `scripts/fetch-libbox.sh [ver]` | Скачивает `libbox-<ver>.aar` из GH Releases форка, проверяет SHA256 (`SHA256SUMS`), кладёт в `app/android/app/libs/libbox.aar` + маркер `.libbox.version`. Идемпотентен (та же версия → skip) |
| `scripts/build-local-apk.sh` | Вызывает fetch перед сборкой (локальный путь) |
| `.github/workflows/ci.yml` → android job → «Fetch sing-box-lx core» | Вызывает fetch перед сборкой (CI-путь) |
| `app/android/app/build.gradle.kts` | Постоянный `implementation(files("libs/libbox.aar"))`; Maven-строка стокового libbox удалена |

`libs/` остаётся в `.gitignore` (AAR ~73MB). Воспроизводимость: версия
зафиксирована в git (пин-файл), артефакт верифицируется хешем из релиза форка.

## Обновление ядра

1. Тегнуть релиз в `sing-box-lx` (`v1.13.13-lx.N`) — `lx-release.yml` соберёт AAR.
2. Поменять `app/android/libbox.version`.
3. `./scripts/fetch-libbox.sh` + локальный smoke (AWG/XHTTP коннект).
4. Коммит пин-файла.

## Тест

Скрипт прогнан боевым обновлением lx.1 → lx.5 (см. журнал релиза v2.0.0);
повторный запуск — skip по маркеру.
