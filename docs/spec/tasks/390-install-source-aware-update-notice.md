# §390 — канал установки: уведомление о новой версии ведёт в свой стор

| Поле | Значение |
|------|----------|
| Статус | Done, DEVICE-VERIFIED (эмулятор, 11.08.2026) |
| Дата старта | 2026-08-11 |
| Дата завершения | 2026-08-11 |
| Связанные spec'ы | §036 — update check (`UpdateChecker`, SnackBar + About-блок); §274 — паттерн исчезающей всплывашки снизу; §166 — «всплывашка снизу, не баннер»; §356/§357 — support-лента (соседняя очередь показов на старте); §221 — симметрия allowlist ↔ export; §279/§285 — l10n natural keys |
| Docs | `docs/FDROID.md`, `docs/RELEASE_PROCESS.md`, `docs/BUILD.md`, `docs/STORAGE.md`, `CHANGELOG.md` |

## Проблема

До сих пор канал распространения был один — GitHub Releases. `UpdateChecker`
(§036) опрашивает `api.github.com/releases/latest` и при новой версии показывает
снек «L×Box vX available» с кнопками **View** (страница релиза) и **Later**.

С выходом в Google Play и F-Droid каналов становится три, и оба новых ломаются
на одном и том же: **кнопка ведёт на GitHub**.

1. **Google Play.** APK с GitHub подписан нашим ключом, Play-сборка — ключом
   Google (Play App Signing). Установка поверх падает с «signatures do not
   match»: пользователь по нашей же кнопке приходит в тупик. Отдельно —
   политика Device and Network Abuse запрещает обновлять приложение в обход
   Play, а кнопка на сторонний APK ровно это и предлагает.
2. **F-Droid.** Третья, тоже несовместимая подпись (F-Droid подписывает своим
   ключом). Плюс версия в каталоге отстаёт: сборка трёх ABI ≈ 3 часа + ревью.
3. **GitHub.** Здесь ссылка верная.

Приложение сейчас **не знает**, откуда оно установлено.

Вторая проблема, вскрытая при разборе (§036, не регресс этой таски): снек
всплывает **при каждом холодном старте**, пока пользователь не обновится.
Throttle 24 ч стоит на сетевом чеке, а показ идёт ещё и из кеша — гидрацией,
которой throttle не касается. Единственный глушитель — кнопка «Later».

## Решение

Ввести **install source** (канал установки) и переработать модель показа.

### Определение канала

Гибрид: build-time значение — источник истины, рантайм-детект — фолбэк.

```
InstallSource.current
  ├─ 1. --dart-define=LXBOX_DISTRIBUTION=play|fdroid|github  (String.fromEnvironment)
  │      └─ задано → используем как есть, рантайм не спрашиваем
  └─ 2. фолбэк: native getInstallSourceInfo().installingPackageName
         ├─ com.android.vending                      → play
         ├─ org.fdroid.fdroid | org.fdroid.basic | … → fdroid
         └─ всё остальное / null                     → github  (sideload — дефолт)
```

Почему так:

- **`--dart-define` первичен** — в момент сборки мы точно знаем адресата
  артефакта. Play и GitHub — наш CI, флаг ставится тривиально. F-Droid — их
  buildserver, флаг задаётся в рецепте `fdroiddata` (`build:`-блок уже вызывает
  `flutter build apk`). Прецеденты живые: `LXBOX_SUPPORT_URL` (§356) и
  `DONATE_URL` читаются через `String.fromEnvironment`, `LXBOX_ABI_FILTER`
  прокидывается через env в `build.gradle.kts`.

  ⚠ Это **не откат §065/§066.** Там убирались *версионные* маркеры
  (`BUILD_LOCAL`, `BUILD_GIT_DESC`) — версия переехала в `pubspec.yaml`, у факта
  появился единственный источник истины. Канал доставки в pubspec выразить
  нельзя: один коммит и одна версия уезжают в три стора.

- **Рантайм — фолбэк.** `installingPackageName` врёт в обе стороны: sideload
  через сторонний стор даст непонятный installer, установка из файлового
  менеджера — `null`. Как фолбэк для локальных и dev-сборок достаточно.
- **Дефолт `github`** — самый безопасный: ошибочно замолчать хуже, чем
  ошибочно показать.

#### Таблица installer → канал

| `installingPackageName` | Канал |
|---|---|
| `com.android.vending` | `play` |
| `org.fdroid.fdroid`, `org.fdroid.basic`, `com.looker.droidify` | `fdroid` |
| `null`, `com.android.packageinstaller`, `com.android.shell`, браузеры, файловые менеджеры | `github` |
| любой другой | `github` |

⚠ **Obtainium** (`dev.imranr.obtainium`) ставит APK **с GitHub** — подпись наша,
GitHub-ссылка валидна. Он попадает в `github`, несмотря на «сторонний стор».
Правило: в `fdroid` только клиенты каталога F-Droid.

### Модель показа — единая для всех каналов

Каналы отличаются **только адресом**, куда ведёт переход. Поведение снека
одинаковое везде.

| Свойство | Поведение |
|---|---|
| Когда | **только на старте**, на первом кадре, из кеша `last_known_version` |
| Как часто | не чаще одного раза за запуск приложения |
| Длительность | 6 секунд, `SnackBarBehavior.floating`, свайп-dismiss |
| Клик по телу | переход в стор своего канала + глушение как «Later» |
| Кнопка **Later** | убрать; покажем снова при следующем запуске |
| Кнопка **Ignore** | про эту версию больше не напоминаем; вернёмся, когда выйдет следующая |

Никаких других вариантов показа: сетевой результат в текущей сессии снек
**не** поднимает.

#### Почему «строго из кеша»

Сейчас путей показа два: `hydrate()` (кеш, первый кадр) и реакция на успешный
сетевой `maybeCheck()` (+5 сек). Второй и создаёт «всплывает посреди работы».

Решение — **снять реакцию на сетевой результат**. Чек продолжает ходить в сеть
и писать `last_known_version`, но показ этой новости откладывается до
**следующего** запуска, где её подхватит `hydrate()`.

```
запуск N:   hydrate() → кеш пуст/старый → молчим
            +5 сек: сетевой чек → last_known_version = v2.18.0   (снек НЕ показан)
запуск N+1: hydrate() → кеш v2.18.0 новее локальной → снек
```

Цена: новость опаздывает на один запуск. Это сознательный размен — уведомление
никогда не выскакивает поверх работающего приложения.

Технически: `UpdateChecker.latest` продолжает жить (About-блок и §047-эмиттер
на нём завязаны), но `home_screen` **перестаёт** показывать снек по listener'у.
Показ вызывается один раз из `hydrate()`-ветки.

#### Дедуп: три уровня

| Уровень | Ключ / поле | Живёт | Что глушит |
|---|---|---|---|
| В пределах запуска | `_updateSnackbarShown` (поле `State`) | до убийства процесса | повторный показ в той же сессии |
| «Later» / клик по телу | `deferred_update_version` (новый) | до следующего запуска | ничего не глушит между запусками — см. ниже |
| «Ignore» | `dismissed_update_version` (существующий) | навсегда для этого тега | все показы этой версии |

⚠ **`deferred_update_version` не нужен как persist-ключ.** «Later» означает
«покажем при следующем запуске», а показ и так один за запуск — внутрипроцессного
флага `_updateSnackbarShown` достаточно. Ключ **не заводим**: «Later» просто
скрывает снек (`hideCurrentSnackBar`), запись в storage не делается.

Итого новых ключей хранилища — **ноль**. «Ignore» переиспользует существующий
`dismissed_update_version` (§036), который уже в §221-allowlist и в export.

#### Куда ведёт переход

| Канал | URL | Фолбэк |
|---|---|---|
| GitHub | `ProjectLinks.releaseTag(tag)` — страница релиза | — |
| Play | `market://details?id=com.leadaxe.lxbox` | `https://play.google.com/store/apps/details?id=com.leadaxe.lxbox` при `ActivityNotFoundException` |
| F-Droid | `https://f-droid.org/packages/com.leadaxe.lxbox/` | — (обычный https) |

⚠ `market://` без установленного Play роняет `startActivity` — а устройства без
GMS ровно наша аудитория. Нужен `try/catch` в `MainActivity.openUrl`.

Ссылка **в свой стор** политику Play не нарушает: Device and Network Abuse
запрещает обновление в обход стора, а здесь обновление идёт через стор.

### Про Play In-App Updates API — не берём

Официальный способ спросить у Play «есть ли новая версия» — `AppUpdateManager`
(Play Core). Отклонён:

| Минус | Детали |
|---|---|
| Зависимость от GMS | на устройствах без Google-сервисов не работает |
| F-Droid не примет | проприетарный блоб, сборка из исходников обязательна |
| Дублирует то, что есть | наш чек уже знает последнюю версию — код и версия во всех каналах одни |

Известная цена отказа: релиз доезжает в Play через ревью, поэтому наш чек может
сказать «есть v2.18.0», когда Play её ещё раскатывает — пользователь придёт в
стор и увидит старую. Лечится тем, что переход ведёт в стор: там видно
фактическое состояние. Если окно ревью окажется большим и пойдут жалобы —
отдельная таска.

### Что НЕ делается

| Не делается | Почему |
|---|---|
| Play Core / In-App Updates | см. выше |
| Разные `latest.json` по каналам | версия одна, отличается только доставка |
| Скрывать канал от пользователя | наоборот, показывается в About — диагностика в багрепортах |
| Показ снека по сетевому результату в текущей сессии | сознательно снято, см. «строго из кеша» |

## Изменения

### 1. `app/lib/services/install_source.dart` — новый

```dart
enum InstallSource { github, play, fdroid }
```

- `InstallSource.current` — резолвится один раз, кешируется в `late final`.
- `Future<void> InstallSourceResolver.init()` — из `main.dart` рядом с
  `VersionInfo` (тот же паттерн: резолв до первого UI-кадра). Читает
  `String.fromEnvironment('LXBOX_DISTRIBUTION')`; если пусто — нативный вызов,
  маппинг по таблице.
- `String updateUrl(String tag)` — адрес перехода (таблица выше). Один метод
  вместо булева флага: вызывающему не нужно знать канал.
- `String get label` → `'GitHub'` / `'Google Play'` / `'F-Droid'` — About и
  дамп версии (§378).
- Чистая функция `installSourceFromInstaller(String? pkg)` — вынесена для
  тестов без `MethodChannel`.

Дефолт при любой ошибке — `github` + `AppLog.warning`.

### 2. `MainActivity.kt` — метод `installSource` в канале `com.leadaxe.lxbox/utils`

Канал существует (`openUrl`, `hasCamera`, `canSaveToDownloads`, …), добавляется
один `when`-кейс + хелпер:

```kotlin
private fun installerPackageName(): String? = try {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        packageManager.getInstallSourceInfo(packageName).installingPackageName
    } else {
        @Suppress("DEPRECATION")
        packageManager.getInstallerPackageName(packageName)
    }
} catch (_: Throwable) { null }
```

Возвращает **сырой** package name; маппинг — на Dart-стороне (одно место,
покрыто unit-тестами).

⚠ `minSdk = 24` — ветка `getInstallerPackageName` обязательна, не косметика.

### 3. `MainActivity.openUrl` — `try/catch` на `market://`

`startActivity(Intent(ACTION_VIEW, …))` оборачивается: при
`ActivityNotFoundException` — повтор с https-формой. Общий фикс канала,
полезен и вне таски.

### 4. `project_links.dart`

`playPage` (`market://…`), `playPageWeb` (`https://play.google.com/…`),
`fdroidPage` (`https://f-droid.org/packages/com.leadaxe.lxbox/`).

### 5. `home_dialogs.dart` — `maybeShowUpdateSnackbar`

Read-guard прежний (`dismissed == info.tag` → выход). Снек:

- 6 секунд, `SnackBarBehavior.floating`;
- **тело кликабельно** — `InkWell`/`GestureDetector` вокруг `content`: скрыть
  снек + `UrlLauncher.open(InstallSource.current.updateUrl(info.tag))`.
  Персиста нет — ведёт себя как «Later»;
- кнопка **Later** — `hideCurrentSnackBar()`, без персиста;
- кнопка **Ignore** — `UpdateChecker.I.dismissCurrent()` (уже пишет
  `dismissed_update_version` + чистит notifier).

⚠ **Тело — `InkWell`, а не `GestureDetector`** (выяснено при реализации).
`SnackBar` рендерит `content` внутри собственного `Material`, и жест из
`GestureDetector` проигрывает конкуренцию его ink-слою: тап уходит в
`_RenderInkFeatures` и обработчик молча не вызывается. `InkWell` встраивается в
тот же слой. Плюс `SizedBox(width: double.infinity)` внутри — иначе кликабельна
только строка глифов, а не вся область.

⚠ Раскладка адаптивная: на ширине < 320dp текст и две кнопки в ряд не
помещаются — кнопки уезжают под текст (`Column`).

⚠ `onShown()` вызывается всегда — иначе `_updateSnackbarShown` не выставится.

### 6. `home_screen.dart` — снять показ по сетевому результату

- `_onLatestUpdateChanged` **больше не показывает** снек. Listener остаётся
  только если нужен для другого (иначе снимается вместе с
  `removeListener` в `dispose`).
- Показ — один вызов из `hydrate()`-ветки: `unawaited(UpdateChecker.I.hydrate(...))`
  завершился → если `latest.value != null`, показать снек в
  `addPostFrameCallback`.
- `_updateCheckTimer` (+5 сек) остаётся: сеть ходит, `last_known_version`
  пишется, снек не поднимается.

⚠ Порядок со стартовым визардом и support-лентой (§356): снек встаёт в очередь
`ScaffoldMessenger`, а визард — диалоги поверх. Пересечения нет, но проверить,
что снек не съедается `clearSnackBars()` из соседних флоу.

### 7. `about_screen.dart` — `_UpdateBlock`

- Ссылка ведёт на `InstallSource.current.updateUrl(info.tag)` вместо жёсткого
  `htmlUrl`.
- Строка «Installed from: %s» с `label` — постоянная, во всех каналах.

### 8. `update_checker.dart` — без изменений

Сетевой чек одинаков везде: `latest.json` / GitHub API отвечает на вопрос
«какая версия последняя», а не «откуда качать». `AutomationEventEmitter` (§047)
продолжает эмитить `update_available` во всех каналах.

### 9. CI + F-Droid рецепт

| Где | Что |
|---|---|
| `ci.yml`, шаг «Build APKs» | `--dart-define=LXBOX_DISTRIBUTION=github` во все вызовы `build_one` |
| `ci.yml`, шаг «Build AAB (Google Play)» | `--dart-define=LXBOX_DISTRIBUTION=play` |
| `fdroiddata`, все три build-блока | `--dart-define=LXBOX_DISTRIBUTION=fdroid` |
| `scripts/build-local-apk.sh` | не трогаем — фолбэк даст `github`, что верно |

⚠ Правка рецепта `fdroiddata` — **ручной MR** (автоподхват версии по тегу
рецепт не меняет, см. `docs/FDROID.md`). До мержа F-Droid-сборки детектятся
рантайм-фолбэком по `org.fdroid.fdroid` — то есть корректно; MR делает детект
детерминированным, но не блокирует.

## Тесты

`app/test/services/install_source_test.dart` — чистый маппинг, без device:

| Вход | Ожидание |
|---|---|
| define `play` + installer `org.fdroid.fdroid` | `play` (define приоритетнее) |
| define пуст + `com.android.vending` | `play` |
| define пуст + `org.fdroid.fdroid` / `org.fdroid.basic` | `fdroid` |
| define пуст + `null` / `com.android.shell` | `github` |
| define мусорный (`=xyz`) | `github` + warning |
| `updateUrl` в каждом канале | play → `market://…`, fdroid → `f-droid.org/…`, github → `releases/tag/…` |

Widget-тесты снека (`app/test/screens/update_snackbar_test.dart`):

| Кейс | Ожидание |
|---|---|
| показ | есть **Later** и **Ignore** |
| тап по телу | `UrlLauncher` вызван с `updateUrl` канала + `fallbackUrl`; `dismissed` **не** записан |
| тап «Later» | снек скрыт; `dismissed` **не** записан; `openUrl` не вызван |
| тап «Ignore» | `dismissed_update_version == info.tag` |
| `dismissed == tag` заранее | снек не показан (`onShown` не вызван) |
| github / play / fdroid | каждый ведёт на свой адрес |
| ширина 320dp | обе кнопки на месте, исключений нет |

### Грабли widget-тестов (выяснено при реализации)

Четыре независимые ловушки, каждая даёт либо вечный hang, либо **ложно-зелёный**
тест. Все обойдены в файле, но при правке легко вернуть.

| Грабля | Симптом | Обход |
|---|---|---|
| `SettingsStorage` = реальный файловый I/O | тест виснет на первом `await` — в fake-async зоне `testWidgets` диск не движется | всё storage-касание внутри `tester.runAsync` |
| `unawaited(...)` в обработчиках | side-effect не успевает случиться к моменту `expect` | опрос в цикле внутри `runAsync` (до 500 мс) |
| тап во время въездной анимации снека | `tap()` берёт старые координаты, **промахивается и молча ничего не вызывает** | `pump(800ms)` после показа, до тапов |
| промах `tap()` — лишь warning | тест «проходит», ничего не нажав; кейсы вида «проверяем ОТСУТСТВИЕ записи» ложно-зелёные | `WidgetController.hitTestWarningShouldBeFatal = true` в `setUp` |
| `dismissCurrent()` читает `latest.value` | «Ignore» ничего не пишет — notifier пуст | заполнить `UpdateChecker.I.latest.value` в `setUp` |

Прецедент по первой грабле уже был: `startup_wizard_test.dart` обошёл её
отказом от `testWidgets` в пользу `test()`. Здесь так нельзя — нужен реальный
рендер снека.

## Критерии приёмки

1. Снек появляется **только на старте** и не чаще одного раза за запуск.
   Во время работы приложения не всплывает никогда.
2. Новость из сетевого чека показывается на **следующем** запуске.
3. **Later** — снек вернётся при следующем запуске. **Ignore** — не вернётся
   для этой версии; при следующем релизе вернётся.
4. Клик по телу открывает нужный адрес по каналу и ведёт себя как «Later».
5. Play-сборка: переход в Play; F-Droid: на `f-droid.org`; GitHub: на релиз.
6. Устройство **без GMS**: клик в Play-режиме не роняет приложение —
   открывается https-форма.
7. Локальная сборка `build-local-apk.sh` — как `github`.
8. About на всех каналах: «Installed from: …» с верным лейблом.
9. `flutter analyze` + `flutter test` зелёные; l10n-чекеры (§285) проходят.

## Device-верификация

Проведена 11.08.2026 на эмуляторе `sdk_gphone64_arm64` (Android 15, образ с
Google Play). Метод: три release-сборки с разными `--dart-define`, версия
занижена до `2.0.0` (`--build-name`), чтобы реальный релиз `v2.20.6` с GitHub
стал «новее» — весь путь проверен на живых данных, без подмены кеша.

| Кейс | Результат |
|---|---|
| define `play` | ✅ About: «Установлено из Google Play», кнопка «Открыть в Google Play» |
| define `fdroid` | ✅ «Установлено из F-Droid», кнопка «Открыть в F-Droid» → `f-droid.org/packages/…` |
| define `github` | ✅ «Установлено из GitHub», кнопка «Открыть релиз» → `github.com/Leadaxe/Lx…` (регресса нет) |
| define перебивает рантайм | ✅ пакет ставился через `adb` (`installerPackageName=null`), но About показал канал из define |
| снек на старте | ✅ «Доступна L×Box v2.20.6 (у вас v2.0.0)» + «Позже» / «Не напоминать», раскладка в две строки |
| клик по телу → стор | ✅ `market://` не зарезолвился → **сработал https-фолбэк**, открылась `play.google.com/store/…` |
| «Позже» | ✅ `dismissed` НЕ записан; после `force-stop` снек вернулся |
| «Не напоминать» | ✅ `dismissed_update_version = v2.20.6`; после `force-stop` снек молчит |
| `dismissed` глушит и другой канал | ✅ F-Droid-сборка с тем же тегом в `dismissed` — снека нет, About «Обновлений нет» |
| «Проверить сейчас» | ✅ форс-чек обходит `dismissed`, блок показывает версию + ссылку канала |

⚠ **`market://` не открылся даже при установленном `com.android.vending`** —
на эмуляторе intent не резолвится. То есть https-фолбэк это не редкий путь для
устройств без GMS, а вполне рабочий сценарий; без него была бы поймана
`ActivityNotFoundException`. Проверка на реальном устройстве с живым Play
(должен открыться клиент стора, а не браузер) остаётся.

### Не проверено

| Кейс | Почему |
|---|---|
| Реальный installer `com.android.vending` / `org.fdroid.fdroid` | нужна установка из настоящего стора; рантайм-фолбэк покрыт unit-тестами |
| Устройство без GMS | образ эмулятора с Play; впрочем фолбэк отработал и здесь |
| «Только на старте» при живом сетевом чеке | throttle 24 ч не дал повторный чек в сессии; логика покрыта тем, что listener снят (код) + widget-тестом |

### Грабли верификации

| Грабля | Симптом |
|---|---|
| debug-сборка не встаёт поверх release | `INSTALL_FAILED_UPDATE_INCOMPATIBLE` — ровно проблема §390 в миниатюре. Решение: собирать release с тем же keystore, `uninstall` не нужен |
| `adb shell input tap` промахивается по кнопке снека | снек уходит (визуально «сработало»), но обработчик не вызван — выглядит как баг персиста. Проверять по факту записи, а не по исчезновению снека |
| снек живёт 6 с | скриншот на 9-й секунде застаёт пустой экран; тапать сразу после старта |
| сборка переписывает `pubspec.yaml` и `libbox.version` | placeholder версии и пин ядра — откатывать перед коммитом |

## Docs to update

| Файл | Что |
|---|---|
| `CHANGELOG.md` | Unreleased: уведомление ведёт в свой стор; показ только на старте, кнопки Later/Ignore |
| `docs/STORAGE.md` | семантика `dismissed_update_version` расширена — теперь пишется кнопкой «Ignore», не «Later» |
| `docs/FDROID.md` | «Чем сборка отличается» — `--dart-define=LXBOX_DISTRIBUTION=fdroid`; в «Обновление на новый релиз» — что флаг живёт в рецепте и при ручном MR не теряется |
| `docs/BUILD.md` | таблица dart-define'ов: `LXBOX_DISTRIBUTION` (значения, дефолт, кто ставит); уточнить строку «`--dart-define`-маркеры убраны в §065/§066» — она про версионные маркеры, не про механизм |
| `docs/RELEASE_PROCESS.md` | публикация в Play: AAB собирается с `=play`; подписи Play/GitHub/F-Droid взаимно несовместимы |
| `docs/ARCHITECTURE.md` | `install_source.dart` в дереве сервисов |
| `docs/spec/features/036 update check/spec.md` | модель показа изменена — сослаться на §390 |
