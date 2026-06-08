# 091 — `ConfigNode` model: структурные метаданные ноды (убрать reverse-parse тега)

| Поле | Значение |
|------|----------|
| Статус | **Design agreed** (обсуждено с юзером, эта сессия). Реализация — отдельно, **behavior-changing** → своя реализация + тесты. НЕ начата. |
| Тип | refactor / architecture / **logic-rewrite** (§090-класс, но своя focused-таска) |
| Закрывает | §077 / §079 / §080 — структурно (целый класс багов «reverse-парсим display-тег») |
| Связанные | §048 (node filters), §068 (`NodeViewItem`), §085 R2 (`ConfigIntrospection`), §083 (per-channel filter) |

## Проблема

Display-тег ноды кодирует **4 ортогональных атрибута** в одну строку:
`'$tagPrefix $bare ⚙ ... -N'` = (1) префикс подписки, (2) bare-имя, (3) detour-
маркер `⚙` (`kDetourTagPrefix`), (4) collision-суффикс `-N` (`_BuildCtx.allocateTag`).
UI потом **reverse-парсит строку**, чтобы восстановить эти атрибуты — отсюда
весь класс §077/§079/§080.

Параллельно — **3 раздельных ре-деривации из `configRaw`**:
- `ConfigCache.protoByTag` (tag→протокол),
- `ConfigCache.detourTags` (tag c полем `detour`),
- `ConfigIntrospection.parse` (для View JSON / detour-chain),
- `subscriptionsOfTag` reverse-map (tag→подписка, с collision-FP).

## Ключевые факты (заземление, проверено по коду)

- `config-tag == нода в Clash == элемент `state.nodes`` — одна идентичность.
  `state.nodes` берётся из **Clash API** (`proxies[group].all`, home_controller:457-461),
  это список **тегов**.
- `config-tag ≠ нода в подписке` — единственный реальный mismatch: билдер
  наложил `prefix`+`-N`+`⚙` (`server_list_build`), а **subId в конфиг не пишется**.
- `protocol` и `detour`-поле **лежат в конфиге** по точному тегу → достаются
  без reverse-map. `subId` — НЕ лежит → только prefix или builder-emit.
- `ConfigCache` строится **лениво на смену `configRaw`** (`HomeState` ctor /
  copyWith, home_state:114/242), т.е. на load + rebuild (`saveParsedConfig`).

## Модель

**Один `ConfigNode` на каждый outbound/endpoint**, распарсенный раз из конфига,
ключ = tag. В мапу кладём **ВСЕ** outbounds (payload + служебные), различаем по
`type`. Схлопывает `protoByTag` + `detourTags` + `ConfigIntrospection`.

```dart
class ConfigNode {
  final String tag;                  // = нода в Clash
  final String type;                 // vless|trojan|…|selector|urltest|direct|block|dns
                                     //   (заменяет protocol + isControl одним полем)
  final String? detour;              // СВОЙ hop-таргет (через кого ходит) → меню + бэйдж hasDetour
  final bool   isMarkedDetour;       // `⚙` в теге (переходный — см. ниже)
  final int    detourRefCount;       // на меня ссылаются N нод (как на detour-таргет)
  final Map<String, dynamic> raw;    // сырой outbound JSON → View JSON
  bool get isDetour => detourRefCount > 0;   // структурно: «я — релей/hop-таргет»
  bool get isControl => const {'selector','urltest','direct','block','dns'}.contains(type);
}
```

**Построение (один проход по outbounds+endpoints):**
1. для каждого outbound → `ConfigNode{tag, type, detour: o['detour'], raw: o, isMarkedDetour: ⚙-в-теге}`;
2. собрать все значения `detour` → инкрементить `detourRefCount` соответствующему таргету
   (detour=='direct-out' игнорим — `preset_expand` его и так снимает).

### Статика vs Динамика (важно)

| Слой | Что | Когда обновляется |
|---|---|---|
| **Статика** | `Map<String tag, ConfigNode>` (в `ConfigCache` → можно переименовать `ParsedConfig`) | **только** на смену `configRaw` |
| **Динамика** | `lastDelay` / `pingBusy` / `activeInGroup` / `urltestNow` (отдельные map по tag) | на каждый ping/urltest |
| **Join** | `NodeViewItem` (он уже это делает: tag + delay + pingBusy + active + meta) | на рендере |

Пинги **НЕ** кладём в `ConfigNode` — иначе каждый ping пересобирал бы статик-кэш.

### Фильтры (после модели)

- **протокол:** `node.type == p` — **O(1)**.
- **detour-toggle:** `node.isMarkedDetour` (переходно) → потом `node.isDetour` — **O(1)**.
- **бэйдж hasDetour:** `node.detour != null`.
- **подписка:** `tag.startsWith('$prefix ')` — **O(N)**, **только если префикс задан**.
  Префикс не задан → чипа нет. «Custom» = тег не начинается ни с одного префикса.
  Уходит `subscriptionsOfTag` reverse-map + collision `matchesAllocated`.

## Detour-триада (не путать)

| Имя | Смысл | Источник | UI |
|---|---|---|---|
| `node.detour` | куда ХОДИТ (hop-таргет) | поле `detour` конфига | меню + бэйдж |
| `node.isDetour` | на НЕЁ ссылаются (релей) | `detourRefCount > 0` | будущий toggle |
| `node.isMarkedDetour` | `⚙` в теге | строка тега (раз) | toggle сейчас (переходно) |

### Миграция `⚙` (отдельно, потом)

Сейчас `⚙` = ручная пометка отдельных серверов как detour (toggle в
node_settings). План: **убрать ручную пометку**, разрешить любой одиночный
сервер как detour, тогда `⚙` = просто метка «внутренний сервер подписки» и в
итоге убираемая; ориентир — `isDetour` (по факту). `isMarkedDetour` — мост на
переходный период. **Не в этой итерации, продумать позже.**

## Что уходит / схлопывается

- `subscription_lookup.dart::subscriptionsOfTag` — **удалить** (reverse-map).
- `TagResolver.isDetourMarker` строкопарсинг в фильтре — заменить на
  `node.isMarkedDetour` (вычислен раз). §079 закрыт.
- `ConfigCache.protoByTag` + `detourTags` → `ConfigNode.byTag`.
- `ConfigIntrospection` (для View JSON / chain) → `node.raw` + `node.detour`.
- `matchesAllocated` collision-эвристика — не нужна (prefix-фильтр игнорит `-N`).

## Blast radius

`models/home_state.dart` (ConfigCache → ConfigNode model), `screens/home/
node_filter.dart` (предикат: protocols/subscriptions/detour), `screens/home/
node_list_presenter.dart` (`buildNodeFilter`/`splitNodes`/`protocolOfTag`/
`isControlTag`/`computeListData`), `screens/home/subscription_lookup.dart`
(удалить), `screens/home/node_actions.dart` (`viewOutboundJson` → `node.raw`),
возможно `services/config_introspection.dart` (фолд / оставить для не-home
потребителей — проверить). Чип «Custom» (детекция). node_settings `⚙`-toggle —
переходно.

## Edge cases / решения

- **Подписки без префикса** — не фильтруются (нет чипа). Принято (юзер: «не
  задан — нет поиска»).
- **Одинаковый префикс у 2 подписок** — конфлейтит. Редко; опц. валидация
  уникальности префикса.
- **Ручной импорт конфига** (config editor/backup) — ноды = «custom» (префикс
  не совпадёт). Консистентно.
- **`auto`/urltest-группа** — `type=urltest`, без protocol-лейбла (как сейчас на
  экране). Текущий fallback `protoByTag[urltestNow]` = рантайм-резолв → если
  нужен лейбл по резолву, это динамик-слой, не статик.

## Тесты (при реализации)

- `ConfigNode` parse: type / detour / `detourRefCount` / `raw` / `isMarkedDetour`
  из фикстур-конфигов (вкл. detour-цепочки, urltest, selector, prefixed/non).
- prefix-фильтр: match/no-match, без префикса, collision `-N` игнор.
- `isDetour` count: цепочка A→B→C даёт refCount B/C = 1, A = 0.
- «custom» detection: нода без совпадения префикса.
- View JSON через `node.raw` == прежний `ConfigIntrospection` вывод (chain).

## Не в скопе

- Реализация (своя итерация, behavior-changing, тесты).
- Миграция/удаление `⚙` ручной пометки (отдельно, после переходного периода).
- §089 (структурный рефактор) — независим, уже сделан.
