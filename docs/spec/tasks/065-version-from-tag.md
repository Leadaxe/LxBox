# 065 — Version from git tag (single source of truth, no manual bumps)

| Поле | Значение |
|------|----------|
| Статус | Done (v1.8.2) |
| Дата | 2026-05-12 |
| Связанные | §040 backup (использует `source_app_version`), §036 update check (compares versionName with GitHub release tag). Доп. контекст — v1.8.0 hotfix incident (см. v1.8.1 release notes). |
| Триггер | После v1.8.0 hotfix v1.8.1 версия всё ещё дублировалась в `pubspec.yaml` + `about_screen.dart _version` const + git tag. CI consistency check ловил расхождения, но **bump всё равно ручной в 2 файлах + commit**. Юзер: «должно быть всё из тега и без лишних commit'ов». |

## Цель

Сделать git tag **единственным источником правды для версии**. Никаких bump'ов pubspec/dart в репо при release-flow. CI и local build script переписывают `pubspec.yaml` `version:` line перед `flutter build` — на release tag in CI, на `git describe` локально.

## Не в скопе

- Перенос versionCode в semver-вычисление (`X*10000+Y*100+Z`) — оставляем `git rev-list --count HEAD` (monotonic с commits, прозрачно).
- Auto-tag из CI на push to main — нет, тег по-прежнему ручной (`git tag vX.Y.Z`).

---

## Что было

### Старая модель (до v1.8.2)

```
┌─────────────────────────┐    ┌──────────────────────────────┐    ┌─────────────────┐
│ app/pubspec.yaml        │    │ app/lib/screens/             │    │ git tag         │
│ version: 1.8.1+34       │    │ about_screen.dart            │    │ v1.8.1          │
│ (versionName, version-  │    │ static const _version =      │    │ (CI release     │
│  Code для Android)      │    │ '1.8.1';                     │    │  trigger)       │
└─────────────────────────┘    └──────────────────────────────┘    └─────────────────┘
        ↑ должно совпадать       ↑ должно совпадать                  ↑ должно совпадать
        с tag                    с pubspec
```

При release:
1. Bump pubspec → 1.8.2+35
2. Bump about_screen `_version` → '1.8.2'
3. Commit «chore(release): bump 1.8.2»
4. Merge develop→main
5. Tag v1.8.2
6. Push tag

Если забыл (1) или (2) — версия в UI неправильная. v1.8.0 ▼: забыл (2), `_version` остался '1.7.0', UpdateChecker показал «v1.8.0 available» на v1.8.0 build. v1.8.1 ▼: добавил CI consistency check как guard (валидация, не fix).

### Почему это плохо

- **3 источника правды** (pubspec, dart const, tag) → 3 места для рассинхронизации
- **Каждый release требует «chore(release): bump» commit** → шум в истории, plus ошибки человеческие
- **CI consistency check** ловил, но **не выводил** — bump всё равно manual

---

## Что стало

### Новая модель (v1.8.2+)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ git tag vX.Y.Z  ← единственный source of truth                             │
└────────────────┬────────────────────────────────────────────────────────────┘
                 │ derive
                 ↓
┌─────────────────────────┐    ┌──────────────────────────────┐
│ versionName = X.Y.Z     │    │ versionCode = N              │
│ from `${tag#v}`         │    │ from `git rev-list --count   │
│                         │    │             HEAD`            │
└─────────┬───────────────┘    └─────────┬────────────────────┘
          │                              │
          └──────────┬───────────────────┘
                     │ inject sed-in-place
                     ↓
          ┌──────────────────────┐
          │ pubspec.yaml         │
          │ version: X.Y.Z+N     │  ← эфемерно перед `flutter build`
          └──────────┬───────────┘
                     │ flutter compiles
                     ↓
          ┌──────────────────────┐
          │ Android APK          │
          │ versionName=X.Y.Z    │
          │ versionCode=N        │
          └──────────┬───────────┘
                     │ PackageInfo.fromPlatform()
                     ↓
          ┌──────────────────────┐
          │ VersionInfo.I.init() │  ← в main() перед runApp
          │ .version → "X.Y.Z"   │  ← sync getter для всего UI
          └──────────────────────┘
```

`pubspec.yaml` в репо навсегда удерживается как `version: 0.0.0-dev+0` placeholder. CI и `build-local-apk.sh` его временно переписывают.

### Файлы изменены

| Файл | Что |
|---|---|
| `app/lib/services/version_info.dart` | NEW — singleton с `init()` async loader + sync `version`/`buildNumber` getter'ы. |
| `app/lib/main.dart` | `await VersionInfo.I.init()` перед `runApp`. |
| `app/lib/screens/about_screen.dart` | Удалён `static const _version` + `versionString` alias. Display через `VersionInfo.I.version`. |
| `app/lib/screens/home_screen.dart` | 4 occurrence'а `AboutScreen.versionString` → `VersionInfo.I.version` (hydrate, maybeCheck, "you have v…" text). |
| `app/lib/screens/app_settings_screen.dart` | 1 occurrence → `VersionInfo.I.version`. `import 'about_screen.dart'` удалён (был unused после). |
| `app/lib/services/debug/handlers/action.dart` | 1 occurrence в `/action/check-updates` handler → `VersionInfo.I.version`. |
| `app/pubspec.yaml` | `version: 1.8.1+34` → `0.0.0-dev+0` (placeholder, никогда не меняется при release-flow). |
| `.github/workflows/ci.yml` | **Удалён** «Version consistency check» (больше нечего сверять). **Добавлен** «Inject release version» в `android` job перед `flutter pub get` — sed pubspec.yaml из `needs.meta.outputs.version` + `git rev-list --count HEAD`. `fetch-depth: 0` в Checkout для доступа к full history. |
| `scripts/build-local-apk.sh` | Derive versionName из `git describe --tags --abbrev=0` (или `X.Y.Z-dev.N` если есть commits since tag); versionCode = `git rev-list --count HEAD`; sed pubspec.yaml in-place; `trap "git checkout -- app/pubspec.yaml" EXIT` для revert. |
| `docs/RELEASE_PROCESS.md` §2.2 | Переписан под «tag = single SoT, никаких pubspec/dart bump'ов». §2.3 — commit message теперь «docs(release): vX.Y.Z notes» без `bump to X.Y.Z+N`. |

---

## Release-flow до vs после

| Шаг | До v1.8.2 (5 файлов в release commit) | После v1.8.2 (только docs) |
|---|---|---|
| Pre-flight | analyze + test + smoke local build | analyze + test + smoke local build (script сам derive'ит версию) |
| Bump pubspec.yaml | ✋ manual edit `1.8.1+34 → 1.8.2+35` | — (placeholder остаётся) |
| Bump about_screen.dart `_version` | ✋ manual edit `'1.8.1' → '1.8.2'` | — (нет такой константы) |
| CHANGELOG | manual entry `## [1.8.2]` | manual entry `## [1.8.2]` |
| docs/releases/vX.Y.Z.md | manual draft | manual draft |
| RELEASE_NOTES.md | manual mirror | manual mirror |
| DEV_REPORT chronicle | manual row | manual row |
| Commit | `chore(release): bump X.Y.Z` (5+ файлов) | `docs(release): vX.Y.Z notes` (3 файла: CHANGELOG/release-notes/DEV_REPORT) |
| Merge develop→main | same | same |
| Tag + push | `git tag vX.Y.Z; git push origin vX.Y.Z` | same |
| CI | analyze + test + (consistency check) + build + release | analyze + test + (inject version step) + build + release |

---

## Local dev quirk

При `flutter run` (для dev) Pubspec остаётся `0.0.0-dev+0` если не запускать `build-local-apk.sh`. App покажет `v0.0.0-dev` в About screen. Это **намеренно** — явный signal «это dev session, не release». Если нужна реальная версия в dev:
```bash
scripts/build-local-apk.sh   # derive'ит + inject + revert
```

UpdateChecker для `0.0.0-dev` сравнит с latest GH tag и предложит «v1.8.2 available» — что technically valid, но для dev сессии может быть raздражающим. **Не fix'ил пока** — если будет проблема, добавим guard `if version.contains('-dev') skip update check`.

---

## Тестирование (verified on device)

После tagged release v1.8.2:
1. CI собрал APK с `versionName=1.8.2`, `versionCode=N` (= commits count HEAD на момент tag)
2. `adb install -r LxBox-v1.8.2-arm64-v8a.apk` — поверх v1.8.1
3. `dumpsys package com.leadaxe.lxbox | grep version` → `versionName=1.8.2 versionCode=N`
4. App → Settings → About → показывает `v1.8.2`
5. UpdateChecker → silent (latest tag == current version)
6. Debug API `/state` показывает `app_version: 1.8.2+N`
7. Backup export `source_app_version` → `1.8.2+N`

Все surfaces consistent — нет разрыва UI vs APK.

---

## Risks

| Риск | Митигация |
|---|---|
| Tag и pubspec в репо расходятся | CI всё равно overwrite'ит при release. Local build тоже использует git, не pubspec. Pubspec в репо — placeholder без значения. |
| versionCode разные между local и CI build при тех же commits | Нет: оба используют `git rev-list --count HEAD`, дают тот же результат. |
| Rebase/squash меняет commit count | Tag pinning — после `git tag` commit history до tag'а freeze'ится. Если rebase до tagged commit'а — нужно retag. Это уже было правилом. |
| `flutter run` в dev sessions показывает `0.0.0-dev` | Намеренно. Hint для dev. Если раздражает — запускать через `build-local-apk.sh` для proper version. |
| CI step «Inject release version» fail'нется | Шаг runs after `Checkout` с `fetch-depth: 0`, до `flutter pub get`. Если sed упадёт — Flutter получит pubspec в нечитаемом state, и pub get fail'нется. `set -euo pipefail` в bash. |

---

## Зависимости

- `package_info_plus` — уже в `pubspec.yaml` (используется backup, device handler).
- Никаких новых packages.
