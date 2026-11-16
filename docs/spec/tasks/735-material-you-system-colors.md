# 735 — Material You: опция «System colors» (палитра из обоев Android 12+)

| | |
|---|---|
| **Статус** | Draft — вариант Б и хранение в `vars` подтверждены владельцем 15.11.2026, реализовано в ветке; эмулятор Android 14 ОК, телефон, Android < 12 и TV не проверены |
| **Дата** | 2026-11-15 |
| **Повод** | [issue #218](https://github.com/Leadaxe/LxBox/issues/218), автор Az-1-2: «Feature request: Add material you design» |
| **Связанные** | [707 итер. 9 — тема из SharedPreferences в JSON](707-taildrop-send-receive-files.md), §206 (`banner_palette.dart`), §541 (вкладка Appearance), §622/§679 (TV) |

Номер: 734 оставлен параллельной сессии по issue #219 (она стартовала раньше и
номер ещё не заняла); сверено с `origin/develop` (последний — 733) и соседними
worktree.

## Docs to update

- эта задача
- `docs/STORAGE.md` — строка `dynamic_color` в таблице известных ключей `vars`
- `CHANGELOG.md` — Unreleased, Added
- контракт с лаунчером — **не трогается** (см. «Контракт и бэкап»)

## Problem

У приложения одна фиксированная палитра (seed `Colors.indigo`). Автор просит
Material You — динамические цвета Android 12+ (палитра из обоев) — или хотя
бы опцию, чтобы приложение выглядело как остальные системные.

## Diagnosis

### Как строится тема сейчас

- `app/lib/main.dart:360` — `static const _seed = Colors.indigo;` в `LxBoxApp`.
- `app/lib/main.dart:376-385` — `theme` / `darkTheme` = `ThemeData(colorScheme:
  ColorScheme.fromSeed(seedColor: _seed[, brightness: dark]), useMaterial3: true)`.
  Material 3 уже включён, весь UI берёт цвета из `ColorScheme` — подмена seed
  перекрашивает приложение целиком без правки экранов.
- `app/lib/main.dart:295-354` — `ThemeNotifier`: только `ThemeMode`
  (system/light/dark); перечитывается по `SettingsStorage.nativePrefsGeneration`
  (импорт бэкапа, смена Workspaces).
- Хранение режима темы: `native_prefs.app_theme_mode`
  (`app/lib/services/settings_storage/native_prefs.dart:37`, `:68-77`,
  `:151-164`), в зеркало Kotlin не идёт. Этот ключ — часть контракта бэкапа
  (`app/contract/schema/backup.schema.json:84`, `app/contract/docs/BACKUP.md:406`,
  контракт 1.1.158).
- UI: App Settings → Appearance, `app/lib/screens/app_settings_screen/widgets/appearance_tab.dart:45-66`
  (радиогруппа System/Light/Dark); рядом переключатели «Allow rotation» (скрыт
  на TV, `app_settings_screen.dart:707`) и «Two columns on wide screens».
- Эти два переключателя хранятся как app-флаги в `vars`
  (`app/lib/services/settings_storage.dart:308-309`, `:920-941`): поле
  `lxbox_settings.json`, едет в сыром снимке/Workspaces, **не** в LX Backup
  (в его секцию `vars` попадают только `portable` имена реестра контракта).

### Golden-тесты

`matchesGoldenFile` в `app/test` нет — ломаться нечему. Тесты, которые
проверяют конкретный цвет `ColorScheme`, не найдены.

### Цвета мимо `ColorScheme`

`grep` по `app/lib`: ~70 вхождений `Colors.<цвет>` в 26 файлах и 3 `Color(0x…)`.
Почти всё — **семантика статуса**, а не фирменный цвет, и от палитры не
зависит:

| Место | Что | При динамической палитре |
|---|---|---|
| `widgets/probe_badge.dart:31-33` | пинг: green / amber.800 / orange.800 | без изменений — стоит на поверхности, а у tonal spot поверхности почти нейтральные (chroma ≈ 6), контраст как сейчас |
| `widgets/node_row.dart:126-128, 210-212, 258-266, 296-299` | статус tailnet/узла: green/orange, плашка `green.withAlpha(.18)` | то же |
| `widgets/tailscale_network_tab.dart:1126, 1235, 1491-1493, 1739` | online/direct/derp: green/orange | то же |
| `widgets/banner_palette.dart:33-40` | warning/success — явные пресеты amber/green (§206), info/error — из `ColorScheme` | warning/success без изменений, info/error следуют палитре — так и задумано |
| `subscription_meta.dart:146`, `subscription_entry_tile.dart:125` | `0xFF2AABEE` — цвет значка Telegram | бренд Telegram, не трогаем |
| `main.dart:259-279` | экран фатальной ошибки: свой тёмный фон + white | не зависит от темы |
| `qr_scan_screen.dart:182-205`, `transfer_receive_screen.dart:253, 393` | оверлей камеры, QR-код чёрным на белом | не зависит от темы (QR должен быть ч/б) |
| `app_settings_screen.dart:946-947` | маска затухания `ShaderMask` | не цвет, а альфа |
| `widgets/lx_code_editor.dart:806-819` | цвета редактора Sora | берутся из `ColorScheme` — следуют палитре автоматически |
| `vpn/TaildropClipActivity.kt:443-453` | окно Send clipboard (своя Activity) | свои цвета по `night`, не Flutter-тема; остаётся как есть |
| `res/values/colors.xml` | фон иконок ярлыков Connect/Disconnect (§032) | иконки лаунчера, не тема |
| уведомление VPN, плитка QS | системные стили Android | не затрагиваются |

Вывод: при произвольной палитре ничего не становится нечитаемым. Единственное
заметное следствие — статусные зелёный/оранжевый могут «спорить» с
акцентом, если обои, например, оранжевые (акцент близок к цвету
предупреждения). Это эстетика, не читаемость; правка — отдельной задачей, если
владелец захочет.

### Как получить системную палитру

1. **Пакет `dynamic_color`** (material-foundation, BSD-3, без проприетарных
   библиотек — для F-Droid допустим). Последняя версия 2.1.0 (20.08.2026)
   тянет новую зависимость `material_ui ^1.0.0` (вынос Material из Flutter
   SDK) — её совместимость с нашим Flutter 3.47.1 и остальными пакетами не
   проверена, а это лишний риск для сборок трёх каналов.
2. **Свой метод в канале `com.leadaxe.lxbox/utils`** (`MainActivity.kt:119`):
   Android 12+ (API 31) отдаёт `android.R.color.system_accent1_500` — тон 50
   первичной тональной палитры, построенной системой из обоев. Dart строит
   схему `ColorScheme.fromSeed(seedColor: accent)` с вариантом по умолчанию
   `tonalSpot` — тот же вариант, которым Android строит системную палитру, оттенок
   совпадает. Отличие от «точной» системной схемы (пакет копирует все 65 тонов)
   — в долях процента насыщенности, на глаз незаметно. Ноль зависимостей,
   ~10 строк Kotlin.

Выбран **вариант 2**.

Ограничения платформы:

- **ниже Android 12** (minSdk 24) — системной палитры нет, метод отдаёт `null`,
  переключатель скрыт, тема индиго;
- **Android TV / Google TV** — Material You на TV не применяется (ресурсы
  `system_accent*` есть, но это статичная палитра, а не обои); метод отдаёт
  `null` при `isTelevision` (`MainActivity.kt:522`), переключатель скрыт;
- **смена обоев**: `assetsPaths` нет в `configChanges` (`AndroidManifest.xml:89`),
  Android 12+ пересоздаёт Activity; дополнительно акцент перечитывается при
  возврате приложения на передний план (`AppLifecycleState.resumed`), если
  опция включена.

### Контракт и бэкап

Флаг — app-флаг в `vars` (`dynamic_color`, `'true'|'false'`, дефолт `'false'`),
как соседние переключатели вкладки Appearance (`allow_rotation`,
`node_list_two_columns`). Правило «Где живёт настройка»
(`docs/ARCHITECTURE.md` → «Where a setting lives», п. 1) выполнено: поле
`lxbox_settings.json`. Kotlin его не читает — зеркала нет. Контракт с
лаунчером не меняется: у лаунчера нет темы Android, а LX Backup app-флаги
`vars` не переносит. Флаг едет в сыром снимке и в Workspaces.

Альтернатива — ключ `native_prefs.app_dynamic_color` рядом с
`app_theme_mode`: тогда он поедет и в LX Backup, но это изменение схемы
бэкапа, т. е. запрос лаунчеру и бамп контракта. Ради косметики не стоит —
вопрос владельцу ниже.

## Варианты

| Вариант | Что получает пользователь | Цена |
|---|---|---|
| **А. Не делать** | ничего; ответ автору «не планируем» | 0 |
| **Б. Опция «System colors», выключена по умолчанию** | переключатель в Appearance (Android 12+, не TV); у всех текущих пользователей вид не меняется | ~10 строк Kotlin, ~60 строк Dart, 2 строки l10n × 2 языка, тест; контракт не трогается |
| **В. То же, включено по умолчанию** | все на Android 12+ после обновления видят приложение в цветах обоев | как Б + заметная смена вида у всей аудитории, скриншоты в сторах/доках перестают совпадать, жалобы «куда делся синий» |

**Решение по умолчанию: Б** (подтверждено владельцем 15.11.2026). Запрос разумный и
частый, изменение маленькое и изолированное, существующий вид не меняется.
Переход Б → В позже — смена одного дефолта.

## Solution (вариант Б, реализовано)

1. Kotlin, `MainActivity.kt`, канал `utils`: метод `systemAccentColor` →
   `Int` ARGB `system_accent1_500` на API ≥ 31 и не на TV, иначе `null`.
2. Dart, `UrlLauncher.systemAccentColor()` (рядом с `isTelevision`) —
   `Color?`, ошибка канала → `null`.
3. `app/lib/services/app_theme_seed.dart`: `kAppSeedColor = Colors.indigo` и
   чистая `appThemeSeed(dynamicColor, systemAccent)` — акцент, только если опция
   включена и акцент есть.
4. `SettingsStorage.getDynamicColor/setDynamicColor` — var `dynamic_color`,
   добавлен в `_appFeatureFlagVars`.
5. `ThemeNotifier`: поля `dynamicColor`, `systemAccent`, геттеры `seed`,
   `dynamicColorAvailable`; `load()` читает флаг и акцент; `_reload()` (импорт,
   Workspaces) перечитывает и флаг; при `resumed` акцент перечитывается, если
   опция включена; `setDynamicColor`.
6. `LxBoxApp`: seed — `themeNotifier.seed` для светлой и тёмной схемы.
7. Appearance: `SwitchListTile` «System colors» под выбором темы, только если
   `dynamicColorAvailable`.
8. l10n: ключи «System colors» и «Use the accent color from your wallpaper
   (Material You, Android 12+).» — ru, zh.

## Risks and edge cases

- Флаг `true` пришёл снимком на устройство без палитры (Android < 12, TV) —
  схема индиго, переключатель скрыт; флаг сохраняется.
- Обои с акцентом, близким к оранжевому/зелёному, — статусные цвета теряют
  отличие от акцента (см. «Цвета мимо ColorScheme»). Читаемость не страдает.
- Прошивки, где `system_accent1_500` не связан с обоями (часть кастомных
  оболочек), отдадут свой фирменный цвет — это и есть «системный цвет» с точки
  зрения ОС, приемлемо.
- Окно Send clipboard (Kotlin) и системное уведомление остаются в своих цветах.

## Verification

- `flutter analyze` по изменённым файлам; unit-тест `appThemeSeed` и
  round-trip флага в хранилище (`test/services/app_theme_seed_test.dart`).
- CI build-fast 43747440123 на 7fffa9dd зелёный (Kotlin компилируется).
- **Эмулятор LxBox_test (Android 14), 15.11.2026, APK 2.25.22-rc.2-dev.19** —
  скриншоты `.claude/emu-shots/735-*.png`; системная палитра менялась через
  `settings put secure theme_customization_overlay_packages` (`system_palette`):

| Сценарий | Результат |
|---|---|
| 1 установка поверх: флага нет, вид индиго, переключатель «System colors» виден, выключен | прошёл (735-02) |
| 2 включение: `vars.dynamic_color = 'true'`, seed = акцент системы | прошёл (735-03) |
| 3 палитра E91E63 при открытом приложении: перекраска в розовый (главный, Servers, подписка, тест серверов — `err` красным читается) | прошёл (735-04..07) |
| 4 тёмная тема в розовой палитре | прошёл (735-08) |
| 5 выключение при розовой палитре: снова индиго, `dynamic_color = 'false'` | прошёл (735-09) |
| 6 смена палитры (4CAF50) при приложении в фоне → возврат | прошёл со второго раза: первый снимок через 4 с — чёрный экран (эмулятор пересоздаёт Activity медленно); повтор с FF9800 и паузой 12 с — оранжевый (735-12) |
| 7 холодный старт с включённой опцией | прошёл, зелёный (735-11) |

  Наблюдение: смена системной палитры пересоздаёт Activity (`relaunch` в
  logcat), приложение возвращается на главный экран. Так ведёт себя и
  выключенная опция, и сборка до задачи — вне 735. ANR «System UI / Process
  system isn't responding» — системные процессы эмулятора под нагрузкой, не
  L×Box. Эмулятор возвращён в исходное (палитра `home_wallpaper`, тема Light,
  опция выключена).
- **Не проверено:** Android < 12 и TV (переключатель скрыт — только по коду),
  телефон.

## Вопросы владельцу

1. ~~Вариант Б или сразу В?~~ — Б, слово владельца 15.11.2026.
2. ~~Хранить флаг в `vars` или в `native_prefs` с бампом контракта?~~ — `vars`,
   без контракта, LX Backup флаг не несёт; слово владельца 15.11.2026.
3. ~~Подстраивать ли статусные цвета (пинг, tailnet, warning/success) под
   палитру?~~ — нет, остаются фиксированными; слово владельца 15.11.2026.
4. Ответ автору #218 — черновик в отчёте сессии; публиковать после релиза или
   сразу?

## Unresolved / follow-up

- Проверка на эмуляторе Android 12+ и на TV.
