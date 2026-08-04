# Публикация в F-Droid

Как обновить L×Box в каталоге F-Droid после выпуска релиза на GitHub.

Смежные документы:
- [`RELEASE_PROCESS.md`](RELEASE_PROCESS.md) — выпуск самого релиза (тег, CI, GitHub Release).
- [`BUILD.md`](BUILD.md) — сборка APK, ядро sing-box-lx.

---

## 0. Как это устроено

**GitHub и GitLab — две независимые системы, вложенности между ними нет.**

| Где | Что |
|---|---|
| GitHub | Разработка, теги, GitHub Actions, релизы с APK |
| GitLab (`fdroid/fdroiddata`) | Каталог F-Droid: метаданные и их собственный CI |

F-Droid не берёт готовый APK из GitHub Release. Их сборщик читает поле `commit:`
из метаданных, клонирует **этот** репозиторий на указанном теге и собирает APK
у себя с нуля — включая ядро `libbox.aar`, которое компилируется из исходников
`Leadaxe/sing-box-lx`. Так проверяется, что бинарник соответствует коду.

Единственная связь между системами — обычный `git clone` с их стороны. Ни один
из двух CI не запускает другой.

**Наши координаты:**

| Что | Где |
|---|---|
| Метаданные | `metadata/com.leadaxe.lxbox.yml` в `fdroid/fdroiddata` |
| Форк | `gitlab.com/leadaxe/fdroiddata`, ветка `com.leadaxe.lxbox` |
| Заявка (RFP) | [fdroid/rfp#4218](https://gitlab.com/fdroid/rfp/-/work_items/4218) |
| Merge request | [fdroiddata!44731](https://gitlab.com/fdroid/fdroiddata/-/merge_requests/44731) |

Токен GitLab (scope `api`) — в `~/.gitlab-token`, права `600`, вне репозитория.
Передавать одноразово прямо в URL push'а, **не** прописывать в `remote`.

---

## 1. Обновление на новый релиз

Автоподхват новых версий отключён (`UpdateCheckMode: None`, почему — §4), поэтому
на каждую версию нужен небольшой MR: меняются только номер версии и тег.

### 1.1. Посчитать versionCode

Сборка F-Droid идёт **без** `--split-per-abi`, поэтому ABI-множителя Flutter
там нет. Схема своя, по требованию рецензента (MR!44731): ABI-цифра идёт
**последней**, иначе список версий в каталоге сортируется вперемешку.

```bash
echo $(( $(git rev-list --count vX.Y.Z) * 10 + 2 ))   # 2 = arm64
```

ABI-цифры: `1` armv7, `2` arm64, `4` x86_64.

⚠ У APK с GitHub значение **другое** — там `--split-per-abi` остался, и Flutter
домножает ABI по своей формуле (`ABI * 1000 + code`). Не путать: в метаданные
F-Droid идёт число из команды выше, а не из GitHub-APK. Подробности — §4.

### 1.2. Поправить метаданные

Версии тулчейнов править **не нужно** — они читаются из исходников
(`android/flutter.version`, `go.version` ядра, `android/libbox.version`),
а `srclibs` пинятся ветками. Это и была суть замечаний рецензента: в
метаданных F-Droid не должно остаться ни одной захардкоженной версии.

В `metadata/com.leadaxe.lxbox.yml` меняются **четыре** места:

```yaml
Builds:
  - versionName: X.Y.Z          # 1
    versionCode: <из §1.1>      # 2 — например 16042
    commit: <полный хеш>        # 3 — git rev-parse vX.Y.Z^{commit}

CurrentVersion: X.Y.Z           # 4a
CurrentVersionCode: <из §1.1>   # 4b
```

⚠ `commit:` — **полный хеш**, не тег: рецензент просил именно так.

Проверить локально (`fdroidserver` ставится через `pip install`):

```bash
fdroid lint com.leadaxe.lxbox && fdroid rewritemeta com.leadaxe.lxbox && git diff --quiet metadata/com.leadaxe.lxbox.yml && echo "формат канонический"
```

`rewritemeta` не должен ничего менять — иначе их CI отвергнет форматирование.

### 1.3. Запушить в форк

Отдельной команды «запустить CI» нет: **push сам запускает их пайплайн**.

```bash
git add metadata/com.leadaxe.lxbox.yml && git commit -m "com.leadaxe.lxbox: update to X.Y.Z" && git push "https://oauth2:$(tr -d '[:space:]' < ~/.gitlab-token)@gitlab.com/leadaxe/fdroiddata.git" com.leadaxe.lxbox
```

### 1.4. Дождаться зелёного пайплайна

Сборка идёт ~20 минут (компилируется ядро). Девять джобов должны быть `success`,
в логе `fdroid build` — строка `1 build succeeded`.

Только после этого открывать MR в `fdroid/fdroiddata`. Их CONTRIBUTING требует
именно такого порядка: сначала зелёная сборка на форке, потом MR.

---

## 2. Скриншоты и описания

**Fastlane-метаданные читаются из коммита релиза, а не из ветки.** Поля «взять
метаданные из другого коммита» у F-Droid нет ([их документация][fastlane-docs]:
fdroidserver checkout'ит последнюю версию и сканирует репозиторий в её состоянии).

Практическое следствие: скриншот, добавленный в `develop` после тега, на витрину
**не попадёт** — нужен новый релиз. На этом уже обожглись: v2.19.4 ушёл без
скриншотов, пришлось выпускать v2.19.5.

Файлы: `fastlane/metadata/android/{en-US,ru}/`

⚠ Каталог лежит **в корне репозитория**, а не в `app/`. F-Droid ищет fastlane
только в корне — из `app/` он его не видит (замечание рецензента в MR!44731).

| Что | Файл |
|---|---|
| Короткое описание (≤80 символов) | `short_description.txt` |
| Полное описание | `full_description.txt` |
| Иконка | `images/icon.png` |
| Скриншоты | `images/phoneScreenshots/N.png` — нумерация задаёт порядок |
| Changelog | `changelogs/<versionCode>.txt` — имя = код из APK |

⚠ **Имя changelog'а — тот же versionCode, что в метаданных** (см. §1.1, схема
`rev-list * 10 + ABI`). Не совпадёт — changelog версии просто не покажут.

### Съёмка скриншотов

```bash
adb exec-out screencap -p > shot.png
```

⚠ **Экран Servers не снимать** — там личные подписки и домашние серверы. Для
кадров использовать публичные подписки из `public-servers-manifest.json`.

---

## 3. Что отличается в сборке F-Droid

| Что | Почему |
|---|---|
| `libbox.aar` собирается из исходников | prebuilt-бинарники запрещены; апстрим sing-box пакуется так же |
| **naive отключён** | тянет `cronet-go` с готовым `libcronet.a` |
| Собирается только arm64 | `--target-platform=android-arm64` + `LXBOX_ABI_FILTER` |
| Проверка JDK 17 в ядре вырезана | в их Debian trixie стоит JDK 21, пакета `openjdk-17` нет |
| legacy-вариант AAR вырезан | gomobile требует SDK platform под каждый вариант |

На сборки с GitHub это не влияет — там naive остаётся и собираются все ABI.

⚠ **`--target-platform` НЕ фильтрует нативный код ядра.** Он сужает только
движок Flutter и Dart AOT, а `.so` внутри AAR (все три ABI) попадают в APK как
есть — без фильтра APK раздувается 31 → 71 МБ. Отсюда `LXBOX_ABI_FILTER`
([build.gradle.kts](../app/android/app/build.gradle.kts)): он чистит
`ndk.abiFilters` и выкидывает чужие ABI из AAR через `packaging.jniLibs.excludes`.

### Грабли их buildserver

Выявлены прогонами CI, все учтены в метаданных:

1. `make.bash` требует bootstrap-Go → `apt-get install golang-go` + `GOROOT_BOOTSTRAP`.
2. **Сканер работает МЕЖДУ `prebuild:` и `build:`.** Всё, что собрано в
   `prebuild`, он видит как подозрительные бинарники и требует `scanignore`.
   Сборка ядра живёт в `build:` — тогда сканер видит только исходники, и
   `scanignore` не нужен вовсе (ни на AAR, ни на Go-модкэш с его fuzz-корпусом).
3. Первый запуск CI на GitLab требует верификации аккаунта (телефон/карта), иначе
   пайплайн падает как «yaml invalid» с нулём джобов.
4. Git-протокол к GitLab периодически отваливается (`Connection reset`), а REST
   API при этом жив. Обход — коммит файла через
   `POST /projects/:id/repository/commits`.

---

## 4. Две разные схемы versionCode

**GitHub** (`--split-per-abi`) — формулу задаёт Flutter, ABI впереди:

```
versionCodeOverride = ABI_VERSION[abi] * 1000 + versionCode
```

(`FlutterPlugin.kt`; arm32 = 1, arm64 = 2, x86_64 = 4.)

**F-Droid** (без `--split-per-abi`) — формулу задаём мы, ABI сзади:

```
versionCode = git rev-list --count <тег> * 10 + ABI
```

Почему именно так: каталог F-Droid **сортирует версии по versionCode**. С
ABI впереди x86_64-сборка старого релиза оказывается «новее» armv7-сборки
нового, и список едет вперемешку. С ABI сзади релизы идут по порядку, а
варианты одного релиза стоят рядом. Это прямое требование рецензента
(MR!44731).

Числа для одного релиза **не совпадают** между GitHub и F-Droid — так и
задумано, это разные каналы с разными APK.

### Почему UpdateCheckMode: None

Их `checkupdates` не может прочитать версию:

- в git `pubspec.yaml` держит placeholder, реальная версия вычисляется из тега
  на сборке (см. [`RELEASE_PROCESS.md` §2.2](RELEASE_PROCESS.md));
- `versionCode` из имени тега тоже не выводится — это число коммитов.

**Долг:** включить автообновление, когда версия станет читаемой из исходников.
Обещано рецензенту. Требует смены схемы версионирования (писать реальную
версию в pubspec при релизе), с проверкой монотонности на устройстве —
versionCode обязан только расти, иначе Android откажет в обновлении.
Отдельной таской, после включения в каталог.

### Долг: остальные ABI

Сейчас собирается только arm64. armv7 и x86_64 добавляются отдельными
build-блоками с тем же `versionName`, но своими `versionCode`
(цифры `…1` и `…4`) и своими `LXBOX_ABI_FILTER` / `--target-platform`.
Каждый ABI — отдельная ~20-минутная сборка ядра на их раннерах.

[fastlane-docs]: https://f-droid.org/en/docs/All_About_Descriptions_Graphics_and_Screenshots/
