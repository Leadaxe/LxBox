# §278 — осиротевший экран папки: авто-закрытие вместо немых orphan-гейтов

| Поле | Значение |
|---|---|
| Статус | РЕЛИЗ v2.15.10 (2026-07-17) |
| Связанные спеки | §277 (породивший свип; критерии «немой гейт»), §238 (Debug API /folders CRUD), §234 (папки), §221 (backup/restore) |
| Ядро | не затронуто |

## Проблема

Свип §277 нашёл в `folder_detail_screen.dart` семейство orphan-гейтов
`if (_index < 0) return;` (reorder ~984, Switch члена ~1046, onTap члена
~1058, `_addFromClipboard` ~604, `_addFromFiles` ~629, и ещё ~10 call-sites),
где `_index = widget.controller.entries.indexOf(widget.entry)` — по identity
(`SubscriptionEntry` не переопределяет `==`). Два ревью-агента разошлись в
оценке достижимости; разбор кода в этой таске дал точный ответ.

**Достижимо. Два пути осиротения при открытом экране:**

1. **Debug API §238**: `DELETE /folders/{id}` → `_deleteFolder`
   (`services/debug/handlers/folders.dart:171`) работает с живым контроллером
   (`ctx.requireSub()`) → `deleteFolderAt` → `_entries.removeAt` — entry-объект
   исчезает из списка, пока экран держит на него ссылку.
2. **Restore из backup (теоретический)**: `restore_backup.dart:87` зовёт
   `subController.init()`, который пересоздаёт ВСЕ entry-объекты
   (`subscription_controller.dart:120`) — открытый экран сирота, даже если
   «та же» папка есть в restored-данных. Практически недостижим при открытой
   папке: restore-кнопка живёт в empty-state списка главного экрана
   (`home_screen.dart:611`). ⚠ Debug API `POST /backup/import` init() НЕ
   зовёт — пишет только storage (`handlers/backup.dart`), in-memory entries
   не трогает (§076 restart-reconciled) — этот путь экран НЕ осиротит
   (уточнение адверсарного ревью; первая редакция спеки утверждала обратное).

3. **Debug API `DELETE /subs/{id}` с id ПАПКИ** (нашло адверсарное ревью):
   папка — entry общего списка `/subs`, а `subs._delete`
   (`handlers/subs.dart:185-201`) не гейтит по типу (в отличие от `_refresh`)
   → `removeAt` → то же осиротение. Слушатель покрывает и этот путь
   (`removeAt` нотифицирует). Type-guard в `subs._delete` — не добавлен
   осознанно: удаление папки через generic /subs легитимно (meta папок и так
   правится через `PATCH /subs/{id}` по докам `folders.dart`).

**Недостижимо** (identity переживает): rename/refresh (`_replaceList` мутирует
entry на месте), удаление ДРУГОЙ папки (`removeAt` сдвигает индексы, не рвёт
identity), ungroup/move-server (вставка новых entries).

Последствие осиротения до фикса: экран продолжал выглядеть полностью рабочим
(даже не перерисовывался: `AnimatedBuilder` в build слушает `widget.entry`, а
`deleteFolderAt`/`init()` нотифицируют КОНТРОЛЛЕР), но каждое действие — тоггл
члена, tap, reorder, add, rename, sort — молча умирало в orphan-гейте. Тот же
анти-паттерн «немой гейт», что в §277, только гейт размазан по ~15 обработчикам.

Единственное место с честной обработкой — `_delete` (строки ~580-584): при
`idx < 0` закрывает экран.

## Решение

### 1. Обобщить паттерн `_delete`: слушатель контроллера + авто-pop

Точечные фиксы каждого из ~15 гейтов (снекбар в каждом) оставили бы юзера на
мёртвом экране. Вместо этого — один структурный механизм:

- `initState`: `widget.controller.addListener(_onEntriesChanged)`
  (симметрично `removeListener` в `dispose`);
- `_onEntriesChanged`: если `_index < 0` и ещё не уходим (`_leaving`) —
  pop после кадра (`addPostFrameCallback`: notify может прийти во время
  build). Роут может быть не верхним (открыт диалог/шит/пикер) —
  `route.isCurrent ? Navigator.pop : Navigator.removeRoute(route)`, чтобы
  не снять чужой верхний роут;
- `_delete` ставит `_leaving = true` перед `deleteFolderAt` — свой
  явный pop, слушатель не дублирует (двойной pop снял бы экран ниже).
  Защёлка НЕ one-way: `deleteFolderAt` может упасть ПОСЛЕ `removeAt`, на
  `_persist()` (FileSystemException; `subscription_controller.dart:943→953`)
  — notify и явный pop не случатся, а застрявший `_leaving` навсегда глушил
  бы авто-pop (§277-зомби; находка адверсарного ревью). Поэтому catch:
  сброс защёлки + прямой `_onEntriesChanged()` (упавший вызов сам не
  нотифицировал) + rethrow;
- после `addPostFrameCallback` — `ensureVisualUpdate()`: пост-кадровый
  колбэк сам кадр не планирует; без этого pop зависел бы от того, что кадр
  запросят другие слушатели контроллера (home/subs-экраны — сегодня
  запрашивают, но это скрытая зависимость);
- pop тихий — консистентно с существующей orphan-веткой `_delete`; сценарий
  power-user'овский (Debug API/restore), а формулировка «Folder was removed»
  была бы ложью для restore-пути (папка существует, но новым объектом).

Гейты `if (_index < 0) return` ОСТАЮТСЯ как защита окна в один кадр между
внешней мутацией и pop'ом (тап может успеть) — теперь это честная
мёртвая-защита при живом экране, а не UX-механизм.

### 2. app_picker: «Export to clipboard» глотался гейтом при загрузке

`app_picker_screen.dart`: пункт меню enabled во время `_loading`, но
`onSelected`-гейт `if (_loading && v != 'system') return;` молча глотал выбор
— рассинхрон того же семейства (соседние пункты честно `enabled: !_loading`).
Экспорт зависит только от `_selected`, который инициализируется синхронно из
`widget.selected` в `initState` — список приложений ему не нужен. Фикс =
поведение под видимое состояние: `export` исключён из гейта (как `system`),
а не задизейблен.

## Верификация

- Достижимость путей осиротения доказана чтением кода (см. «Проблема» —
  конкретные строки), device-пробник не потребовался.
- Адверсарное multi-agent ревью (4 линзы: navigator / lifecycle /
  reachability / app-picker; каждая с задачей опровергнуть; SDK-семантика
  Navigator/routes сверялась с исходниками Flutter 3.41.6). Итог: не
  опровергнуто. Ревью дало три правки до коммита: (1) сброс `_leaving` в
  catch `_delete` (иначе throw на `_persist` после `removeAt` = вечный
  зомби), (2) `ensureVisualUpdate` после `addPostFrameCallback`,
  (3) mounted-гарды в `_editMember`/`_moveMember`/`_deleteMember`/
  `_editThresholds` — тап из шита, пережившего removeRoute экрана, ронял бы
  геттер `context` (шум в crash-reporter). Плюс две фактические правки спеки
  (backup/import не осиротит; третий путь `DELETE /subs/{id}`).
- Проверены и НЕ подтвердились: двойной pop (защёлка + `isActive`-гейт
  закрывают все интерливинги, включая ответ на диалог до post-frame);
  notify между initState и первым build (нет event-loop turn);
  `ModalRoute.of` в post-frame после finalizeTree (mounted-гард надёжен).
- Известный резидуал (принят): внешний DELETE, у которого `_persist` бросил
  FileSystemException — entry снят без notify, экран-зомби до ЛЮБОГО
  следующего notify контроллера (самолечится ре-чеком слушателя); требует
  IO-сбоя storage, не хуже поведения до фикса. Заброшенный шит поверх
  «не того» экрана после removeRoute — закрывается юзером вручную,
  действия в нём — тихий no-op через mounted-гарды.
- `flutter analyze` (весь проект) — 0 issues, `flutter test` — полный сьют
  зелёный (см. коммит).

Widget-тест: у экрана нет pump-харнесса (как у §277); слушатель+pop —
навигационный side-effect, unit-тестируется только контроллерная часть,
которая не менялась.

## Docs to update

- `CHANGELOG.md` → `[Unreleased]` / Fixed — в этом же коммите.
- Debug API reference — без изменений (семантика endpoints не менялась).

## Вне скоупа

- `NodeSettingsScreen`, открытый ПОВЕРХ осиротевшей папки (наш роут снимается
  под ним через `removeRoute`; его собственные записи упираются в его гейты) —
  отдельная редкая матрёшка, ловится теми же путями Debug API.
- Снекбар-уведомление при авто-pop — осознанно нет (см. «Решение»).
- `persistSources` осиротевшего entry (Sources-вкладка §237 пишет через
  контроллер по объекту) — с авто-pop'ом окно схлопывается до кадра.
