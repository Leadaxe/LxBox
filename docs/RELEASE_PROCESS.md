# Протокол выпуска релизов (L×Box)

Документ описывает, как выпустить **stable-релиз** `vX.Y.Z`. Canonical-source для процедуры: если что-то в других документах противоречит — править здесь, остальное приводить в соответствие.

Смежные документы:
- **`.github/workflows/ci.yml`** — механика CI: триггеры, job'ы, версия, публикация релиза и `docs/latest.json`.
- **`AGENTS.md`** — общий scope агента, правила работы с git / ветками.
- **`RELEASE_NOTES.md`** — тело релиза (корень репо), которое CI загружает в `body_path` GitHub Release.
- **`docs/releases/vX.Y.Z.md`** — архив per-version release notes.

---

## 0. Что меняет CI, что делаете вы

CI (`.github/workflows/ci.yml`) триггерится на:

| Событие | Что запускается |
|---|---|
| push tag `v*` | `meta` + `checks` + `android` + `release` + `publish-manifest` (полный релиз) |
| push в `develop` / `main` | `checks` (только analyze + tests) |
| PR в `develop` / `main` | `checks` |
| `workflow_dispatch` + `run_mode=checks` | `checks` |
| `workflow_dispatch` + `run_mode=build` | `checks` + `android` (APK в artifacts, без релиза) |
| `workflow_dispatch` + `run_mode=release` | полный релиз (тег CI не создаёт — используется для экстренных перевыпусков) |

Тело релиза CI берёт из `RELEASE_NOTES.md` (sparse-checkout, шаг `Create GitHub Release`, `body_path: RELEASE_NOTES.md`). Перед тегированием убедитесь, что файл содержит **ровно** те заметки, которые должны попасть в этот релиз.

Бот-шаг `publish-manifest` после релиза пушит в `main` коммит `chore(release): update docs/latest.json ... [skip ci]`. Это единственный разрешённый автоматический коммит в `main` помимо merge-коммитов релиза.

---

## 1. Модель веток

- **`main`** — релизная ветка. Сюда пишем только **когда готовим релиз**: merge из `develop`, финальные правки `RELEASE_NOTES.md` / `app/pubspec.yaml` / tag-сопутствующие мелочи, тег `vX.Y.Z`, автоматический бот-коммит `docs/latest.json`. Feature-разработка в `main` — нет.
- **`develop`** — основная ветка разработки. Сюда сливаются все feature/fix PR'ы.
- **Feature-ветки** — ответвляются от `develop`, мержатся обратно в `develop`.
- **Теги `vX.Y.Z`** — только на коммитах в `main` (типично — на merge-коммите из `develop`).

После каждого релиза `main` сливается обратно в `develop` (§2.6), иначе бот-коммит `docs/latest.json` и merge-коммит релиза окажутся не-предками `develop`, и `git describe` на `develop` будет врать.

---

## 2. Stable-релиз — `vX.Y.Z`

### 2.1. Pre-flight

1. На `develop` всё зелёное:
   ```bash
   cd app
   flutter analyze && flutter test
   ```
2. `develop` — прямой потомок последнего stable-тега:
   ```bash
   git fetch --tags
   git describe --tags
   # Должно быть vX.Y.Z-N-gSHA; если далеко — подумайте, всё ли включено в заметки
   ```
3. Все доки синхронизированы под релиз:
   - `CHANGELOG.md` — добавлена запись `## vX.Y.Z`.
   - `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT_REPORT.md` — если затронуты.
   - `README.md`, `README_RU.md` — если видимые фичи поменялись.
   - spec'и задач (`docs/spec/features/NNN*/spec.md`) — `status: released`.
   - `docs/releases/vX.Y.Z.md` — черновик per-version архива (можно готовить по ходу разработки).
4. **Local smoke-тест release APK** (рекомендуется перед тегированием):
   ```bash
   scripts/build-local-apk.sh   # release + arm64-only, см. AGENTS-memory
   scripts/install-apk.sh       # auto-detect устройство, install + launch
   ```
   Это ловит debug-подпись, упавший build, несовместимый `versionCode` **до** того, как тег уедет на origin.

   ⚠️ **Если собираете из worktree** (`.claude/worktrees/*`): `app/android/key.properties` и `upload-keystore.jks` в worktree **отсутствуют**. До первой release-сборки симлинкать их из основного checkout'а — иначе APK получит debug-подпись и не встанет поверх prod. См. memory `feedback_keystore_in_worktree`.

### 2.2. Bump версии

В `app/pubspec.yaml`:

```yaml
version: X.Y.Z+<build>
```

`+<build>` — monotonic integer (VersionCode для Android Play-like). Обычно `prev_build + 1`. Даунгрейдить нельзя — установка поверх prod упадёт.

### 2.3. RELEASE_NOTES.md → архив

1. Причесать `RELEASE_NOTES.md` (корень репо) под финальный вид релиза — это тело, которое CI зальёт в body GitHub Release. Формат — как у предыдущих релизов (`v1.5.0` как образец): breaking → highlights → tools/process → tests → install → RU-секция.
2. Скопировать финальный файл в `docs/releases/vX.Y.Z.md` (архив per-version, пригождается для кросс-ссылок из будущих релизов и в spec'ах).
3. Проверить, что внутри нет остатков прошлой версии: заголовок `# L×Box vX.Y.Z`, предыдущая ссылка внизу `Предыдущий релиз: [v...](docs/releases/v...md).`
4. Один коммит в `develop`:
   ```
   docs(release): vX.Y.Z notes + bump to X.Y.Z+N
   ```
   Запушить в `origin/develop`.

### 2.4. Merge в main и тег

CI запускает release job **только** на push тега, и тег нужен **отдельной** командой: `git push origin main --tags` GitHub обработает как push-event по ветке, и release job не стартует.

```bash
git checkout main
git pull --ff-only
git merge --no-ff develop -m "Merge branch 'develop' into main (vX.Y.Z)"
git push origin main

# Отдельно — тег
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```

> ⚠️ После этого тег сидит на merge-коммите в `main`, который **не предок** `develop`. §2.6 — обязательный шаг, иначе следующий релиз стартует с «отставшей» историей.

### 2.5. Дождаться CI

```bash
RUN_ID="$(gh run list --workflow=ci.yml --limit 1 --json databaseId -q '.[0].databaseId')"
gh run watch "$RUN_ID" --exit-status
```

На финише ожидаем:
- Release опубликован (`draft=false`).
- APK `LxBox-vX.Y.Z.apk` приложен (подпись — **release**, не debug; иначе установка поверх prod отвалится).
- Тело релиза = содержимое `RELEASE_NOTES.md` на момент тега.
- `docs/latest.json` обновлён бот-коммитом в `main` (`[skip ci]`).

### 2.6. Post-flight: вернуть main в develop

После релиза в `main` два коммита, не-предки `develop`:
1. Merge-коммит из §2.4.
2. Бот-коммит `chore(release): update docs/latest.json → vX.Y.Z [skip ci]`.

Слить обратно:

```bash
git checkout develop
git fetch origin
git merge --no-ff origin/main -m "chore: merge main (vX.Y.Z tag) back into develop"
git push origin develop

# Проверка:
git describe --tags
# Должно показать vX.Y.Z или vX.Y.Z-N-g<SHA>
```

### 2.7. Verify

```bash
gh release view vX.Y.Z --json isLatest,isDraft,isPrerelease
# → {"isLatest":true, "isDraft":false, "isPrerelease":false}

curl -sL https://raw.githubusercontent.com/Leadaxe/LxBox/main/docs/latest.json | jq '.tag'
# → "vX.Y.Z"
```

- APK качается из release-страницы, `scripts/install-apk.sh` ставит его поверх prod без `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (значит подпись — release).
- На устройстве с предыдущей версией L×Box UpdateChecker показывает SnackBar с новым релизом.

---

## 3. Траблшутинг

### CI падает на release job — «No APK found»

`android` job не отдал артефакт — смотреть его логи. Частая причина — `flutter build apk --release` упал из-за отсутствия keystore secrets. См. `scripts/bootstrap-android-signing-for-ci.sh` и `scripts/setup-android-ci-secrets.sh`.

### APK в релизе имеет debug-подпись

Значит `ANDROID_KEYSTORE_BASE64` / `..._PASSWORD` / `..._ALIAS` не проставлены в GitHub secrets. В логе шага `Android release keystore (optional)` будет:
```
No ANDROID_KEYSTORE_BASE64 secret; release APK will use debug signing.
```
Это **не** надо игнорировать — юзеры с prod-установкой не смогут обновиться. Заполнить secrets и перевыпустить (см. «Тег уже существует» ниже).

### Запушил `main` и тег одной командой — build не стартовал

`git push origin main --tags` GitHub воспринимает как push по ветке, release не стартует. Перепушить тег отдельно:
```bash
git push origin vX.Y.Z
```

### Тело релиза не то / пустое

CI читает `RELEASE_NOTES.md` на момент тега. Если тег стоит на старом коммите — тело будет с прошлого релиза. Горячий фикс:
```bash
gh release edit vX.Y.Z --notes-file RELEASE_NOTES.md
```

### `git describe` на develop отстаёт

§2.6 не сделан. Делать сейчас:
```bash
git checkout develop && git merge --no-ff origin/main && git push origin develop
```

### Тег уже существует, нужно перевыпустить

Последняя мера. `docs/latest.json` уже обновлён бот-коммитом — при необходимости откатывать руками.

```bash
gh release delete vX.Y.Z --yes
git push --delete origin vX.Y.Z
git tag -d vX.Y.Z
# починить причину, перепройти §2.4
```

Если пользователи уже скачали плохой APK — придётся бампать `+build` и релизить `vX.Y.(Z+1)`, т.к. поверх установленной debug-сборки release-сборка не встанет без переустановки с нуля.

---

## 4. Чеклист для агента

### Stable vX.Y.Z

- [ ] `develop` зелёная (`cd app && flutter analyze && flutter test`), descendant от прошлого stable-тега.
- [ ] Релиз-доки синхронизированы: `CHANGELOG.md`, `ARCHITECTURE.md` / `DEVELOPMENT_REPORT.md` (если затронуты), `README.md` + `README_RU.md` (если фичи видимые), spec'и → `status: released`.
- [ ] `app/pubspec.yaml`: `version: X.Y.Z+N` (N > прошлого build).
- [ ] `RELEASE_NOTES.md` причёсан под финал, скопирован в `docs/releases/vX.Y.Z.md`.
- [ ] Local smoke: `scripts/build-local-apk.sh` + `scripts/install-apk.sh` — ставится поверх prod без `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (при работе из worktree не забыть симлинки keystore).
- [ ] Коммит `docs(release): vX.Y.Z notes + bump to X.Y.Z+N` запушен в `develop`.
- [ ] `main` ← merge `--no-ff develop`, запушен; тег `vX.Y.Z` запушен **отдельной командой**.
- [ ] `gh run watch` зелёный, APK `LxBox-vX.Y.Z.apk` в релизе, подпись — release.
- [ ] `publish-manifest` отработал — `docs/latest.json` обновлён на `main`.
- [ ] `main` слит обратно в `develop` (§2.6), запушен.
- [ ] `git describe` на `develop` показывает `vX.Y.Z`.
- [ ] `gh release view vX.Y.Z --json isLatest` → `{"isLatest":true}`.
