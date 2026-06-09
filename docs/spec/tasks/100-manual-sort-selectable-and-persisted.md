# 100 — Manual-сортировка: выбираемая из меню + персист порядка

| Поле | Значение |
|------|----------|
| Тип | UX + персистентность (расширение §070/§071) |
| Триггер | Юзер: «разблокируй ручную сортировку из списка сортировки чтобы её можно было выбрать — для тупых появятся поля перетаскивания; и сохраняй порядок ручной сортировки» |

## Было

- `NodeSortMode.manual` («Custom») **не входил в cycle** (`next`) и **не было
  UI-выбора** — manual входился ТОЛЬКО через drag (`commitManualReorder`).
  Меню сортировки (`showSortOptionsMenu`) содержало лишь pin/re-sort чекбоксы,
  без выбора режима (режим менялся tap'ом по кнопке = cycle).
- `manualOrder` — **per-session** (в памяти), терялся при рестарте; cycle из
  manual→default его **сбрасывал**.

## Стало

1. **Выбор режима в меню** (`home_menus.dart`): добавлен ряд `ChoiceChip`'ов по
   всем `NodeSortMode.values` (Default / Ping / A–Z / **Custom**) — tap →
   `controller.setSortMode(m)`. Выбор `Custom` = manual → видимые grab-strip'ы
   (§098) «поля перетаскивания».
2. **`HomeController.setSortMode(mode)`** (новый) — прямой выбор режима +
   персист. `cycleSortMode` больше **не сбрасывает** `manualOrder` (порядок
   сохраняется, повторный выбор Custom его восстанавливает). `commitManualReorder`
   — персист после drag.
3. **Персист** (`SettingsStorage.getNodeSort`/`setNodeSort`): `node_sort_mode`
   (имя enum) + `node_manual_order` (List<String>) в `lxbox_settings.json`.
   `HomeController._persistSort()` пишет после любой смены сортировки.
4. **Restore** (`_loadSavedConfig`): на старте читает сохранённые mode+order →
   `copyWith(sortMode, manualOrder)`. Stale-теги безопасны — `HomeState`
   фильтрует `manualOrder` к present-нодам + новые в конец (§071, не менял).

## Файлы

| Файл | Что |
|------|-----|
| `services/settings_storage.dart` | +`getNodeSort`/`setNodeSort` (через `_load`/`_save`) |
| `controllers/home_controller.dart` | +`setSortMode`, +`_persistSort`; `cycleSortMode` без clear; `commitManualReorder` персист |
| `controllers/home_controller/config_io.dart` | `_loadSavedConfig` restore mode+order |
| `screens/home/home_menus.dart` | mode-ChoiceChips в sort-меню (+import home_state) |

## Заметки

- Отменяет §071-«exit из manual сбрасывает manualOrder» — теперь порядок sticky
  (юзер явно просил персист).
- Персистится и сам `sortMode` (не только manual) — последний режим
  восстанавливается на старте. Pin/re-sort остаются per-session (не просили).

## Статус — DONE ✅ (analyze + 843 теста; device-verify на юзере)
