# 283 — Отключение отдельных нод подписки

| Поле | Значение |
|------|----------|
| Тип | Feature (модель + builder + UI) |
| Статус | Спека утверждена, реализация не начата |
| Связано | [234 server-folders](../234%20server-folders/spec.md) (эталон per-member toggle), [129 file-subscription](../129%20file-subscription/spec.md) (file:-подписки — GC выключен), task [172](../../tasks/172-heal-dangling-detour.md) (heal detour на выключенную ⚙-ноду), task [221](../../tasks/221-backup-allowlist-export.md) (backup-инвариант) |

Пользователь может выключить отдельную ноду **внутри подписки** — как это уже
умеют папки (§234 per-member toggle), — не трогая источник. Выключенная нода
видна в списке (с тогглом), но не эмитится в sing-box конфиг. Отметка
переживает refresh и рестарт, потому что ключуется **хешем сути узла**, а не
позицией/тегом.

Контекст: состав подписки владеется источником — `nodes` перезаписывается на
каждом refresh и вообще не персистится (`toJson` хранит только `url`; тело —
в `HttpCache`, узлы регидрируются парсом). Поэтому «выключенность» — отдельный
персистентный оверлей на записи подписки.

## Нецели

- UserServer (paste-списки) и папки — вне скоупа v1. Папки уже умеют
  (`FolderMember.enabled`); paste-списки — потом тем же механизмом, если
  понадобится.
- Авто-отключение нод, роняющих старт ядра, — отдельная возможная фича; этот
  механизм её не знает и не хранит «кто выключил» (решение пользователя
  2026-07-18: без учёта источника выключения).
- Health/ping-фильтры — нет, только ручной toggle.

---

## 1. Идентичность ноды: hash сути

**Решение пользователя (2026-07-18):** ключ = «сервер целиком + все его
параметры», т.е. хеш канонического эмита узла, а не tag (теги в подписках
переименовываются косметически) и не позиция (состав дышит).

### Формула

```
nodeIdentityHash(spec) =
  sha256( jsonEncode( deepSortKeys( spec.emit(TemplateVars.empty).map
                                    .. remove('tag') .. remove('detour') ) ) )
  → hex-строка
```

Обоснование каждого шага (проверено разведкой по коду):

- **`emit(TemplateVars.empty)`** — канонический sing-box-map узла. Сегодня
  `vars` на emit не влияет вообще (все `TransportSpec.toSingbox(vars)`
  игнорируют аргумент; tls_fragment — post-step `applyTlsFragment` по уже
  собранному конфигу) — `emit(empty) ≡ emit(любые vars)`. UI уже использует
  этот паттерн (`node_settings_screen.dart:114`).
- **Вырезать `tag` и `detour`** — ровно два контекстных поля в map:
  `tag` = производная от пользовательской ремарки (§243 name=tag),
  `detour` = tag chained-ноды (тоже нестабилен). Всё остальное — свойства
  самой ноды. `id`/`label`/`rawUri`/`warnings` в map не попадают вовсе.
- **`deepSortKeys`** — рекурсивная сортировка ключей Map (вглубь Map/List)
  перед `jsonEncode`. Готового util в проекте НЕТ (`canonicalJsonForSingbox`
  не сортирует; Dart `jsonEncode` сохраняет insertion order) — написать
  (~15 строк). Без этого хеш зависит от порядка полей в коде эмиттера.
- **sha256** — `package:crypto` добавить в direct deps `app/pubspec.yaml`
  (уже в `pubspec.lock` как transitive 3.0.7 — ничего не пересобирается).
  Самописный sha256 из `tool/l10n/src/sha256.dart` не переиспользовать —
  tool/ изолирован от lib/ намеренно.

### Свойства (и их цена — зафиксировано осознанно)

| Событие | Хеш | Отметка |
|---|---|---|
| Провайдер переименовал ноду (tag/label) | не меняется | держится ✓ |
| Refresh, нода на месте | не меняется | держится ✓ |
| Нода временно пропала и вернулась | не меняется | держится (до TTL, §3) ✓ |
| Провайдер сменил суть (порт/uuid/sni…) | меняется | слетает — «другой узел», корректно |
| Дубли: один сервер, разные лейблы | ОДИН хеш | один toggle гасит все дубли разом — by design («сервер целиком»); UI покажет близнецов выключенными синхронно |
| Релиз приложения изменил схему emit | может измениться | отметки могут слететь после апдейта — известное ограничение v1, TTL-GC (§3) вычистит осиротевшие |

emit — нормализующий (мусор §115/§217/§281/§282 не эмитится), поэтому ноды,
различающиеся только мусорными параметрами, сливаются в один хеш — плюс.

Хеш включает креденшелы (uuid/password) — необратимо (sha256), наружу не
раскрывает.

### Chained и ⚙-ноды

`emit()` всегда возвращает один map (chained — только строкой `detour`,
которую вырезаем) → **одна нода списка = один хеш**, хеш покрывает сам узел
без цепочки. ⚙-ноды (standalone detour-цели) — обычные члены `nodes`,
выключаются как все; повисшие на них `detour`-ссылки лечит существующий
`healDanglingDetours` (§172) с warning — зависимые ноды работают напрямую.
Chained-дети (развёрнутые строки UI, не члены `nodes`) собственного toggle
не имеют — выключается родитель целиком.

---

## 2. Модель и хранение

Новое поле на `SubscriptionServers` ([server_list.dart:49](../../../app/lib/models/server_list.dart)):

```dart
/// hash → когда источник ноды последний раз видели в теле подписки.
final Map<String, DateTime> disabledHashes;
```

JSON: `'disabled_hashes': {"<hex>": "<iso8601>", ...}`.

- **Парно в `toJson` И `fromJson` И `copyWith`** — обязательное трио.
  Разведка backup: merge-импорт прогоняет записи через `fromJson→toJson`
  (backup_service.dart:337-359), и любая мутация списка = полный re-serialize
  через модель; поле только в toJson молча потеряется. Прецедент эволюции
  без миграции — `DetourPolicy.replaceDetourChain` («старые backup без
  ключа → default»), дефолт `const {}`.
- **Backup — правок НЕ требует**: export отдаёт top-level ключ
  `server_lists` целиком (`deepCloneJson`, вложенные поля не
  инспектируются), import-allowlist проверяет только имена top-level
  ключей — `server_lists` уже разрешён. §221-инвариант касается только
  top-level ключей — здесь их не появляется.
- Зеркало счётчика папок: `int get disabledCount` (по текущим `nodes`:
  сколько из них попадает в `disabledHashes` по хешу — НЕ размер map,
  в map могут спать хеши отсутствующих нод).

Где НЕ храним: `HttpCache` — эфемерный (перезаписывается на refresh,
чистится clear-cache, стирается при смене url, не бэкапится).

---

## 3. TTL-очистка спящих хешей

**Решения пользователя (2026-07-18):** отметка не вечная — если источник ноды
не появляется в подписке дольше порога, хеш удаляется. Каждый хеш помнит,
когда последний раз находил источник (`lastSeen`). При выключении ноды
`lastSeen = now`.

```dart
kDisabledHashTtlIntervals  = 3;        // порог в интервалах обновления
kDisabledHashTtlFloorHours = 24;       // пол: не меньше суток
kDisabledHashTtlCeilHours  = 24 * 30;  // потолок: не больше месяца

threshold = clamp(kDisabledHashTtlIntervals * updateIntervalHours,
                  kDisabledHashTtlFloorHours, kDisabledHashTtlCeilHours);
```

| `updateIntervalHours` | 3×interval | threshold |
|---|---|---|
| 1 | 3ч | 24ч (пол) |
| 24 (дефолт) | 72ч | 72ч |
| 168 | 504ч | 504ч |
| 336 | 1008ч | 720ч (потолок) |

### Когда срабатывает GC — только успешный СЕТЕВОЙ refresh

На пути, где подписка получила свежее тело из сети и статус стал
`UpdateStatus.ok` (subscription_controller: ручной refresh ~:745-776 и
auto-update ~:841 — `copyWith(nodes: result.nodes)`), одним проходом:

```
freshHashes = { nodeIdentityHash(n) for n in result.nodes }
для каждого (hash, lastSeen) в disabledHashes:
  hash ∈ freshHashes                  → lastSeen = now
  иначе если now − lastSeen > threshold → удалить отметку
```

GC **не** срабатывает:
- на failed refresh (нет сети ≠ нода ушла; §026 фризинг после 5 фейлов —
  подписка может неделями не обновляться, отметки живых серверов трогать
  нельзя);
- на регидрации из HttpCache при старте приложения (:164-198 — тело старое,
  новой информации о составе нет);
- у file:-подписок (§129, «Skip fetch: keeping cached nodes» :1484) — нет
  внешнего источника истины об уходе ноды; их отметки живут до ручного
  включения/удаления подписки.

Жизненный цикл вне TTL: удаление подписки уносит запись целиком (отметки
внутри неё) — отдельной чистки не нужно; смена url отметки сохраняет (та же
запись — те же серверы под другим зеркалом).

---

## 4. Фильтрация в билдере

Точка — цикл `ServerListBuild.build()`
([server_list_build.dart:26-27](../../../app/lib/services/builder/server_list_build.dart)),
сразу после `final server = nodes[i];`:

```dart
// §283 — выключенная нода подписки не эмитится (видна в UI с toggle).
if (this is SubscriptionServers &&
    (this as SubscriptionServers)
        .disabledHashes.containsKey(nodeIdentityHash(server))) {
  continue;
}
```

Почему здесь (разведка, отвергнутые альтернативы):
- **НЕ в `NodeSpec.getEntries`** — контракт policy-free («узел не знает про
  ServerList»), переиспользуется headless probe (`probe_config.dart:59`) и
  view-JSON UI — фильтр протёк бы в модель.
- **НЕ фильтр в конструкторе модели** (как у папок) — у подписки `nodes`
  нужен UI ПОЛНЫЙ (выключенные ноды видны с тогглами); прятать их из
  `nodes` = прятать из списка. Семантика «видна, но не эмитится» = билдер.
- Гейт по типу тривиален (в build уже есть `switch (this)` для plan), и у
  подписки `plan == null` — пропуск индексов не скашивает
  `FolderDetourPlan.policyFor(i)`.

**Зеркало в warnings-цикле**: `build_config.dart:210-218` итерирует
`list.nodes` напрямую (мимо build) — применить тот же фильтр, иначе
warnings выключенных нод продолжат сыпаться в emitWarnings/AppLog.

Последствия пропуска (все закрыты существующими механизмами):
- каналы §125: selector строится из фактически эмитированных тегов;
  auto-двойник не эмитится при пустом наборе; empty-fallback [block,direct];
- `detour` на выключенную ⚙-ноду → `healDanglingDetours` (§172) снимает
  ссылку + warning, зависимая нода работает напрямую;
- allocateTag: у тёзок могут смениться суффиксы — эквивалентно уходу ноды
  на refresh, не новое поведение.

Кеширование хеша: `nodeIdentityHash` дёргается на каждый build для каждой
ноды подписки с непустым `disabledHashes`. sha256+sort по map из ~15 полей —
микросекунды; на 10k нод допустимо. Если профайлер покажет иное — мемоизация
`Expando<String>` по NodeSpec (объект живёт до следующего reparse), НЕ поле
в модели.

---

## 5. UI

Экран деталей подписки, таб Nodes
([subscription_node_list.dart](../../../app/lib/screens/subscription_detail_screen/widgets/subscription_node_list.dart)).
Эталон — folder_detail (§234):

- **Строка ноды**: `Switch` в leading (`SizedBox(width: 40)`, паттерн
  `_MemberTile` folder_detail_screen.dart:1546-1554); выключенная — title
  цветом `onSurfaceVariant`. Существующий `onLongPress`-меню (Copy node
  info / Copy tag) не трогаем; `onTap` остаётся свободным.
- Chained-дети (развёрнутые строки `_loadNodes` :137-141) — БЕЗ toggle
  (управляется родителем). ⚙-ноды — с toggle.
- Дубли по хешу переключаются синхронно (состояние Switch — производная
  от `disabledHashes.containsKey(hash)`, не по-строчная).
- **Счётчик**: в шапке `subscription_meta.dart:74-83` к
  `subEntryNodesCount` добавить ` · M off` при M>0 — переиспользовать
  существующий ARB-ключ `folderOffCount` (или общий новый; строки
  английские, ru — в ARB, §NNN в строках запрещены).
- **Мутация**: новый метод `SubscriptionController`
  `toggleSubscriptionNode(int index, NodeSpec node)` по канону
  `toggleMemberAt` (:1051-1064): `copyWith(disabledHashes: ...)` →
  `entry._replaceList` → `_persist()` (ставит `configDirty`) →
  `notifyListeners()`. Гейта §275 нет — он только для каналов; серверные
  листы мутируются контроллером напрямую.
- Виджет `SubscriptionNodeList` получает колбэк + набор выключенных хешей
  (сейчас он StatelessWidget без контроллера — сохранить чистоту, данные
  сверху).

Опционально (не v1): bulk-действия («reset disabled»), по образцу
`setMembersEnabled`.

---

## 6. Порядок реализации

1. `app/lib/services/node_hash.dart`: `deepSortKeys` + `nodeIdentityHash` +
   константы TTL; `crypto` в pubspec direct deps.
2. Модель: `disabledHashes` в `SubscriptionServers`
   (toJson/fromJson/copyWith, дефолт `const {}`) + `disabledCount`.
3. Builder: фильтр в `ServerListBuild.build` + зеркало в warnings-цикле
   build_config.
4. Контроллер: `toggleSubscriptionNode` + GC-проход в двух refresh-путях.
5. UI: Switch в строке, счётчик в шапке, ARB en+ru.
6. Тесты (§7).

## 7. Тесты

- **node_hash**: одинаковый узел → одинаковый хеш; смена label/tag → тот же;
  смена uuid/port → другой; deepSortKeys детерминирован (перестановка
  ключей входа → тот же хеш); chained не влияет (detour вырезан).
- **Модель**: toJson→fromJson→toJson сохраняет `disabled_hashes` (грабля
  merge-импорта); copyWith других полей не затирает; старый JSON без ключа
  → `{}`.
- **Builder**: выключенная нода не эмитится; включённые эмитятся; selector
  каналов её не содержит; warnings выключенной не попадают в emitWarnings;
  detour на выключенную ⚙ → снят heal'ом с warning; UserServer/folder не
  фильтруются.
- **GC**: нода в свежем теле → lastSeen обновлён; отсутствует < threshold →
  отметка на месте; > threshold → удалена; clamp (1ч→24ч, 24ч→72ч,
  336ч→720ч); failed refresh / регидрация из кэша / file:-подписка → no-op;
  toggle-off ставит lastSeen=now.
- **Round-trip через backup**: buildExport→applyImport (merge) сохраняет
  отметки.

## Docs to update

- `docs/STORAGE.md` — поле `disabled_hashes` в записи `server_lists`
  (схема + TTL-семантика).
- `docs/ARCHITECTURE.md → Feature Specs` — строка фичи 283.

## Решения пользователя (лог)

- 2026-07-18: механизм ручной, без учёта «кто выключил»; хранение — рядом с
  подпиской; ключ — хеш сервера целиком со всеми параметрами.
- 2026-07-18: хеш ушедшей ноды не удалять сразу (мигание состава ≠
  удаление); удалять по TTL: `3 × updateIntervalHours`, пол 24ч, потолок
  месяц; `lastSeen = now` при выключении.
