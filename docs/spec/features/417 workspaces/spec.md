# §417 — Workspaces: именованные копии состояния

**Статус:** ТЗ (v1)
**Связанные:** §076 (settings ↔ config lifecycle), §113/§414 (dirty-check по
mtime), §027/§129 (кэш тел подписок), §011 (кэш .srs), §189 (native-зеркало
тумблеров), §316 (native `filesDir` из Dart), §286 (probe-lifecycle),
§040/§413 (импорт бэкапа — прецедент перечитывания состояния)

## 1. Проблема

Пользователи просят держать несколько наборов настроек — «дом», «работа»,
«эксперимент» — и переключаться между ними: свои подписки, Направления,
правила, DNS, tun_apps. Сейчас набор один, и «попробовать другую конфигурацию»
означает руками разобрать текущую.

## 2. Что делаем

Workspace — **именованная копия всего состояния приложения**. Не конфиг-файл
(как «профиль» у sing-box-клиентов): конфиг генерируется из состояния, а
workspace — это то, из чего он генерируется.

Модель — слоты сохранения:

- **Сцена** — текущие рабочие пути (те, что и сейчас). Ничего не переезжает.
- **Слот** — папка `workspaces/<имя>/` с копией состояния.
- **`current`** — имя слота, который сейчас на сцене. До первого использования
  фичи — «Default», папки у него ещё нет.
- **Load X** — сохранить сцену в слот `current` → скопировать X на сцену →
  `current = X` → перечитать состояние без перезапуска → пересобрать конфиг →
  поднять VPN, если был поднят. Терять нечего — подтверждений нет.
- **Save as Y** — скопировать сцену в слот Y → `current = Y`. Единственный
  диалог фичи — «Y уже есть, перезаписать?».

Обычного «Save» нет: загрузка сохраняет сама. Активного workspace как
сущности нет: `current` — лишь адрес автосохранения.

### 2.1 Состав слота

Состояние живёт в двух каталогах (§414): Dart-«Documents» =
`app_flutter/`, native `filesDir` = `files/` (= Dart App Support).

| # | Позиция | Где на сцене | Зачем в слоте |
|---|---|---|---|
| 1 | `lxbox_settings.json` | `app_flutter/` ([`settings_storage/io.dart`](../../../../app/lib/services/settings_storage/io.dart)) | всё состояние: подписки, Направления, цепочки, правила, DNS, vars, tun_apps, vpn_mode, аккаунты WARP/MASQUE, native_prefs |
| 2 | `sub_cache/` | `files/` ([`subscription/http_cache.dart`](../../../../app/lib/services/subscription/http_cache.dart)) | тела подписок: узлы не персистятся, `SubscriptionController._rehydrateFromCache` перепарсивает их отсюда при каждом старте — без них подписки после загрузки пустые до первой сети |
| 3 | `rule_sets/` | `app_flutter/` ([`rule_set_downloader.dart`](../../../../app/lib/services/rule_set_downloader.dart)) | скачанные `.srs` + `.meta.json`; конфиг ссылается на них абсолютным путём, ядро само не качает |

**Не в слоте:**

- `singbox_config.json` — после загрузки конфиг пересобирается всегда
  (§2.3), хранить его незачем. Заодно это снимает ловушку native
  `ConfigManager.cachedConfig`: он отдаёт кэш, а не файл, и подменённый на
  диске конфиг ядро бы не увидело; пересборка идёт через `saveConfig` и
  обновляет кэш.
- `cache.db` — bbolt-файл ядра открыт, пока VPN работает; копия под живым
  ядром может быть битой, а битый `cache.db` — это паника на старте, ради
  которой существует сброс §334. Пересоздаётся ядром; теряется только история
  urltest/FakeIP.
- `.bak`, tmp-файлы io-слоя — служебные.
- `support_state.json`, `applog.txt`/`corelog.txt`, crash/oom-репорты,
  тема (SharedPreferences) — свойства устройства, не состояния.
- Native-зеркало тумблеров `boxvpn_boot` (§189) — перезаписывается из
  позиции 1 при перечитывании (`bootstrapAndSyncNativePrefs`).

### 2.2 Хранение

```
app_flutter/
├── lxbox_settings.json              ← сцена (как сейчас)
├── rule_sets/                       ← сцена
├── workspaces.json                  ← справочник (появляется при первом Save as / Load)
└── workspaces/
    ├── Home/
    │   ├── lxbox_settings.json
    │   ├── rule_sets/
    │   └── sub_cache/               ← копия из files/sub_cache/
    └── Work/ …
files/
└── sub_cache/                       ← сцена
```

`workspaces.json`:

```jsonc
{
  "version": 1,
  "current": "Home",                          // имя слота на сцене
  "slots": [ { "name": "Home", "saved_at": "ISO-8601" }, … ],
  "pending": null                              // журнал §2.4
}
```

Нет `workspaces.json` = фичей не пользовались: `current` = «Default», слотов
нет. Ни одного нового шага на старте приложения для таких пользователей.

Имя слота = имя папки. Санитизация: обрезать пробелы, запретить пустое,
`/`, `\`, `..`, ведущую точку, длина ≤ 64. Сравнение имён —
регистрозависимое, как файловая система устройства (ext4).

### 2.3 Загрузка — шаги

Всё выполняется из `HomeScreen` (попап живёт в его AppBar), контроллеры —
его поля.

1. `ProbeLifecycle.I.haltAll()` — пробы держат `cache.db` (§286, #1406).
2. `wasUp = _controller.state.tunnelUp`; если поднят —
   `await _controller.stop()` (блокирующий `stopVPN()` до `Stopped`, §387).
3. `await SettingsStorage.flushToDisk()` — сцена на диске актуальна.
4. Журнал: `pending = {op: "load", target: X}` → записать `workspaces.json`.
5. **Save current**: копия позиций 1–3 в `workspaces/<current>/` (§2.5).
6. **Load X**: копия позиций 1–3 из `workspaces/<X>/` на сцену (§2.5).
7. `current = X`, `pending = null` → записать `workspaces.json`.
8. `File(lxbox_settings.json).setLastModified(now)` — настройки заведомо
   новее `singbox_config.json` → bootstrap-проверка §076 честно скажет
   «грязно» (после §414 она работает).
9. **Перечитать** (§2.6).
10. Новый `HomeScreen` в `_initSubsAndAutoUpdate` видит `configDirty` →
    `_rebuildAndClearDirty(silent: true)` — та же воронка, что у холодного
    старта: `generateConfig` + `saveParsedConfig` (native `saveConfig` →
    `cachedConfig` обновлён).
11. Если `wasUp` — `_controller.start()` после bootstrap'а.

Save as = шаги 3 → копия сцены в `workspaces/<Y>/` → `current = Y`. VPN не
трогается, перечитывать нечего.

### 2.4 Журнал и идемпотентность

Копирование трёх позиций не атомарно как целое. Если процесс убит между
шагами 4 и 7, сцена — смесь `current` и X. Лечение: копирование
идемпотентно, поэтому при старте (в `main()`, до
`bootstrapAndSyncNativePrefs`) `WorkspaceStore.recover()` читает
`pending` и **повторяет шаги 5–7 целиком**. Слот `current` при повторе
может получить уже частично перезаписанную сцену — это допустимо: сцена
на момент убийства и есть последнее известное состояние `current`, а
`pending.target` был выбран пользователем.

Позиция 1 копируется через tmp + `rename` (образец —
`settings_storage/io.dart:_atomicSave`), чтобы на сцене никогда не лежал
полуфайл. Папки (2, 3): удалить целевую, скопировать заново — в слоте
может быть меньше файлов, чем на сцене.

Только для пользователей со справочником; без `workspaces.json` `recover()`
— один `exists()`.

### 2.5 Копирование позиций

`WorkspaceStore` — единственное место, где перечислен состав слота
(`kSlotEntries`). Источники путей: Documents —
`getApplicationDocumentsDirectory()`; `files/` —
`BoxVpnClient.getFilesDir()` (§316) с fallback на
`getApplicationSupportDirectory()` (тот же каталог на Android; fallback
нужен тестам). Копия рекурсивная, побайтовая; символических ссылок в этих
каталогах нет.

### 2.6 Перечитывание без перезапуска

Перезапуск процесса не нужен: всё живое состояние либо принадлежит
`HomeScreen`, либо умирает со стопом VPN, либо не зависит от workspace.

| Что | Как перечитать | Где живёт |
|---|---|---|
| `SettingsStorage._cache` | `SettingsStorage.clearCache()` (после `flushToDisk`) | [`settings_storage.dart`](../../../../app/lib/services/settings_storage.dart) |
| native-зеркало тумблеров | `SettingsStorage.bootstrapAndSyncNativePrefs()` | `main.dart` |
| язык | `LocaleController.I.reloadFromStorage()` | `main.dart` (импорт бэкапа зовёт то же) |
| миграции Направлений/цепочек | `migrateDirectionsIfNeeded` (+`TemplateLoader.load()`), `migrateChainOrderIfNeeded` — идемпотентны, импорт бэкапа гоняет их так же | `main.dart:98-110` |
| события автоматизации | `AutomationEventEmitter.I.reload()` | `main.dart` |
| контроллеры: подписки (+ rehydrate из `sub_cache`), home, автообновление, рулсеты, Debug-сервер (порт/токен слота), `DebugRegistry`, `ActiveTimeTracker` | **пересоздать `HomeScreen`**: все они создаются в `initState` и убиваются в `dispose` ([`home_screen.dart:164-256, 467-496`](../../../../app/lib/screens/home_screen.dart)) | `main.dart:297` `home: const HomeScreen()` |

Механизм пересоздания: `WorkspaceController.I` (`ChangeNotifier`, счётчик
`generation`) добавляется в `Listenable.merge` у `LxBoxApp` (`main.dart:258`),
`home: HomeScreen(key: ValueKey(WorkspaceController.I.generation))`. Инкремент
→ старый `HomeScreen` dispose, новый — полный `initState` = обычный старт.
Флаг `pendingAutoConnect` на контроллере — in-memory, одноразовый, читается
новым `HomeScreen` после bootstrap'а.

Не зависит от workspace и не перечитывается: `VersionInfo`, `UpdateChecker`,
`CrashBannerState`, `SupportState`, `HapticService`, `DonateMethods`,
`ThemeNotifier`, `WifiHistoryListener` (пишет в актуальный файл),
`ClashLogPump` (attach идемпотентен), `RuleSetDownloader._cacheDir` (путь
сцены не меняется).

### 2.7 UI

Главный экран, AppBar: справа от «L×Box» — кнопка с именем `current`
(`▾`). Тап — попап в стиле приложения с двумя разделами:

```
┌─ L×Box   [ Home ▾ ]────────────────────┐
│                                        │
│   ┌──────────────────────────────┐     │
│   │ LOAD                         │     │
│   │  ● Home            2 Sep     │     │
│   │    Work            28 Aug    │     │
│   │    Lab             15 Aug    │     │
│   ├──────────────────────────────┤     │
│   │ SAVE                         │     │
│   │  ＋ Save as…                 │     │
│   ├──────────────────────────────┤     │
│   │  Manage workspaces…          │     │
│   └──────────────────────────────┘     │
```

- Раздел LOAD: слоты по имени, `current` отмечен, у каждого дата
  `saved_at`. Тап по `current` — закрыть попап (no-op). Тап по другому —
  §2.3 с прогресс-индикатором на время стопа/копии/пересборки.
- «Save as…» — диалог с именем (предзаполнено `current`, если у него уже
  есть папка — пусто). Существующее имя → «Overwrite “Y”?».
- «Manage workspaces…» — экран-список по образцу
  [`dns_settings_screen.dart`](../../../../app/lib/screens/dns_settings_screen.dart):
  переименовать (папка + `current`, если это он), удалить (не `current`;
  подтверждение).
- Пока справочника нет: в кнопке «Default», в LOAD — один элемент
  «Default» (отмечен), Save as создаёт справочник.
- Строки — natural keys в `app/assets/l10n/ru/ui.json` (§285):
  «Workspaces», «Load», «Save as…», «Manage workspaces…», «Overwrite “%s”?»,
  «Loading workspace…», «Workspace name», «Rename», «Delete», «Default».

### 2.8 Что происходит с VPN

Загрузка при поднятом VPN = стоп → загрузка → пересборка → старт: разрыв
соединений на время операции (секунды). Это ожидаемо: сменился весь мир,
хот-своп невозможен по построению (`cache.db`, inbounds, tun_apps).
Пользователь остаётся в приложении.

## 3. Не делаем в v1

- Переключение из Intent API (§047) / MacroDroid — нужен путь без UI и
  фоновый перезапуск; отдельная спека.
- Импорт бэкапа сразу в слот; экспорт слота — через штатный бэкап после
  загрузки.
- Общие подписки между слотами (overlay/diff-модель) — отвергнуто: второй
  движок слияния.
- Имя workspace в нотификации.
- `cache.db` в слоте.

## 4. Реализация

| # | Коммит | Файлы |
|---|---|---|
| 1 | `WorkspaceStore`: справочник, `kSlotEntries`, `saveTo(name)`, `loadFrom(name)` (5–7 из §2.3), `recover()`, санитизация; тесты на path_provider-моке + `BoxVpnClient.forTest` (`getFilesDir` → temp) | `services/workspaces/workspace_store.dart`, `test/services/workspace_store_test.dart`, `main.dart` (`recover()` перед `bootstrapAndSyncNativePrefs`) |
| 2 | `WorkspaceController` + пересоздание `HomeScreen`; `reloadStateFromDisk()` (таблица §2.6); `pendingAutoConnect` в `_initSubsAndAutoUpdate` | `services/workspaces/workspace_controller.dart`, `main.dart`, `home_screen.dart` |
| 3 | Попап в AppBar + Save as + экран Manage; l10n | `screens/home/widgets/workspace_menu.dart`, `screens/workspaces_screen.dart`, `assets/l10n/ru/ui.json` |
| 4 | Доки: STORAGE.md (дерево + таблица с пометкой «в слоте / устройство»), USER_GUIDE, CHANGELOG | docs |

## 5. Критерии приёмки

- Без справочника: старт приложения не пишет на диск ничего нового.
- Save as → Load другого → Load обратно: подписки с узлами (оффлайн!),
  Направления, правила, DNS, tun_apps, vpn_mode, язык, Debug-порт/токен —
  идентичны исходным; native-тумблеры (`boxvpn_boot`) совпадают с файлом.
- Load при поднятом VPN: туннель опускается, конфиг пересобран
  (`singbox_config.json` mtime новее загрузки, состав outbounds — из слота),
  туннель поднят без действий пользователя.
- Убийство процесса между шагами 5–7 (device-тест: `am kill` по
  таймингу или инжект в тесте) → следующий старт доводит загрузку, сцена =
  слот X целиком.
- Load `current` — no-op; удалить `current` нельзя; имя с `/` отклоняется.
- `flutter analyze`, `flutter test`, четыре l10n-чекера `--strict`.

## Docs to update

- `docs/STORAGE.md` — «Disk layout»: `workspaces.json`, `workspaces/`,
  пометка у каждой позиции: в слоте / устройство.
- `docs/USER_GUIDE.md` + `.ru.md` — раздел Workspaces.
- `CHANGELOG.md` — Unreleased/Added.
- `docs/ARCHITECTURE.md` — Feature Specs: строка 417; «The user state» —
  `workspaces/`.
