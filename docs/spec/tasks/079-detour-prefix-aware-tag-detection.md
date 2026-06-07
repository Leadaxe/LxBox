# 079 — Detour exclusion: prefix-aware tag detection

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата | 2026-06-08 |
| Тип | fix (behaviour bug) |
| Зависимости | §048 (home node filters, detour show/hide toggle), §073 (`server_list_build._withPrefix`), §077 (same prefix-form bug class). |
| Связанные | `home_screen.dart::_computeDisplayList` / `_buildNodeList`, `node_filter_screen.dart::_load`, `services/builder/server_list_build.dart::_withPrefix`. |

## Триггер

Тот же класс багов что §077: два UI-фильтра используют
`tag.startsWith(kDetourTagPrefix)` (`'⚙ '`) для детекции detour-серверов в
**display-form** тэгах. Tag-prefixed подписки (`tagPrefix='🇷🇺 RU'`)
приводят к display-тэгу вида `'🇷🇺 RU ⚙ NodeName'` — `startsWith('⚙ ')`
возвращает false → detour-сервера **протекают** в основной пул нод.

## Воспроизведение

1. Подписка с `tagPrefix='🇷🇺 RU'`, в её raw-config есть ноды с цепочкой
   `detour:` → в финальном sing-box config'е появляются outbounds с
   tag'ами вида:
   - main node: `'🇷🇺 RU NodeA'`
   - detour server: `'🇷🇺 RU ⚙ HopB'`
2. **Home, detour toggle OFF** (`_showDetourNodes=false`): ожидание —
   `'🇷🇺 RU ⚙ HopB'` скрыт из listа.
   Факт: показывается как обычная нода.
3. **NodeFilterScreen** (per-node include/exclude чекбоксы для
   `✨auto`): ожидание — detour-сервера не в списке (их нельзя
   выбирать как endpoint для auto). Факт: они отображаются и пользователь
   может их включить/выключить (ломая семантику auto-pool).

При `tagPrefix == ''` баг невидим (display-form == bare-form: `'⚙ HopB'`
→ `startsWith('⚙ ')` true).

## Root cause

`server_list_build.dart::_withPrefix` формирует финальный display-тэг как
`'$tagPrefix $base'`:

```dart
String _withPrefix(String base) =>
    tagPrefix.isEmpty ? base : '$tagPrefix $base';
```

`base` для detour-сервера = `'⚙ NodeName'` (префикс ставится парсером
или ручным toggle'ом в `node_settings_screen`). При `tagPrefix='🇷🇺 RU'`
финальный display-тэг → `'🇷🇺 RU ⚙ NodeName'`.

Три call-site'а строят пул нод по display-form тэгам и используют
**bare** `startsWith` проверку:

| Файл:line | Контекст |
|-----------|----------|
| `home_screen.dart:618` | `_computeDisplayList` — внешний пересчёт display-orderа для ping button onTap. |
| `home_screen.dart:2227` | `_buildNodeList` — main render path списка нод. |
| `node_filter_screen.dart:60` | `_load` — per-node include picker для `✨auto`. Source: `result.nodes` от `_parseNodesFromConfig(state.configRaw)` (тоже prefixed-form). |

Все три падают одинаково.

## Фикс

Pure helper `isDetourDisplayTag` в `app/lib/config/consts.dart` (рядом с
самой константой `kDetourTagPrefix`):

```dart
/// True если display-form `tag` принадлежит detour-серверу
/// (промежуточный hop, не endpoint).
///
/// Detector обрабатывает **обе** формы prefix'а от
/// `server_list_build._withPrefix`:
///   - `tagPrefix==''` → bare-form: `'⚙ NodeName'`
///   - `tagPrefix!=''` → prefixed-form: `'$tagPrefix ⚙ NodeName'`
///     (subscription tag-prefix + space + ⚙-prefix).
///
/// Heuristic: `startsWith('⚙ ')` (bare) ИЛИ `contains(' ⚙ ')`
/// (после subscription prefix). Совпадение с буквальным `⚙` в середине
/// произвольного юзерского node-имени (`'My ⚙ Server'`) — known
/// false-positive, считается приемлемым: ⚙ — функциональный маркер
/// detour-семантики, использование его как декоративного символа в
/// собственном tag'е сбивает с толку и без этой проверки.
bool isDetourDisplayTag(String tag) =>
    tag.startsWith(kDetourTagPrefix) || tag.contains(' $kDetourTagPrefix');
```

Три call-site'а: `t.startsWith(kDetourTagPrefix)` → `isDetourDisplayTag(t)`.
Семантика на пустом `tagPrefix` сохраняется bit-exact (startsWith leg).

### Почему не `state.configCache.detourTags`

`ConfigCache.detourTags` (см. `home_state.dart:53-75`) собирает тэги
outbound'ов **у которых установлено поле `detour`** — то есть
**пользователи** detour-сервиса, а НЕ сами detour-сервера. Это разные
множества:

```
NodeA  { tag: '🇷🇺 RU NodeA',  detour: '🇷🇺 RU ⚙ HopB' }  ← в detourTags
HopB   { tag: '🇷🇺 RU ⚙ HopB',                          }  ← НЕ в detourTags
```

UI скрывает именно HopB (intermediate hop). Поэтому реюз `configCache` не
подходит без отдельного `detourServerTags` поля — но prefix-based детект
работает на статической строке без расширения cache schema.

## Не в скопе

- Расширение `ConfigCache` отдельным полем `detourServerTags: Set<String>`
  (более robust детект через парсинг raw outbounds на наличие `⚙` в
  bare-tag'е после `_unwrapPrefix`). Возможный future cleanup если
  prefix-heuristic начнёт ложно срабатывать на реальных юзерских
  тэгах — пока не наблюдается.
- `node_settings_screen.dart:83,88,90` — там тоже `startsWith`/manipulation
  `kDetourTagPrefix`, но input — `_tagCtrl.text` (raw editable bare-tag
  без subscription prefix'а), bug не воспроизводится.
- `server_list_build.dart:67` — `main.tag.startsWith(kDetourTagPrefix)` —
  input `main.tag` это **base** (до `_withPrefix`), bug не воспроизводится.
- UX изменение поведения detour toggle (отдельный chip в filter dialog
  вместо global toggle) — отдельная фича.

## Файлы

- `app/lib/config/consts.dart` — добавить `isDetourDisplayTag` helper.
- `app/lib/screens/home_screen.dart` — два call-site'а (`_computeDisplayList`
  + `_buildNodeList`) → helper.
- `app/lib/screens/node_filter_screen.dart` — `_load` → helper.
- `app/test/config/consts_test.dart` (new) — unit tests хелпера.
- `docs/spec/tasks/079-detour-prefix-aware-tag-detection.md` (этот файл).

## Acceptance criteria

- [ ] `isDetourDisplayTag('⚙ X')` → true (bare-form).
- [ ] `isDetourDisplayTag('🇷🇺 RU ⚙ X')` → true (subscription prefix).
- [ ] `isDetourDisplayTag('Plain Node')` → false.
- [ ] `isDetourDisplayTag('🇷🇺 RU Plain')` → false (prefix без ⚙).
- [ ] `isDetourDisplayTag('')` → false.
- [ ] Home, `_showDetourNodes=false` + subscription с tagPrefix:
      detour-сервера скрыты из listа.
- [ ] NodeFilterScreen + subscription с tagPrefix: detour-сервера
      отсутствуют в чекбокс-списке.
- [ ] Subscription с пустым tagPrefix: regression-free
      (bit-exact поведение как до §079 для bare-form'ы).

## Manual verification

После APK install:
1. Подписка с `tagPrefix='🇷🇺 RU'` и detour-цепочкой → refresh config.
2. Home → toggle detour OFF (filter icon → switch) → проверить что
   тэги вида `'🇷🇺 RU ⚙ ...'` НЕ в списке.
3. Открыть NodeFilterScreen (✨auto picker) → убедиться что detour-сервера
   отсутствуют в списке чекбоксов.
4. Subscription без tag-prefix (или удалить tagPrefix) → перегенерить
   config → поведение detour toggle идентично p.2 (bare `'⚙ ...'`
   скрыты).
