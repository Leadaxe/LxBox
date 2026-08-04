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

### 1.1. Узнать versionCode

Сборка F-Droid идёт **без** `--split-per-abi`, поэтому ABI-множителя там нет и
versionCode равен числу коммитов на релизном коммите:

```bash
git rev-list --count vX.Y.Z
```

⚠ У APK с GitHub значение **другое** — там `--split-per-abi` остался, и Flutter
домножает ABI (arm64: `2*1000 + code`). Не путать: в метаданные F-Droid идёт
число из команды выше, а не из GitHub-APK. Подробности — §4.

### 1.2. Поправить метаданные

В `metadata/com.leadaxe.lxbox.yml` меняются **шесть** мест:

```yaml
Builds:
  - versionName: X.Y.Z          # 1
    versionCode: <из APK>       # 2 — например 3582
    commit: vX.Y.Z              # 3
    ...
    prebuild:
      - "sed -i -e 's/^version: .*/version: X.Y.Z+<базовый>/' pubspec.yaml"   # 4
                                # базовый = versionCode из APK минус 2000

CurrentVersion: X.Y.Z           # 5
CurrentVersionCode: <из APK>    # 6
```

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

⚠ **Имя changelog'а — итоговый versionCode** (3582), а не базовый. Не совпадёт —
changelog версии просто не покажут.

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
| Собирается только arm64 | `--split-per-abi --target-platform=android-arm64` |
| Проверка JDK 17 в ядре вырезана | в их Debian trixie стоит JDK 21, пакета `openjdk-17` нет |
| legacy-вариант AAR вырезан | gomobile требует SDK platform под каждый вариант |

На сборки с GitHub это не влияет — там naive остаётся.

### Грабли их buildserver

Выявлены прогонами CI, все учтены в метаданных:

1. `make.bash` требует bootstrap-Go → `apt-get install golang-go` + `GOROOT_BOOTSTRAP`.
2. Go-модкэш read-only, внутри бинарный fuzz-корпус protobuf → **`scanignore`**,
   не `scandelete` (тот пытается удалять и падает с `PermissionError`).
3. Сканер отвергает **любой** `.aar` → `scanignore` на `libbox.aar` (он собирается
   тут же, в prebuild, и в репозитории отсутствует).
4. Первый запуск CI на GitLab требует верификации аккаунта (телефон/карта), иначе
   пайплайн падает как «yaml invalid» с нулём джобов.

---

## 4. versionCode ≠ число коммитов

При `--split-per-abi` Flutter домножает ABI:

```
versionCodeOverride = ABI_VERSION[abi] * 1000 + versionCode
```

(`FlutterPlugin.kt`; arm32 = 1, arm64 = 2, x86_64 = 4.)

Для v2.19.5: `git rev-list --count` даёт **1582**, а arm64-APK несёт **3582**.

Отсюда два следствия:

- в `versionCode:` и в имени changelog'а пишется **итоговое** значение (3582);
- `sed` в prebuild кладёт в pubspec **базовое** (1582) — множитель добавит gradle.

### Почему UpdateCheckMode: None

Их `checkupdates` не может прочитать версию:

- в git `pubspec.yaml` держит placeholder, реальная версия вычисляется из тега
  на сборке (см. [`RELEASE_PROCESS.md` §2.2](RELEASE_PROCESS.md));
- из имени тега `versionCode` не выводится: 3582 никак не следует из `v2.19.5`.

### Идея на будущее: научить CI писать версию в pubspec

Обсуждалась, **отложена до вливания MR**. Разобранные варианты:

| Вариант | Проблема |
|---|---|
| pre-commit хук пишет `rev-list --count + 1` | Угадывание. Тег ставится на тот же коммит; любая доп. правка (заметки, опечатка) снова ломает число. И главное — в pubspec попадёт базовый код, а APK несёт умноженный, так что `checkupdates` всё равно споткнётся |
| Детерминированный код из версии (`2.19.5` → `21905`) | Работает, но это смена схемы версионирования. Нужна проверка монотонности на устройстве: код обязан только расти, иначе Android откажет в обновлении |
| Собирать universal вместо split-per-abi | Множителя нет, код равен базовому. Но APK ~105 МБ вместо 31 МБ |

Корень проблемы не в «неактуальном pubspec», а в том, что при `--split-per-abi`
в pubspec **в принципе не может лежать то число, которое окажется в APK**.

Браться за это стоит отдельной таской после того, как заявку примут.

[fastlane-docs]: https://f-droid.org/en/docs/All_About_Descriptions_Graphics_and_Screenshots/
