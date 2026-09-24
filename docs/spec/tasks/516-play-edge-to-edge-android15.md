# 516 — Рекомендация Play «Отображение от края до края»: источник найден в эмбеддинге Flutter

| Поле | Значение |
|------|----------|
| Статус | **Released в v2.25.2** (24.09.2026). Закрыта без правки кода (WONTFIX по существу): источник — эмбеддинг Flutter, у нас вызовов нет |
| Дата | 2026-09-24 |
| Повод | Google Play Console, рекомендация к выпуску 2.25.1: «Отображение от края до края может работать не у всех пользователей… для обратной совместимости вызовите `enableEdgeToEdge()`» |
| Первоисточник | [Android 15 behavior changes → Edge-to-edge enforcement](https://developer.android.com/about/versions/15/behavior-changes-15#edge-to-edge) |
| Связанные | [§429](429-bottom-inset-system-navigation.md) (нижний отступ, DEVICE-VERIFIED), [§448](448-bottom-inset-contract-sheet-file-exemption.md) (та же рекомендация разбиралась для 2.24.0, AVD API 35) |

## Что говорит первоисточник

Документ делит API на две группы. **Deprecated и отключённые** (no-op при
targetSdk ≥ 35):

- `R.attr#statusBarColor`, `Window#setStatusBarColor`, `Window#getStatusBarColor`
- `R.attr#navigationBarColor` и `Window#setNavigationBarColor` — **только для
  жестовой навигации**; для трёхкнопочной продолжают действовать (с 80 % альфы)
- `R.attr#navigationBarDividerColor`, `Window#setNavigationBarDividerColor`,
  `Window#getNavigationBarDividerColor`, `Window#getNavigationBarColor`
- `Window#setDecorFitsSystemWindows`

**Deprecated, но работают:** `R.attr#enforceStatusBarContrast`,
`Window#setStatusBarContrastEnforced`, `Window#isStatusBarContrastEnforced`,
`R.attr#navigationBarColor` и `Window#setNavigationBarColor` для трёхкнопочной.
`setNavigationBarContrastEnforced` на жестовой навигации не действовал и раньше.

Отдельно: `layoutInDisplayCutoutMode` нефлоатящих окон трактуется как
`ALWAYS` независимо от заданного значения; `Configuration.screenWidthDp` /
`screenHeightDp` больше не исключают системные панели.

Рекомендованный путь — `enableEdgeToEdge()` из `androidx.activity` ≥ 1.8 плюс
разбор `WindowInsets`; `windowOptOutEdgeToEdgeEnforcement` назван **временным**
опт-аутом, и он перестаёт действовать начиная с targetSdk 36.

## Что триггерит рекомендацию у нас

Своих вызовов нет ни одного. Полный grep по `app/android` (`*.kt`, `*.java`,
`*.xml`) по `statusBarColor|navigationBarColor|navigationBarDividerColor|
setDecorFitsSystemWindows|FLAG_TRANSLUCENT|systemUiVisibility|
enforceStatusBarContrast|enforceNavigationBarContrast|windowOptOutEdgeToEdge` —
**пусто**. Grep по `app/lib` по `setSystemUIOverlayStyle|
setEnabledSystemUIMode|AnnotatedRegion|SystemUiOverlayStyle|statusBarColor|
systemNavigationBarColor|systemNavigationBarContrastEnforced` — тоже **пусто**:
приложение вообще не трогает стиль системных панелей из Dart. В `main.dart` из
`SystemChrome` вызывается только `setPreferredOrientations`. В `styles.xml`
(`values/` и `values-night/`) — только `windowBackground`; опт-аута нет и не
ставится.

Вызовы, которые видит сканер Play, приходят из **эмбеддинга Flutter**. Разбор
`flutter_embedding_release-1.0.0-5d53178869…jar` (Flutter 3.47.1) через
`javap -p -c` даёт три класса:

| Класс | Вызов | Гейт в байткоде |
|---|---|---|
| `FlutterActivity`, `FlutterFragmentActivity` → `configureStatusBarForFullscreenFlutterExperience()` | `Window.setStatusBarColor(0x40000000)` | `SDK_INT < 35` (`bipush 35; if_icmpge`) |
| то же | `addFlags(FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)`, `decorView.setSystemUiVisibility(1280)` | без гейта, но оба не в списке отключённых |
| `PlatformPlugin.setSystemChromeSystemUIOverlayStyle()` | `setStatusBarColor` | `SDK_INT < 35` |
| то же | `setNavigationBarColor` | `SDK_INT ≥ 26 && < 35` |
| то же | `setNavigationBarDividerColor` | `SDK_INT ≥ 28 && < 35` |
| то же | `setStatusBarContrastEnforced`, `setNavigationBarContrastEnforced` | `SDK_INT ≥ 29` — и это API из группы «deprecated, но работают» |
| `PlatformPlugin.enableEdgeToEdge()` | `WindowCompat.setDecorFitsSystemWindows(window, false)` + `setSystemUiVisibility(0)` | вызывается при `SystemUiMode.edgeToEdge` и при `SDK_INT ≥ 29` из `setSystemChromeEnabledSystemUIMode` |

То есть **Flutter 3.47.1 уже закрыл все отключённые API рантайм-гейтом
`SDK_INT < 35`**. На Android 15 ни один из них не исполняется. Сканер Play
статический: он видит ссылки в constant pool и не читает ветвления, поэтому
рекомендация выдаётся, хотя на устройстве вызовов нет.

## Почему `enableEdgeToEdge()` в `MainActivity` не нужен

`enableEdgeToEdge()` из `androidx.activity` делает ровно две вещи:
`setDecorFitsSystemWindows(window, false)` и прозрачные панели. Первое при
targetSdk 36 — состояние по умолчанию (система принудительно рисует
edge-to-edge, а `setDecorFitsSystemWindows` вообще no-op), второе — тоже
дефолт Android 15. Приложение и так рисуется от края до края: это зафиксировано
в §429 («Android рисует приложение edge-to-edge… панель навигации ложится
ПОВЕРХ нижнего края окна»).

Добавление вызова потребовало бы новой зависимости `androidx.activity` (сейчас
её в `app/build.gradle.kts` нет — только `core-ktx`, `lifecycle-runtime-ktx`,
`kotlinx-coroutines-android`; транзитивно она приходит из эмбеддинга), при нуле
изменений в поведении. Ссылки на deprecated-API из jar-а эмбеддинга оно тоже не
уберёт — рекомендация Play не исчезнет. Поэтому правка не делается.

## Состояние отступов

- **Низ** — §429: `showAppBottomSheet` (`SafeArea(top: false)` вокруг контента
  всех 26 шторок) и `EdgeInsets.withSafeBottom(context)` у 18 скроллеров.
  Стережёт `test/contract/bottom_inset_contract_test.dart` +
  `bottom_sheet_helper_test.dart`. DEVICE-VERIFIED на AVD API 34 (три кнопки).
- **Верх** — проверено в рамках этой задачи: **каждый** `Scaffold` в
  `lib/screens` и `lib/widgets` имеет `appBar:` (проверка: ни один файл с
  `Scaffold(` не остался без `appBar:`). Flutter `AppBar` учитывает
  `padding.top` сам. Кастомных шапок без `AppBar` нет, поэтому верх закрыт
  целиком; `padding.top` / `viewPadding.top` руками не считается нигде — и не
  нужно. `useMaterial3: true`, то есть M3-компоненты применяют insets сами
  (документ Android прямо называет это достаточным).
- **Опт-аут** — не выставлен и выставляться не должен: при targetSdk 36
  `windowOptOutEdgeToEdgeEnforcement` игнорируется (§429).

## Что уже было проверено на устройстве

§448, «Контекст проверки Play»: AVD `LxBox_A15` (API 35, Android 15,
трёхкнопочная навигация), сборка 2.23.2-dev.156 — App Settings до конца списка,
SnackBar, drawer, Servers: контент под панель не уходит, флаги
`LIGHT_STATUS_BARS LIGHT_NAVIGATION_BARS`. То есть **та же рекомендация Play
разбиралась для 2.24.0 и была признана неактуальной по существу**; §516
добавляет к этому машинную причину — почему сканер её выдаёт и почему
`enableEdgeToEdge()` ничего не изменит.

## Версии на момент разбора

| Что | Значение | Откуда |
|---|---|---|
| Flutter | 3.47.1 stable, Dart 3.13.1 | `flutter --version` |
| `targetSdk` | **36** | `flutter.targetSdkVersion` → `FlutterExtension.kt:34` |
| `compileSdk` | 36 | `flutter.compileSdkVersion` → `FlutterExtension.kt:23` |
| `minSdk` | 24 | `build.gradle.kts` (§233) |

Play пишет про SDK 35; у нас 36 — то есть на шаг дальше, и опт-аут уже
недоступен по определению.

## Если рекомендация вернётся

Она вернётся: пока ссылки живут в jar-е эмбеддинга, статический сканер будет их
находить. Убрать её можно только апстримом Flutter (удалением
deprecated-вызовов, а не гейтом). Действий с нашей стороны рекомендация не
требует — но при бампе Flutter стоит перепроверить гейты той же командой:

```sh
javap -p -c io/flutter/plugin/platform/PlatformPlugin.class \
  | grep -E 'SDK_INT|bipush 35|setStatusBarColor|setNavigationBar'
```

Если в новой версии гейт `SDK_INT < 35` исчезнет без замены — вызовы станут
исполняться на Android 15 как no-op, и тогда имеет смысл вернуться к вопросу.

## Визуальная проверка (если владелец захочет подтвердить на API 35)

Эмулятор под задачу не запускался (зарезервирован). Шаги:

1. AVD `LxBox_A15` (API 35), `adb shell cmd overlay enable
   com.android.internal.systemui.navbar.threebutton` — трёхкнопочная навигация
   как худший случай (48dp панель, 80 % альфа).
2. Главный экран: список узлов докручивается над панелью; кнопка Start и
   traffic-bar не под панелью.
3. Servers: список до конца, drag узла у нижнего края.
4. DNS → Add rule: кнопка **Save** целиком над панелью; с открытой клавиатурой
   поднимается без двойного зазора (это исходная жалоба §429).
5. Любой диалог и шторка (Notifications, node warnings, export) — низ контента
   над панелью.
6. Шторка уведомления (§500) — кнопки действий не срезаны.
7. Верх: статус-бар не перекрывает заголовок ни на одном экране; на экране с
   вырезом (`cutout`) заголовок не под вырезом.
8. Повторить с жестовой навигацией (`navbar.gestural`).

## Риск

**Нулевой: изменений в коде нет.** Спека фиксирует разбор. Патч-релиз без
визуальной проверки на API 35 безопасен — дерево не тронуто, а edge-to-edge уже
подтверждён на API 35 в §448 и на API 34 в §429.

## Проверка

- `flutter analyze` — `No issues found!`.
- `flutter test test/contract/bottom_inset_contract_test.dart
  test/contract/bottom_sheet_helper_test.dart` — 2 passed (страж §429 зелёный).
- Изменения: только этот файл и `CHANGELOG.md`.
