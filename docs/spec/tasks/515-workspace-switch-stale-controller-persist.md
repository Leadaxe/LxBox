# §515 — Workspaces: контроллер прежнего слота затирает подписки нового

| | |
|---|---|
| **Статус** | **Released в v2.25.2** (24.09.2026). Готово: барьер поколения в `SubscriptionController._persist`, настоящий `dispose()`, `AutoUpdater.halt()` на пути переключения, 7 регресс-тестов |
| **Дата** | 2026-09-24 |
| **Источник** | 4PDA, два репорта с видео (HDevil, воспроизвёл дважды): после переключения пространства вкладка «Серверы» во **всех** пространствах показывает одну и ту же подписку — последнюю обновлённую. Потеря закрепляется на диске и переживает перезапуск |
| **Связанные** | [§417 Workspaces](../../project_workspaces_architecture.md) — слот = копии файлов; §447 (явный `configDirty` при загрузке слота); §331 (`keepDirtyFlag` в фетч-пути); §027 / §291 (триггеры `AutoUpdater`); §286 (пробы держат `cache.db`); §101 (регидрация из HTTP-кэша) |

## Проблема

Два пространства (wifi, cell), в каждом своя подписка. После переключения
подписки одного пространства оказываются в обоих, данные второго потеряны —
не только в UI, а в папке слота на диске.

User-impact P0: молчаливая потеря пользовательских данных. Фикс закрывает
причину, но **уже перезаписанные папки слотов не восстанавливает** — только из
бэкапа пространства.

## Диагностика

Корень — три факта вместе, ни один сам по себе не дефект.

1. **`_persist()` пишет весь набор без привязки к слоту.**
   `subscription_controller.dart` → `SettingsStorage.saveServerLists` →
   `sources_rules.dart` `_saveServerLists` → `_spliceSourceKind` с
   `isOurs: (r) => !_isChainRecord(r)`: **все** не-цепочки в
   `lxbox_settings.json` заменяются составом вызывающего контроллера. Ни
   `_persist`, ни `saveServerLists` не знают ни имени слота, ни поколения.

2. **Контроллер прежнего слота живёт дальше.** `SubscriptionController` не имел
   `dispose()` вообще: вызов в `home_screen.dart` попадал в
   `ChangeNotifier.dispose()` — снимает слушателей, но не отменяет летящих
   `await` и не оставляет флага, который `_persist` мог бы проверить.
   Пересоздание — только ключом виджета (`main.dart`,
   `ValueKey(WorkspaceController.I.generation)`): новый `HomeScreen` гарантирован,
   асинхронные хвосты старого — нет.

3. **Апдейтер переживает переключение.** `_stopForWorkspaceSwitch` гасил только
   пробы (`ProbeLifecycle.haltAll`) и туннель. `AutoUpdater.dispose()` снимал
   только таймеры; уже запущенный `maybeUpdateAll` продолжался, а между
   подписками у него `perSubscriptionDelay` 10 с ± 2 с — окно в десятки секунд
   на каждую подписку. `dispose()` апдейтера к тому же зовётся в `dispose()`
   экрана, то есть **после** копирования файлов.

Сценарий по коду: идёт авто-обновление (⟳ / `periodic` / `resumed` /
`vpnStopped`) → пользователь грузит другой слот → `WorkspaceStore._performLoad`
копирует сцену в папку прежнего слота, затем папку целевого — на сцену → новый
контроллер читает целевой слот, **UI верен** → отвечает HTTP старого фетча (или
истекает пауза и апдейтер берёт следующую подписку) → `_persist()` пишет состав
ПРЕЖНЕГО слота в сцену, которая теперь принадлежит целевому → ближайший
`load`/`saveAs` копирует испорченную сцену в папку слота и закрепляет подмену.
Дальнейшие переключения тиражируют одну подписку во все слоты.

Окно **не ограничено фетчем**: любая мутация старого контроллера (`toggleAt`,
`moveEntry`, `renameAt`, `applyEntryOrder`, `disableNodeByCoreTag`,
`syncDetour*`) кончается `_persist()` и даёт то же. Пишут и оба фейл-пути
`_fetchEntryByRef` (пометка попытки `inProgress`, «0 нод»), так что даже
**провалившийся** фетч затирал слот.

Ложный след из исходной гипотезы: debounce-таймера на этом пути нет (`_persist`
пишет сразу, `flush: false` у `LazyPersistMixin` здесь не участвует), и
WorkManager'а в проекте нет — background-fetch выгруженного app вне скопа §027.
Виноват in-process апдейтер.

## Решение

Барьер на уровне контроллера, а не в хранилище.

### 1. Поколение и идентичность — `app/lib/controllers/subscription_controller.dart`

- `_bornGeneration = WorkspaceController.I.generation` — поле, инициализируется
  при конструировании.
- `_disposed` + override `dispose()`, который его ставит.
- `bool get stale => _disposed || WorkspaceController.I.generation != _bornGeneration`.
- `_persist()` **первой строкой** сверяет `stale`: не пишет, логирует
  `AppLog.warning('workspaces: persist skipped — controller from generation N,
  current M')`, возвращается. `configDirty` тоже не поднимает — флаг глобальный,
  иначе чужой хвост заставил бы новый слот пересобирать конфиг.
- Ранние выходы после `await` в асинхронных проходах: в `_fetchEntryByRef` сразу
  после `parseFromSource` (иначе результат старого слота уехал бы в лог как
  «обновлено»), в `_rehydrateFromCache` после `HttpCache.loadBody` (`return`
  безопасен — `finally` по-прежнему закрывает `_rehydrated`).
- override `notifyListeners()`: при `_disposed` — no-op. У контроллера 58 точек
  `_persist` + `notifyListeners`; барьер отменяет запись, но
  `ChangeNotifier.notifyListeners` на том же пути роняет debug-сборку assert'ом
  «used after being disposed». Слушателей после `dispose()` нет по построению.

Один барьер в одной точке закрывает фетч, `toggleAt`, регидрацию и любую
будущую мутацию.

### 2. `AutoUpdater.halt()` — `app/lib/services/subscription/auto_updater.dart`

- `_halted` + `halt()`: снимает таймеры (как `dispose`, который теперь тоже
  ставит флаг) и выставляет отмену.
- `maybeUpdateAll` проверяет `_halted` на входе (закрывает `unawaited`-триггеры
  `resumed` / `vpnStopped`, летящие в то же окно) и перед каждой подпиской
  внутри прохода — с `return`, так что реакция (пересборка/reload) при отмене
  не применяется.
- Пауза между подписками — `_sleepInterruptibly`: нарезка по 250 мс вместо
  одного `Future.delayed(10 с)`. Суммарная задержка для провайдера та же,
  реакция на отмену — четверть секунды вместо десяти.
- `halt()` **не** ждёт `_running == false`: летящий HTTP может висеть до
  таймаута, а переключение слота ждать его не должно. Этот случай закрыт
  барьером поколения.

### 3. `_stopForWorkspaceSwitch` — `app/lib/screens/home_screen.dart`

Первой строкой `_autoUpdater.halt()`, до `ProbeLifecycle.I.haltAll()`.
Штатное окно сводится к нулю ещё до копирования файлов.

### Чего намеренно НЕ сделали

- **Барьер в `saveServerLists` / `sources_rules.dart`** — под него попали бы
  легитимные писатели, не принадлежащие `HomeScreen`: импорт бэкапа
  (`lx_backup_import.dart`), `backup_service.dart`, Debug API, шаги
  `WorkspaceController._reloadStateFromDisk`. Их записи терялись бы молча.
- **Миграция формы хранения** — `kSlotEntries`, `workspaces.json` и форма
  `lxbox_settings.json` не менялись. Миграции слота нет, риска миграции нет.

### Прочие контроллеры, живущие через переключение (проверено)

Полный обход писателей `lxbox_settings.json` (`grep saveServerLists`,
`SettingsStorage.save*` / `set*` по `lib/controllers`, `lib/services/warp`):

| Кандидат | Вывод |
|---|---|
| `RuleSetAutoUpdater` (§366) | `lxbox_settings.json` не пишет — только `getCustomRules()` читает. Свои файлы rule-set'ов от слота не зависят |
| `HomeController` | единственная запись из асинхронного пути — `_persistSort` → `setNodeSort` (скалярная переменная, не набор источников). Полного overwrite нет |
| Папки §234-239 | живут записями `sources[]` того же `SubscriptionController` — закрыты тем же барьером |
| Страховка 478 (`disableNodeByCoreTag`) | идёт через `_persist` того же контроллера — закрыта барьером |
| WARP (`warp_endpoint_picker`, `scan/*`) | записей в `lxbox_settings.json` нет |
| `_healDetourDirectionRefs` (`settings_storage/directions.dart`) | `_saveServerLists(flush: false)` — синхронная часть `updateDirection`/`deleteDirection` от UI, не асинхронный хвост, переживающий переключение |

Отдельных фиксов не потребовалось.

## Риски и edge cases

- **Слишком широкий барьер.** Барьер стоит на уровне контроллера и срабатывает
  только при смене `generation` или после `dispose()`. Контрольный тест
  «контроллер ТЕКУЩЕГО поколения пишет как обычно» держит этот инвариант.
- **`halt()` без последующего `start()`.** Экземпляр апдейтера умирает вместе с
  `HomeScreen`; новый экран создаёт свой и зовёт `start()` в
  `_initSubsAndAutoUpdate`. Реанимация halted-экземпляра не нужна и намеренно
  не предусмотрена.
- **Потерянные обновления.** Фетч, начатый до переключения, теперь
  отбрасывается целиком (включая `lastUpdateAttempt`). Штатный путь: новый
  контроллер целевого слота обновит свои подписки сам по своим триггерам.
- **Уже пострадавшие пользователи.** Папки слотов перезаписаны; фикс их не
  восстановит. Восстановление — только из бэкапа пространства.

## Верификация

`app/test/services/workspace_stale_controller_persist_test.dart` — 7 кейсов,
без эмулятора и без `pumpAndSettle` (виджетов нет, только контроллеры и
реальное файловое хранилище на двух временных корнях). Проверено, что
**6 из 7 красные** на дереве без барьера (`stale => false`, `halt` без флага),
седьмой — контрольный:

- РЕГРЕСС (а): отложенный фетч старого контроллера не трогает новый слот;
- РЕГРЕСС (а-фейл): путь «0 нод» старого контроллера тоже не пишет;
- РЕГРЕСС (б): `toggleAt` старого контроллера — no-op на диске;
- РЕГРЕСС (б-dispose): disposed-контроллер не пишет и в своём поколении;
- контроль: контроллер текущего поколения пишет как обычно;
- РЕГРЕСС (в): `AutoUpdater.halt()` прерывает идущий проход между подписками;
- после `halt` новые проходы не стартуют (`resumed`, `manual force`).

Прогоны: `test/services/workspace_*` 36/36, `test/subscription/` 309/309,
`test/contract/startup_order_contract_test.dart` + `workspace_config_dirty_test`
4/4, стражи `storage_migration/golden_config_test` +
`parser/before_480_identity_snapshot_test` 16/16. `flutter analyze` по проекту
чистый. Четыре `tool/l10n/*_check.dart --strict` — 0 findings (видимых строк не
добавлено, l10n не затронут).

## Нерешённое / follow-up

- **Симметричный барьер на уровне хранилища** (`WorkspaceController.slotEpoch`,
  `saveServerLists` принимает ожидаемый epoch) — предложение разведки, п. 2.
  Переносится на всех писателей `lxbox_settings.json`, а не только на подписки,
  но требует протащить epoch через импорт бэкапа и Debug API. Не в этой задаче.
- **Вопрос автору репорта** (подтвердить, что видео показывает именно этот
  путь): шло ли обновление подписок в момент переключения; в экспорте лога
  `Fetching subscription` ПЕРЕД `workspaces: loaded`, а `Fetched N nodes` —
  ПОСЛЕ. Логи безопасны — URL маскируется до хоста (`maskSubscriptionUrl`).
- **Восстановление данных пострадавших** — вне скопа фикса, только из бэкапов.
