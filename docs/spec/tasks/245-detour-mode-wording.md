# §245 — «Add detour»: toggle «Replace existing chain» → два явных режима

> СТАТУС: реализовано (05.07.2026). Только формулировки UI — поведение,
> storage и Debug API НЕ меняются.

## Триггер

Toggle «Replace existing chain» (§073) под «Add detour» был невнятен:
из названия не следовало, что происходит в положении OFF (append —
ноды со своим detour его сохраняют, override получают только «голые»).
Юзеру приходилось угадывать семантику default-состояния.

## Решение (тексты утверждены владельцем)

`SwitchListTile` заменён на `RadioGroup<bool>` с двумя `RadioListTile`
поверх ТОГО ЖЕ поля `entry.replaceDetourChain` (DetourPolicy):

| Режим (title) | `replaceDetourChain` | Subtitle (подписка) |
|---|---|---|
| **Replace all** | `true` | Drop existing detours — every node connects through this outbound |
| **Fill missing** | `false` (default) | Nodes with their own detour keep it; this outbound is set only where none is defined |

Для папки (§239-конвенция `folderMode`) «node/nodes» → «member/members»:
«…every **member** connects…» / «**Members** with their own detour…».

### Было → стало

| Было | Стало |
|---|---|
| SwitchListTile «Replace existing chain», subtitle «Drop the native detour chain, use only this outbound» | Два RadioListTile «Replace all» / «Fill missing» (таблица выше) |
| Subtitle «Add detour» при выбранном outbound: «Replace chain → x» / «Append → x» | «Replace all → x» / «Fill missing → x» (терминология синхронизирована с режимами) |

Не меняется:

- bool `replaceDetourChain` в `DetourPolicy` + JSON-ключ
  `replace_detour_chain` (storage, backup, Debug API `subs.dart`
  сериализатор) — БЕЗ переименования.
- Семантика билдера (`server_list_build.dart`, §073 append/replace +
  §239 FolderDetourPlan: exempt-набор, интра-цепочки).
- Колбэк `onReplaceDetourChainChanged` и persist-обвязка экранов
  (subscription_detail / folder_detail).
- Гейтинг register-тоглов (§096): показываются при Fill missing,
  прячутся при Replace all — как раньше при toggle OFF/ON.
- Subtitle «Append an outbound to the end of the chain» при пустом
  outbound.

## Файлы

- `app/lib/screens/subscription_detail_screen/widgets/subscription_settings_tab.dart`
  — единственный код-файл (таб общий для подписки и папки).

## Docs to update

- `docs/spec/tasks/073-detour-append-vs-replace.md` — update-сноска.
- `docs/spec/tasks/239-folder-detour-symmetry.md` — update-сноска.
- `CHANGELOG.md` — **[deferred: добавить при релизном проходе]**
  (косметика UI, entry под Changed).

## Связанные

§073 (append vs replace — семантика bool), §239 (folder-симметрия,
folderMode-тексты), §096 (register-тоглы), §111 (вырожденное радио без
нативных цепочек — не затронуто, там toggle не показывался).
