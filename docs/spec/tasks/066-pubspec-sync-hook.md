# 066 — pre-commit hook: pubspec.yaml в sync с git state

| Поле | Значение |
|------|----------|
| Статус | Released в v1.9.0 (изначально draft v1.8.3 — не tag'нут) |
| Дата | 2026-05-12 |
| Связанные | [§065 version from tag](065-version-from-tag.md) — предыдущая итерация (CI/local-script инжект). |
| Триггер | После §065 `flutter run` на dev машине показывал `v0.0.0-dev` (pubspec placeholder), UpdateChecker предлагал «обновитесь до vX.Y.Z». Юзер: «может нам явно говорить что это локальная сборка на базе такого-то последнего тега». |

## Цель

Pubspec.yaml автоматически синхронизируется с git state на каждый `git commit` через pre-commit hook. Никаких ручных шагов. Pubspec **всегда** содержит правильную dev-версию.

## Не в скопе

- Triggering hook на `git tag` или `git checkout` — git не предоставляет такие hooks стабильно. На tag CI override'ит из tag'а (см. ниже).
- Husky / simple-git-hooks (npm-обёртки) — добавляют зависимость, не нужно.
- Auto-tag на push to main — нет, ручной tag.

---

## Компоненты

### 1. `scripts/sync-pubspec-version.sh`

Pure derive из git:

```bash
TAG=$(git describe --tags --abbrev=0)        # "v1.8.2"
SINCE=$(git rev-list "$TAG..HEAD" --count)   # 3 (commits between tag and HEAD)
TOTAL=$(git rev-list HEAD --count)            # 387 (all commits)
VER="${TAG#v}"                                # "1.8.2"
[ "$SINCE" = 0 ] || VER="$VER-dev.$SINCE"    # "1.8.2-dev.3"
LINE="version: ${VER}+$((TOTAL + 1))"         # versionCode = TOTAL + 1 (для текущего commit'а)
sed -i.bak -E "s/^version: .*/${LINE}/" app/pubspec.yaml
rm -f app/pubspec.yaml.bak
```

Идемпотентно — если pubspec уже совпадает, exit без change.

### 2. `.githooks/pre-commit`

```bash
#!/usr/bin/env bash
set -euo pipefail
"$(git rev-parse --show-toplevel)/scripts/sync-pubspec-version.sh"
git add "$(git rev-parse --show-toplevel)/app/pubspec.yaml"
```

`git add` обязателен — без него change не попадёт в commit (git стейджит до hook'а).

### 3. `scripts/setup-hooks.sh`

One-shot для разработчика:

```bash
git config core.hooksPath .githooks
chmod +x .githooks/* scripts/sync-pubspec-version.sh
```

После clone делается один раз. В `RELEASE_PROCESS.md` упомянуто.

### 4. CI override (`.github/workflows/ci.yml`)

На tag push hook не сработал → pubspec имеет `-dev.N` версию из последнего commit. CI step «Inject release version from tag» override'ит:

```bash
VERSION="${GITHUB_REF#refs/tags/v}"            # "1.8.3"
BUILD_NUMBER=$(git rev-list --count HEAD)     # 390
sed -i "s/^version: .*/version: $VERSION+$BUILD_NUMBER/" pubspec.yaml
flutter build apk --release
```

Production APK получает чистую `X.Y.Z+N`.

### 5. UpdateChecker `-dev` skip

```dart
bool _isDevBuild(String version) =>
    version.contains('-dev') || version.startsWith('0.0.0');

Future<void> hydrate({required String localVersion}) async {
  if (_isDevBuild(localVersion)) return;
  // ...
}

Future<void> maybeCheck({required String localVersion}) async {
  if (_inFlight) return;
  if (_isDevBuild(localVersion)) return;
  // ...
}
```

`forceCheck()` (manual «Check now» из UI) не skip — юзер явно нажал.

### 6. `scripts/build-local-apk.sh` упрощён

```bash
./scripts/sync-pubspec-version.sh   # defensive (если hook не отработал)
cd app
flutter build apk --release --target-platform android-arm64
```

Никаких `--dart-define BUILD_LOCAL / BUILD_GIT_DESC / BUILD_LAST_TAG / BUILD_COMMITS_SINCE_TAG / BUILD_TIME`. Pubspec — единственный источник.

### 7. `about_screen.dart` упрощён

Удалены:
- `_buildLocal`, `_buildGitDesc`, `_buildLastTag`, `_buildCommitsSinceTag`, `_buildTime` const'ы
- `_LocalBuildBadge` widget

Остаётся `v${VersionInfo.I.version}` — это уже включает `-dev.N` суффикс если dev build.

---

## Сценарии

| Сценарий | Pubspec | versionName | UpdateChecker |
|---|---|---|---|
| `git commit` после tag v1.8.2 (3 commits since) | hook auto-update | `1.8.2-dev.3` | skip (`-dev`) |
| `flutter run` после commit | as-is | `1.8.2-dev.3` | skip |
| `scripts/build-local-apk.sh` | sync + build | `1.8.2-dev.3` | skip |
| Push tag v1.8.3 → CI release | sed override → `1.8.3+390` | `1.8.3` | check enabled |
| Юзер скачал v1.8.3 APK | manifest = 1.8.3+390 | `1.8.3` | check enabled |

---

## Risks

| Риск | Митигация |
|---|---|
| Разработчик не запустил `setup-hooks.sh` | Hook не активен → pubspec stale → `flutter run` покажет stale версию (но `build-local-apk.sh` defensive вызовом sync исправит). UpdateChecker всё равно skip из-за `-dev` суффикса. README/RELEASE_PROCESS подсказывают. |
| Pre-commit hook не triggers на `git tag` | Это by design git'а. CI override step compensates на tag push. |
| Hook меняет staged content **после** того что юзер staged | Pubspec будет в commit'е даже если юзер не stage'ил его. Не критично — pubspec single-file, change всегда small. |
| Rebase / cherry-pick меняют commit count → пересчёт нужен | `post-rewrite` hook не реализован. После rebase разработчик может вручную `./scripts/sync-pubspec-version.sh` + amend. В практике редко критично. |
| sed syntax разница macOS/Linux | Используем `sed -i.bak ... && rm -f .bak` — portable форма. |
| Pubspec change в каждом commit'е → шум в diff | Это derived data, нормально. Один-строчный change `version: ...`, не мешает review. |

---

## Файлы

| Файл | Что |
|---|---|
| `scripts/sync-pubspec-version.sh` NEW | Derive pubspec из git, idempotent |
| `.githooks/pre-commit` NEW | Trigger sync на каждый commit |
| `scripts/setup-hooks.sh` NEW | One-shot для активации hooks |
| `scripts/build-local-apk.sh` | Упрощён — sync + flutter build, никаких dart-define BUILD_* |
| `app/lib/screens/about_screen.dart` | Удалены `_buildLocal/_buildGitDesc/_buildLastTag/_buildCommitsSinceTag/_buildTime` const + `_LocalBuildBadge` widget |
| `app/lib/services/update_checker.dart` | `_isDevBuild` guard в `hydrate` + `maybeCheck` |
| `.github/workflows/ci.yml` | Inject step упрощён, без BUILD_* dart-define'ов |
| `docs/RELEASE_PROCESS.md` §2.2 | Обновлено: pre-commit hook + setup-hooks.sh + CI override |

---

## Test plan

После landing'а:
1. `git config core.hooksPath` → `.githooks` ✓
2. `git commit -m "test"` после tag → pubspec обновляется автоматом ✓
3. `flutter run` → About screen показывает `vX.Y.Z-dev.N` ✓
4. `flutter run` → нет snackbar «X.Y.Z available» (skip dev) ✓
5. `scripts/build-local-apk.sh` → APK с правильным versionName ✓
6. Tag push v1.8.3 → CI release APK с `versionName=1.8.3`, no `-dev` ✓
7. About screen на production APK → `v1.8.3`, UpdateChecker active ✓
