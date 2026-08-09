# Публикация в F-Droid

Смежное: [`RELEASE_PROCESS.md`](RELEASE_PROCESS.md) — выпуск релиза,
[`BUILD.md`](BUILD.md) — сборка APK.

## Как устроено

F-Droid не берёт APK из GitHub Release. Их сборщик читает `commit:` из
метаданных, клонирует репозиторий на этом теге и собирает всё сам — включая
`libbox.aar` из исходников `Leadaxe/sing-box-lx`.

| Что | Где |
|---|---|
| Метаданные | `metadata/com.leadaxe.lxbox.yml` в `fdroid/fdroiddata` |
| Форк | `gitlab.com/leadaxe/fdroiddata`, ветка `com.leadaxe.lxbox` |
| Заявка | [rfp#4218](https://gitlab.com/fdroid/rfp/-/work_items/4218) |
| MR | [fdroiddata!44731](https://gitlab.com/fdroid/fdroiddata/-/merge_requests/44731) |

Токен GitLab (scope `api`) — в `~/.gitlab-token`, права `600`, вне репозитория.
Передавать одноразово в URL push'а, **не** прописывать в `remote`.

## Обновление на новый релиз

Автоподхват включён: F-Droid читает версию из `app/pubspec.yaml` на новом теге.
Ручной MR нужен, только когда меняется сам рецепт.

Если правим вручную — в каждом из трёх build-блоков меняются `versionName`,
`versionCode` (своя ABI-цифра) и `commit` (**полный хеш**, не тег), плюс
`CurrentVersion` / `CurrentVersionCode` внизу файла. Код считает
[`scripts/version-code.sh`](../scripts/version-code.sh):

```bash
scripts/version-code.sh 2.20.4 arm64-v8a   # 22004502
```

Версии тулчейнов править не нужно — они читаются из исходников
(`android/flutter.version`, `go.version` ядра, `android/libbox.version`), а
`srclibs` пинятся ветками. В метаданных F-Droid не должно остаться ни одной
захардкоженной версии — прямое требование рецензента.

Перед пушем прогнать **оба** линтера (`pip install fdroidserver`):

```bash
fdroid lint com.leadaxe.lxbox && fdroid rewritemeta com.leadaxe.lxbox && git diff --quiet metadata/com.leadaxe.lxbox.yml && echo ok
```

`lint` пропускает длинные строки, а `rewritemeta` их переносит — и это отдельная
джоба в их CI, которая упадёт.

Push сам запускает их пайплайн; отдельной команды нет. Сборка трёх ABI идёт
**~3 часа**, в логе `fdroid build` должно быть три строки `1 build succeeded`.
MR открывать только после зелёного прогона — этого требует их CONTRIBUTING.

## Скриншоты и описания

Файлы: `fastlane/metadata/android/{en-US,ru}/` — **в корне репозитория**, не в
`app/` (из `app/` F-Droid их не видит).

| Что | Файл |
|---|---|
| Короткое описание (≤80 символов) | `short_description.txt` |
| Полное описание | `full_description.txt` |
| Иконка | `images/icon.png` |
| Скриншоты | `images/phoneScreenshots/N.png` — номер задаёт порядок |
| Changelog | `changelogs/<versionCode>.txt` |

⚠ **Метаданные читаются из коммита релиза, а не из ветки.** Скриншот, добавленный
в `develop` после тега, на витрину не попадёт — нужен новый релиз. На этом уже
обожглись: v2.19.4 ушёл без скриншотов, пришлось выпускать v2.19.5.

⚠ Имя changelog'а — тот же versionCode, что в метаданных. Не совпадёт — F-Droid
не покажет описание изменений.

⚠ Экран Servers не снимать — там личные подписки. Для кадров брать публичные из
`public-servers-manifest.json`.

```bash
adb exec-out screencap -p > shot.png
```

## Чем сборка F-Droid отличается

| Что | Почему |
|---|---|
| `libbox.aar` из исходников | prebuilt запрещён; апстрим sing-box пакуется так же |
| `libcronet.a` из исходников | `cronet-go` кладёт готовый блоб; собираем Chromium сами и сверяем с ним через `cmp`. **~50 минут на ABI** |
| Три APK по ABI | три build-блока, у каждого свои `--target-platform` и `LXBOX_ABI_FILTER` |
| Вырезана проверка JDK 17 | у них Debian trixie: JDK 21, пакета `openjdk-17` нет |
| Вырезан legacy-вариант AAR | gomobile требует SDK platform под каждый вариант |

Обе правки ядра делает один `sed` по `cmd/internal/build_libbox/main.go`.

⚠ **`--target-platform` НЕ фильтрует нативный код ядра.** Он сужает только движок
Flutter и Dart AOT, а `.so` из AAR (все три ABI) попадают в APK как есть — без
фильтра 31 → 71 МБ. Отсюда `LXBOX_ABI_FILTER` в
[build.gradle.kts](../app/android/app/build.gradle.kts): чистит `ndk.abiFilters`
и выкидывает чужие ABI через `packaging.jniLibs.excludes`.

### Грабли их buildserver

1. `make.bash` требует bootstrap-Go → `apt-get install golang-go` +
   `GOROOT_BOOTSTRAP`.
2. **Сканер работает МЕЖДУ `prebuild:` и `build:`.** Всё, собранное в `prebuild`,
   он видит как подозрительные бинарники и требует `scanignore`. Сборка ядра
   живёт в `build:` — тогда сканер видит только исходники.
3. `git -C $$srclib$$ checkout` **обязательно с `-f`**: fdroidserver чистит
   keysigning-конфиги в клоне Flutter, дерево грязное, и обычный checkout
   отказывается переключаться.
4. Сабмодулей ядра нужно **три**: `sing-tun`, `wireguard-go`, `gvisor`. Смотреть
   не в `.gitmodules` (там ещё три клиентских, тяжёлых), а в `go.mod` ядра:
   `grep -A15 '^replace' go.mod | grep '=> \./'`.
5. **`rewritemeta` проверяет порядок ключей и последний байт.** Порядок задан их
   схемой, не алфавитный: `Binaries` сразу за `Repo`, `AllowedAPKSigningKeys`
   перед `MaintainerNotes`. Отдельно падает на отсутствующем `\n` в конце файла.
   Диагноз не угадывать — джоба печатает готовый diff, применять буквально.
6. Дефолтный лимит GitLab на джобу — **1 час**, трём ABI не хватает. Поднят до 5
   через `build_timeout` в API проекта. Разброс раннеров велик: один и тот же
   Chromium собирался то 25, то 50 минут.
7. Первый запуск CI на GitLab требует верификации аккаунта (телефон/карта),
   иначе пайплайн падает как «yaml invalid» с нулём джобов.
8. **APK не должен нести `DEPENDENCY METADATA`.** AGP по умолчанию кладёт в
   APK Signing Block список зависимостей, зашифрованный ключом Google. Сканер
   F-Droid отвергает APK целиком: `Found extra signing block`. Гасится
   `dependenciesInfo { includeInApk = false }` в
   [`app/android/app/build.gradle.kts`](../app/android/app/build.gradle.kts);
   для AAB оставлено включённым — Google Play собирается из бандла.
9. **Пин на генерируемую ветку может отвалиться.** `cronet-go` держит собранные
   библиотеки в ветке `go_dev`, которую upstream переписывает: 6 августа наш пин
   вылетел из всех веток, и `git clone` перестал его доставать
   (`unable to read tree`). Лечится обновлением ядра: пин обязан совпадать с тем,
   что в `go.mod` ядра, а тот — быть достижим обычным клоном.

### Треды в MR закрывать явно

Замечания рецензентов живут в **тредах**, а не в общей ленте. Ответить текстом
мало — тред остаётся открытым, пока кто-то не нажмёт **Resolve**, и MR висит с
`blocking_discussions_resolved: false`. Для мейнтейнера это читается как «автор
ещё не ответил»: метка `waiting-for-upstream` не снимается, очередь проходит
мимо. На этом потеряли полтора суток — все замечания были закрыты делом, но
пять тредов висели неотмеченными.

Смотреть не ленту `notes`, а `discussions`:

```bash
curl -sS --header "PRIVATE-TOKEN: $(cat ~/.gitlab-token)" \
  "https://gitlab.com/api/v4/projects/36528/merge_requests/44731/discussions?per_page=100" \
  | python3 -c "import sys,json; print(sum(1 for d in json.load(sys.stdin) for n in d['notes'] if n.get('resolvable') and not n.get('resolved')), 'неразрешённых')"
```

Закрыть: `PUT .../discussions/<id>?resolved=true`.

## Воспроизводимость

Режим **включён**: `Binaries` (URL релизного APK, свой на каждый блок) и
`AllowedAPKSigningKeys` в метаданных. F-Droid собирает сам, скачивает наш APK,
сверяет побитово — и публикует **наш**, с нашей подписью. Установка из каталога
и с GitHub даёт одно приложение, обновления ходят в обе стороны.

⚠ **Обратной дороги нет.** Android не даёт обновлять приложение другим ключом:
снять `Binaries` — значит перевести каталог на подпись F-Droid, а это для
системы другое приложение. Потеря `upload-keystore.jks` = конец обновлениям.

⚠ **Каждый релиз обязан сходиться побитово**, иначе версия просто не выйдет в
каталог. Проверено на v2.20.6, все три ABI: **455 файлов, ноль расхождений**.

Расходились три нативные библиотеки:

| Файл | Причина | Решение |
|---|---|---|
| `libapp.so` | абсолютный путь сборки запечён в Dart AOT-снапшот | собирать по тому же пути, что и наш CI: `mv` в `/home/runner/work/LxBox/LxBox` в начале `build:` |
| `libflutter_zxing.so` | стороны передавали линкеру разные флаги | флаг задан один раз в `build.gradle.kts`, из метаданных убран |
| `libdartjni.so` | `.note.gnu.build-id` | `--build-id=none` |

⚠ **NDK ставит `-Wl,--build-id=sha1` безусловно** (`build/cmake/flags.cmake:72`,
обход старого LLDB). Название обманывает: lld хэширует выходной файл **до
strip**, вместе с отладочной информацией, где сидят абсолютные пути. В
поставляемый `.so` они не попадают — отсюда разный отпечаток при совпадающих
библиотеках. Замер на `libdartjni.so`: ровно **20 байт по смещению `0x2e0`**,
остальное идентично.

Флаг задан в [`app/android/build.gradle.kts`](../app/android/build.gradle.kts)
через `-DCMAKE_SHARED_LINKER_FLAGS`, а не в рецепте: сборка F-Droid использует
этот же файл, один источник на обе стороны. Механизм проверен сборкой, а не
выведен из документации — `-D` задаёт cache-переменную целиком, поэтому оба
исхода исключены измерением: секции `.note.gnu.build-id` нет, набор секций не
изменился. Запасной путь — патч
`add_link_options("LINKER:--build-id=none")` в `CMakeLists.txt` пакета.

⚠ **`--filesystem-root` не помогает** и никто в каталоге его не использует:
`flutter build apk` флага не принимает, а через `--extra-front-end-options` он
не доходит до `dartPluginRegistrantUri` (проверено сборкой).

### Как сверять

Распаковать оба APK, выкинуть `META-INF/`, сравнить SHA-256 пофайлово.

⚠ **`META-INF/` сверять отдельно:** там не только подпись (её сравнивать
бессмысленно — ключи разные), но и ~76 файлов версионных метаданных androidx,
которые иначе выпадут из проверки.

⚠ **Пофайловое сравнение не покрывает APK Signing Block.** Он лежит между
данными и Central Directory — вне zip-структуры, и `unzip` его не видит. На этом
обожглись: 455 файлов сходились, а `check apk` падал на 7185 байт
`DEPENDENCY METADATA`. Смотреть блоки по id:

```python
i = data.rfind(b'APK Sig Block 42')          # 0x504b4453 = DEPENDENCY METADATA
```

Разница в размере APK при полном совпадении содержимого нормальна: наш тяжелее
на ~12 КБ за счёт блока подписи v2/v3. `.RSA`-файла в архиве нет — подпись лежит
перед Central Directory, `keytool -printcert` на ней не работает, нужен
`apksigner verify --print-certs`.

## Схема versionCode

§379 — одна формула на оба канала, ABI сзади:

```
versionCode = ((major × 10000 + minor × 100 + patch) × 100 + PRE) × 10 + ABI
```

`PRE`: `01-49` = `-rc.N`, `50` = релиз, `51-98` = `-hotfixN`.
`ABI`: `0` universal, `1` armv7, `2` arm64, `4` x86_64.

Формула живёт только в [`scripts/version-code.sh`](../scripts/version-code.sh),
дублировать арифметику нельзя. Раскладка и правила стадий —
[§379](spec/tasks/379-version-code-from-version.md).

**Почему ABI сзади:** каталог сортирует версии по versionCode. С ABI впереди
(как делает Flutter при `--split-per-abi`: `ABI * 1000 + code`) x86_64-сборка
старого релиза оказывается «новее» armv7-сборки нового. Требование рецензента.

Поэтому на GitHub `--split-per-abi` убран — иначе Flutter домножил бы ABI поверх
нашего числа. Вместо прогона со сплитом — по прогону на таргет. Числа одного
релиза совпадают между GitHub и F-Droid.

### Автообновление

До §379 `checkupdates` не мог прочитать версию: `pubspec.yaml` держал
placeholder, а `versionCode` был числом коммитов — не функция от тега. Стоял
`UpdateCheckMode: None`, каждая версия требовала ручного MR.

```yaml
AutoUpdateMode: Version
UpdateCheckMode: Tags
VercodeOperation:
  - '%c + 1'
  - '%c + 2'
  - '%c + 4'
UpdateCheckData: app/pubspec.yaml|version:\s.+\+(\d+)|.|version:\s(.+)\+
CurrentVersion: 2.20.4
CurrentVersionCode: 22004504
```

`UpdateCheckData` читает из pubspec код с **ABI=0** (`2.20.4+22004500`),
`VercodeOperation` подставляет цифру ABI каждого блока. Операций столько же,
сколько build-блоков.

⚠️ Операция — `%c + ABI`, **не** `%c * 10 + ABI`. Умножение на 10 уже сидит
внутри формулы §379, и в pubspec попадает готовый код. Лишнее умножение даёт
`220045002` вместо `22004502` — на порядок больше, и откатить нельзя: Android не
принимает понижение `versionCode`. Прецедент `app.atrium` тут не помощник — у
него в pubspec код *без* ABI, поэтому там `* 10` уместно.

⚠ `AutoUpdateMode` — голое `Version`, без `v%v`. В режиме `Tags` реальный тег
известен из проверки и подставляется в `commit:` как есть (`checkupdates.py`:
`if tag: b.commit = tag`). Шаблон с `%v` схема отвергает.

### Цена трёх ABI

Кэша между блоками нет: каждый компилирует Go, Chromium и ядро заново. Один ABI
— 45-70 минут, три — **2-3 часа** (замеры на v2.20.4 и v2.20.6).
