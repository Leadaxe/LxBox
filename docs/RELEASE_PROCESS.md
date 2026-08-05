# Протокол выпуска релизов (L×Box)

Документ описывает, как выпустить **stable-релиз** `vX.Y.Z`. Canonical-source для процедуры: если что-то в других документах противоречит — править здесь, остальное приводить в соответствие.

Смежные документы:
- **`.github/workflows/ci.yml`** — механика CI: триггеры, job'ы, версия, публикация релиза и `docs/latest.json`.
- **`AGENTS.md`** — общий scope агента, правила работы с git / ветками.
- **`RELEASE_NOTES.md`** — тело релиза (корень репо), которое CI загружает в `body_path` GitHub Release.
- **`docs/releases/vX.Y.Z.md`** — архив per-version release notes.
- **[`FDROID.md`](FDROID.md)** — публикация в F-Droid: что делать в каталоге после выпуска релиза (отдельный MR на GitLab; скриншоты и описания читаются из коммита тега, а не из ветки).

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

0. **Ядро — fork sing-box-lx, не сток.** Релиз с AWG/XHTTP (§097) валиден только на ядре fork'а (механика — [§104](spec/tasks/104-libbox-fork-ci-fetch.md)):
   - в `app/android/app/build.gradle.kts` зависимость — `implementation(files("libs/libbox.aar"))`, активной Maven-строки `com.github.singbox-android:libbox` **нет**;
   - в `ci.yml` (job `android`) есть шаг `Fetch sing-box-lx core (libbox.aar)`, а пин `app/android/libbox.version` = версия, которой прогнан local smoke (п. 4) — пин общий для local и CI, расходиться им не с чего;
   - стоковое ядро 1.13.11 отвергает конфиги с AWG-полями (`jc`/`jmin`/…) и `type:"xhttp"` — релиз, собранный на нём, брак.
1. На `develop` всё зелёное:
   ```bash
   cd app
   flutter analyze && flutter test
   dart run tool/l10n/template_check.dart --strict
   dart run tool/l10n/ui_check.dart --strict
   dart run tool/l10n/hardcoded_check.dart --strict
   dart run tool/l10n/kotlin_check.dart --strict
   ```
   ⚠ Именно `flutter analyze` **без аргумента** — CI анализирует **весь** проект, включая `test/`. Локальная привычка `flutter analyze lib/` пропускает ошибки в тестах (особенно `non_exhaustive_switch` после добавления подтипа в sealed-класс) — они всплывут в CI уже **после** пуша тега и уронят релиз (ловили на v2.8.2 / §217).

   ⚠ Четыре l10n-чекера — **не опционально**: job `checks` гоняет их шагом «L10n checks», и падение любого роняет релиз ровно так же, как упавший тест. На v2.17.0 тег пришлось перевыпускать из-за `hardcoded_check`: два `hintText`-примера в §302 (`tls.utls.fingerprint`, `chrome`). Технические идентификаторы в UI (JSON-пути, значения протокольных полей) переводу не подлежат — лечение не «завести ключ в словаре», а аннотация `// l10n-exempt: <причина>` в конце строки (см. [l10n.md](l10n.md)).
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

   ⚠️ **Ядро для smoke:** `app/android/app/libs/libbox.aar` — в `.gitignore`, в свежем clone/worktree его нет; `build-local-apk.sh` сам скачивает версию из пина `app/android/libbox.version` (`scripts/fetch-libbox.sh`, идемпотентно) — см. [BUILD.md → «Ядро sing-box-lx»](BUILD.md#ядро-sing-box-lx-libbox). CI использует тот же пин, так что smoke и релиз гарантированно на одной версии ядра; smoke на версии, отличной от пина (ручной override fetch-скрипта), не считается.

### 2.2. Версия — git tag это единственный source of truth

**Выбор номера версии: по умолчанию бампаем ТОЛЬКО patch (последнюю цифру).**
`2.9.1 → 2.9.2 → 2.9.3`, а не улетать в minor `2.10.0`, даже если в релизе есть
новые фичи. Minor/major — только по явному решению мейнтейнера. Не додумывать
«тут же фичи, значит minor» — по умолчанию всегда следующий patch.

**versionCode считается из версии** ([§379](spec/tasks/379-version-code-from-version.md)), а не из числа коммитов:

```
versionCode = ((major × 10000 + minor × 100 + patch) × 100 + PRE) × 10 + ABI
```

`PRE`: `01-49` = `-rc.N`, `50` = релиз, `51-98` = `-hotfixN`. `ABI`: `0` universal, `1` armv7, `2` arm64, `4` x86_64. Считает [`scripts/version-code.sh`](../scripts/version-code.sh) — единственный источник формулы; CI и локальный скрипт обязаны звать именно его, иначе коды разойдутся и `install -r` сломается.

`v2.19.8` → arm64 `21908502`, а `v2.19.8-rc.1` → `21908012`. Строго возрастает по мере выпусков.

- **`app/pubspec.yaml`** в `develop` держит placeholder — при релизе туда **коммитится реальная версия** (§2.4), иначе F-Droid `checkupdates` не может её прочитать и автообновление в каталоге не работает. Тег встаёт на этот коммит.
- **CI release** переписывает pubspec из tag перед `flutter build`:
  - `versionName` = `${tag#v}` (чистая `X.Y.Z` без `-dev` суффикса в production APK).
  - `versionCode` — по формуле выше, своя цифра ABI на каждый из 4 прогонов сборки.
- **Локальная сборка** ([`scripts/build-local-apk.sh`](../scripts/build-local-apk.sh)) переписывает pubspec перед `flutter build`:
  - `versionName` = `${tag#v}` на теге, иначе `${tag#v}-dev.${commits_since_tag}` (например `1.8.2-dev.3`).
  - `versionCode` = код **последнего релизного тега** для arm64 (пин к тегу, §186 — против downgrade-блока при установке релиза поверх dev-сборки; хвост `-dev.N` формула срезает).
- **About screen / UpdateChecker** читают версию через `VersionInfo.I.version` (load из `PackageInfo.fromPlatform()` в `main()` перед `runApp`) — то есть из APK-манифеста, а не из pubspec-файла.
- **UpdateChecker skip для `-dev` versions** — dev builds не получают snackbar «X.Y.Z available» (всегда выглядит как «обновитесь до latest»).

### Setup для нового clone

Ничего не требуется — версионирование целиком вычисляется на сборке (`build-local-apk.sh` / CI). Git-хуки не используются.

### История

- До v1.8.2 версия дублировалась в `pubspec.yaml` + `about_screen.dart _version` const. v1.8.0 ▼: расхождение, UI показал v1.7.0. v1.8.1 hotfix + CI consistency check как guard.
- v1.8.2 ([§065](spec/tasks/065-version-from-tag.md)): убрана hardcoded const, pubspec → placeholder, CI/local-script инжектят. Но требовался manual `scripts/build-local-apk.sh` для realistic version при dev sessions.
- v1.8.3 ([§066](spec/tasks/066-pubspec-sync-hook.md)): pre-commit hook делал sync автоматом на каждый commit.
- v2.11.x: pre-commit hook **удалён** (`.githooks/`, `setup-hooks.sh`, `sync-pubspec-version.sh`). Хук лишь бампил закоммиченный pubspec, но обе сборки (local + CI) всё равно переписывают версию перед `flutter build`, а runtime читает её из APK-манифеста — значение хука до APK не доживало. Взамен pubspec заморожен на `0.0.0+1`, версия вычисляется только на сборке. Выгода: конец «дрожанию» pubspec и merge-конфликтам по `version:`.
- v2.19.x ([§379](spec/tasks/379-version-code-from-version.md)): versionCode переведён с `rev-list --count` на формулу от версии, `--split-per-abi` убран. Реальная версия снова коммитится — но ровно один раз, на merge-коммите в `main`, а не на каждый коммит в `develop` (это и была причина «дрожания»). Повод: F-Droid `checkupdates` читает версию из исходников на коммите тега; без этого автообновление в каталоге невозможно.

### 2.3. RELEASE_NOTES.md → архив

1. Причесать `RELEASE_NOTES.md` (корень репо) под финальный вид релиза — это тело, которое CI зальёт в body GitHub Release. Структура: вступление (оба языка) → английская секция → русская секция → Install → ссылка на предыдущий релиз.

   **Заметки всегда двуязычные — английский и русский, обе версии полные.** Не «основной язык + краткая выжимка на втором»: содержимое дублируется целиком, один в один по разделам. Каждая языковая секция заворачивается в спойлер, чтобы страница релиза не растягивалась вдвое:

   ```markdown
   <details open>
   <summary><h2>🇬🇧 English</h2></summary>
   …полный текст…
   </details>

   <details open>
   <summary><h2>🇷🇺 Русский</h2></summary>
   …полный текст…
   </details>
   ```

   `v2.17.0` — образец формата. Внутри секций — как у предыдущих релизов: breaking → highlights → tools/process → tests. Разделы Install и ссылка на предыдущий релиз общие, вне спойлеров, продублированы двумя языками.
2. Скопировать финальный файл в `docs/releases/vX.Y.Z.md` (архив per-version, пригождается для кросс-ссылок из будущих релизов и в spec'ах).
3. Проверить, что внутри нет остатков прошлой версии: заголовок `# L×Box vX.Y.Z`, номер в команде `adb install`, предыдущая ссылка внизу `Previous release / Предыдущий релиз: [v...](docs/releases/v...md).` Плюс — обе языковые секции описывают один и тот же набор изменений (при правках легко обновить одну и забыть вторую).
4. Один коммит в `develop`:
   ```
   docs(release): vX.Y.Z notes
   ```
   Запушить в `origin/develop`. **Никаких pubspec/about_screen изменений в `develop`** — версия пишется в pubspec один раз, на merge-коммите в `main` (§2.4), чтобы не «дрожала» в ветке разработки.

### 2.4. Merge в main и тег

CI запускает release job **только** на push тега, и тег нужен **отдельной** командой: `git push origin main --tags` GitHub обработает как push-event по ветке, и release job не стартует.

```bash
git checkout main
git pull --ff-only

# ⚠ Two-step merge: `--no-commit` + explicit `commit -m`.
# `git merge --no-ff -m "..."` падает с "Пустое сообщение коммита"
# несмотря на -m (git CLI quirk, ловили дважды на v1.8.1 + v1.8.2).
# Если script продолжает после fail → push выдаст "up-to-date" (main не
# двинулся), tag создастся на старом commit'е, CI соберёт устаревший
# код. Always two-step.
git merge --no-ff --no-commit develop

# §379 — реальная версия в pubspec ДО коммита: тег встанет на этот коммит, а
# F-Droid checkupdates читает версию именно с коммита тега. Без этого шага
# в каталоге остаётся placeholder и автообновление не работает.
# Число после `+` — база кода (ABI=0), цифру ABI добавляет VercodeOperation.
CODE="$(scripts/version-code.sh X.Y.Z universal)"
sed -i.bak -E "s/^version: .*/version: X.Y.Z+${CODE}/" app/pubspec.yaml
rm -f app/pubspec.yaml.bak
git add app/pubspec.yaml

git commit -m "Merge branch 'develop' into main (vX.Y.Z)"
git push origin main

# Sanity: tag должен дотягиваться до hotfix commit'а
git merge-base --is-ancestor <hotfix-sha> main && echo OK || echo "❌ retag needed"

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
- Приложены 4 APK: `LxBox-vX.Y.Z-arm64-v8a.apk` / `-armeabi-v7a` / `-x86_64` / `-universal` (подпись — **release**, не debug; иначе установка поверх prod отвалится).
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
# ⚠ Тот же two-step quirk, что в §2.4: `merge --no-ff -m` падает с
# «Пустое сообщение коммита» (ловили на v2.11.1) — всегда --no-commit + commit -m.
git merge --no-ff --no-commit origin/main

# ⚠ §379 — merge тянет из main реальную версию в pubspec. В develop должен
# остаться placeholder, иначе версия снова начнёт «дрожать» в ветке разработки
# (ровно от этого ушли в v2.11.x). Откатываем ДО коммита:
git checkout HEAD -- app/pubspec.yaml
git status --short   # ожидаем только docs/latest.json

git commit -m "chore: merge main (vX.Y.Z tag) back into develop"
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
- Ссылки из приложения на документы в `main` отдают 200 (в APK они зашиты на `blob/main`, а файл попадает туда только с merge — §361):

  ```bash
  grep -oE 'https://github\.com/Leadaxe/LxBox/blob/main/[^'"'"']+' app/lib/services/project_links.dart | sort -u | while read -r u; do
    printf '%s → ' "${u##*/}"
    curl -s -o /dev/null -w '%{http_code}\n' "$u"
  done
  # → все 200; 404 = документ не влит в main, кнопка в About/Automation ведёт в никуда.
  # Список берётся из ProjectLinks (§358) — новая doc-ссылка попадает в проверку сама.
  ```
- В установленном из релиза APK версия ядра (About/Debug, `Libbox.version()`) содержит суффикс `-lx` и совпадает с пином `app/android/libbox.version` на теге (сейчас `v1.14.0-lx.1`), **не** стоковое `1.13.11`: гарантия, что CI собрал fork-ядро и AWG/XHTTP/MASQUE-конфиги работают.
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

### Релизный APK собран на стоковом ядре (AWG/XHTTP отвергаются)

Симптом: Start падает с ошибкой ядра на конфигах с AWG-полями (`jc`/`jmin`/…) или `type:"xhttp"`; версия ядра в About/Debug — `1.13.11` без `-lx`.

Причина: CI собрал стоковый Maven-libbox — в `build.gradle.kts` вернулась Maven-строка, либо шаг `Fetch sing-box-lx core` в `ci.yml` убран/не отработал (или пин `app/android/libbox.version` указывает не туда).

Это брак релиза. Чинить `ci.yml`/gradle/пин и перевыпускать тег (см. «Тег уже существует»). ⚠ **Не** подменять артефакт локально собранным APK через `gh release upload` — релизы только CI-built.

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

Сначала определить, дошёл ли CI до создания Release — от этого зависит безопасность re-tag:

```bash
gh release view vX.Y.Z --json isDraft,createdAt 2>/dev/null || echo "release not found"
```

#### Случай (а): CI упал ДО `Create GitHub Release` (`release not found`)

Самый частый путь — `checks`/`analyze`/`android` упали раньше, чем job `release` создал релиз (например `flutter analyze` на `test/`, см. pre-flight п.1, или флаки-тест — так падал первый тег v2.8.2 и v2.9.0). GitHub Release и `docs/latest.json` **не тронуты**, поэтому re-tag безопасен:

```bash
# gh release view выше должен сказать "release not found"
git push --delete origin vX.Y.Z
git tag -d vX.Y.Z
# починить причину, перепройти §2.4 (тот же vX.Y.Z)
```

#### Случай (б): Release уже опубликован

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

- [ ] `develop` зелёная (`cd app && flutter analyze && flutter test` **+ четыре `dart run tool/l10n/*_check.dart --strict`** — CI гоняет их шагом «L10n checks», см. §2.1 п.1), descendant от прошлого stable-тега.
- [ ] **Ядро:** `app/android/app/build.gradle.kts` → `implementation(files("libs/libbox.aar"))` (активной Maven-строки стокового libbox нет); в `ci.yml` job `android` есть шаг `Fetch sing-box-lx core`, пин `app/android/libbox.version` = версии local smoke. Стоковое 1.13.11 отвергает AWG/XHTTP-конфиги — такой релиз не выпускать.
- [ ] Релиз-доки синхронизированы: `CHANGELOG.md`, `ARCHITECTURE.md` / `DEVELOPMENT_REPORT.md` (если затронуты), `README.md` + `README_RU.md` (если фичи видимые), spec'и → `status: released`.
- [ ] `app/pubspec.yaml` в `develop` **не трогать** — реальная версия пишется туда на merge-коммите в `main` (§2.4/§379), тег встаёт на этот коммит.
- [ ] `RELEASE_NOTES.md` причёсан под финал, скопирован в `docs/releases/vX.Y.Z.md`. **Обе языковые версии (EN + RU) полные и синхронные**, каждая в своём `<details>`-спойлере (§2.3, образец — `v2.17.0`).
- [ ] Local smoke: `scripts/build-local-apk.sh` (derive'ит версию из `git describe`, sed pubspec + revert trap) + `scripts/install-apk.sh` — ставится поверх prod без `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (при работе из worktree не забыть симлинки keystore).
- [ ] Коммит `docs(release): vX.Y.Z notes` запушен в `develop` (только doc-изменения; никаких pubspec/code bump'ов).
- [ ] `main` ← merge `--no-ff --no-commit develop` → `commit -m "Merge ..."` → push; тег `vX.Y.Z` запушен **отдельной командой**. **NB:** именно `--no-commit` + явный `commit -m`, не `--no-ff -m` — последнее ломается на «Пустое сообщение коммита» и tag оказывается на старом commit'е (см. memory `feedback_git_merge_no_ff_quirk`).
- [ ] `gh run watch` зелёный; в релизе 4 APK `LxBox-vX.Y.Z-{arm64-v8a,armeabi-v7a,x86_64,universal}.apk`, подпись — release; версия ядра в APK содержит суффикс `-lx` и совпадает с пином `app/android/libbox.version` на теге (сейчас `v1.14.0-lx.1`).
- [ ] `publish-manifest` отработал — `docs/latest.json` обновлён на `main`.
- [ ] `main` слит обратно в `develop` (§2.6), запушен.
- [ ] `git describe` на `develop` показывает `vX.Y.Z`.
- [ ] `gh release view vX.Y.Z --json isLatest` → `{"isLatest":true}`.
