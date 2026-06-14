# 125 — Local versionCode согласовать с релизным (split-per-abi)

| Поле | Значение |
|------|----------|
| Статус | Реализовано |
| Дата старта | 2026-06-14 |
| Триггер | После релиза v2.2.0: локальная dev-сборка (vc ~610) не встаёт поверх релизного arm64-APK (vc 2612) — downgrade. Каждый dev-install требовал ручного бампа versionCode. |
| Связанные | [RELEASE_PROCESS.md §2.2](../../RELEASE_PROCESS.md) (версия из git tag); [§065](065-version-from-tag.md), [§066](066-pubspec-sync-hook.md) (versionCode из git rev-list) |
| Затронутые файлы | `scripts/build-local-apk.sh`, `scripts/install-apk.sh`, `docs/RELEASE_PROCESS.md` (если нужна заметка) |

## Проблема

`versionCode` локальной и CI-сборки **расходятся на множитель ABI**, потому что собираются разными командами:

| Сборка | Команда | versionCode (arm64) |
|---|---|---|
| **CI релиз (arm64)** | `flutter build apk --release --split-per-abi` | `1000 × abiIndex + git-count` = **2612** |
| **build-local-apk.sh** | `flutter build apk --release --target-platform android-arm64` | `git-count` = **610** |

При `--split-per-abi` Flutter Gradle plugin применяет ABI-множитель к versionCode:

| ABI | abiIndex | формула | versionCode (base=612) |
|---|---|---|---|
| armeabi-v7a | 1 | 1000×1 + 612 | 1612 |
| arm64-v8a | 2 | 1000×2 + 612 | **2612** |
| x86_64 | 4 | 1000×4 + 612 | 4612 |
| universal (без split) | — | 612 | 612 |

`build-local-apk.sh` собирает **single-ABI** (`--target-platform android-arm64` + `LXBOX_ABI_FILTER`), **без** `--split-per-abi` → множитель не применяется → versionCode = чистый `git-count` (~610). Это **ниже** релизного arm64 (2612) → `adb install -r` отклоняет как downgrade (`INSTALL_FAILED_VERSION_DOWNGRADE`), и приходилось вручную бампать pubspec при каждой dev-установке поверх релиза.

## Решение

**Перевести `build-local-apk.sh` на `--split-per-abi` arm64** — точно как CI. Flutter сам применит arm64-множитель → локальный versionCode попадёт в тот же диапазон (2xxx), что и релиз. Никакой ручной арифметики; если Flutter когда-нибудь поменяет множитель, local и CI поменяются синхронно.

**`LXBOX_ABI_FILTER` убирается** — `--split-per-abi` сам задаёт `splits.abi.filters`, а они **конфликтуют** с `ndk.abiFilters` («Conflicting configuration: arm64-v8a in ndk abiFilters cannot be present when splits abi filters are set»). Сужение до одного arm64 даёт `--target-platform android-arm64`: на выходе ровно `app-arm64-v8a-release.apk` (~29 МБ, один ABI, без раздувания).

### Изменения

1. **`scripts/build-local-apk.sh`**: `flutter build apk --release --target-platform android-arm64` → `flutter build apk --release --split-per-abi --target-platform android-arm64`; **убрать `export LXBOX_ABI_FILTER=arm64-v8a`** (конфликтует со split).
2. **`scripts/install-apk.sh`**: путь к release-APK меняется с `app-release.apk` на `app-arm64-v8a-release.apk` (`--split-per-abi` пишет per-ABI имена, не `app-release.apk`). Debug-путь (`--debug` без split) не трогаем — там `app-debug.apk` остаётся.

### Имена выходных файлов

| Команда | Выходной файл |
|---|---|
| `flutter build apk --release` (universal) | `app-release.apk` |
| `flutter build apk --release --split-per-abi` (arm64) | `app-arm64-v8a-release.apk` |
| `flutter build apk --debug` | `app-debug.apk` |

## Acceptance

- [ ] `build-local-apk.sh` собирает `app-arm64-v8a-release.apk` с versionCode в диапазоне 2xxx (= `2000 + git-count`).
- [ ] `install-apk.sh` (release) находит и ставит per-ABI APK.
- [ ] Локальная сборка встаёт **поверх релиза того же ABI** через `adb install -r` без downgrade-ошибки (когда git-count локально ≥ релизного).
- [ ] Debug-флоу (`install-apk.sh --debug`) не сломан.

## Замечания

- **Single-ABI build остаётся arm64-only** — `LXBOX_ABI_FILTER` + `--split-per-abi` вместе дают один arm64-APK, не три (проверить, что `--split-per-abi` уважает `ndk.abiFilters` и не собирает armeabi/x86).
- На устройстве после релиза v2.2.0 стоит arm64 vc=2612. Локальная сборка поверх требует `git-count` ≥ 612 (т.е. новые коммиты) — иначе тот же vc, `install -r` пройдёт (равный vc допустим), но при меньшем — downgrade. Для dev-итераций это норма: каждый коммит растит count.
