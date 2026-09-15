# 446 — тормоза главного экрана при большом числе узлов

| Поле | Значение |
|------|----------|
| Статус | **В работе** |
| Дата | 2026-09-15 |
| Повод | [#135](https://github.com/Leadaxe/LxBox/issues/135) — «Клиент лагает при большом количестве серверов (502)» |
| Связанные | [§071](071-manual-node-reorder.md) (manual-порядок, `ReorderableListView`), [§322](../features/322%20balancer-node/spec.md) (значки пула), [§333](333-large-text-virtualization.md) (виртуализация больших текстов) |

## Проблема

Список узлов виртуализован (`ReorderableListView.builder`,
`node_list.dart:264`) — строятся только видимые строки. Тормоза приходят не
оттуда: на каждый build пересчитывается производный слой по ВСЕМ узлам, а сам
build случается раз в секунду по тику трафика.

Комментарий в `home_controller.dart:1084` называет расчётный размер: «node-list
95 нод». У автора #135 их 502.

### Замеренные по коду места

| # | Место | Что происходит | Сложность при N=502 |
|---|---|---|---|
| 1 | `node_list_presenter.dart:276` | `_cachedSorted!.every(s.nodes.contains)` — `s.nodes` это `List<String>` (`home_state.dart:164`), `contains` линейный. Sanity-check кэша дороже сортировки, которую он экономит | ~252 000 сравнений на КАЖДЫЙ build, на cache-hit пути |
| 2 | `home_state.dart:410` | `rest.where((n) => !manualOrder.contains(n))` — `manualOrder` это `List` (`:241`). Соседняя строка `:409` уже использует `restSet` правильно | ~252 000 сравнений; `sortedNodes` это `late final`, но новый `HomeState` рождается на каждый `copyWith` → раз в секунду |
| 3 | `home_screen.dart:746` | Один `AnimatedBuilder` на весь экран, без `Selector`. Любой `notifyListeners` перестраивает AppBar, controls, traffic bar и весь список с полным `computeListData` | 1 полная пересборка/с при поднятом туннеле; ~8/с во время mass-ping (`_massPingFlushMs = 120`, `ping_orchestration.dart:212`) |
| 4 | `node_list_presenter.dart:285` | `computeListData` — 7+ проходов по N без мемоизации: pool строится дважды (`:295` и повторно в `splitNodes:229`, комментарий на `:292` это признаёт), `extractEmojis` гоняет unicode-regexp по всем тегам, `variantsOfTag` аллоцирует новый `Set` на каждый тег | O(N log N) с дорогими константами, на каждый build |
| 5 | `home_state.dart:275` | `groupOf` — линейный скан `ccGroups`, без индекса. Зовётся 2 раза на строку в `itemBuilder` (`node_list.dart:285`, `:286`) плюс трижды в `computeListData` | O(строк × групп) на кадр скролла |
| 6 | `node_list.dart:573` | `_poolBadgeOf` — вложенный цикл по всем подпискам × всем их узлам с `tag.endsWith()`, прямо из `itemBuilder`. Под гейтом `autoGroupLabel != null`, то есть бьёт по узлам автовыбора, а не по всем строкам | до N итераций на каждую видимую строку автовыбора, каждый кадр |
| 7 | `node_list_presenter.dart:61` | `poolBadges` компилирует unicode-regexp заново на каждый вызов (`tryCompileRegex`), кэша компиляции нет | по вызову на строку автовыбора за кадр |
| 8 | `dependency_graph.dart:167` | `computeSick` — BFS на каждый мёртвый корень, внутри цикла `members.contains(cur)` по `List`. При сборной подписке, где половина узлов мертва, `dead` разрастается до сотен | вызывается каждые 120 мс весь прогон mass-ping (`ping_orchestration.dart:344`) |
| 9 | `home_controller.dart:1146` | `_applyGroups` без throttle и без проверки «снапшот не изменился» (в отличие от `_onCcStatus`): каждый push groups-стрима делает новый `HomeState` → инвалидация `late final sortedNodes` → пункт 2 | по тику groups-стрима |
| 10 | `settings_storage/io.dart:335` | `_save()` — pretty-print всего кэша (включая `node_manual_order` из 502 тегов) плюс tmp+bak+rename. Зовётся из `commitManualReorder` (`home_controller.dart:1493`) | на каждый drop при перетаскивании строки |

### Что проверено и НЕ является проблемой

- Probe и ping ограничены по параллелизму: mass-ping `_pingConcurrency = 10`
  (`ping_orchestration.dart:207`), folder-probe `_concurrency = 6`. Цена не в
  числе соединений, а в стоимости каждого flush (пункты 3 и 8).
- `ParsedConfig.parse` зовётся только при смене `configRaw` (`home_state.dart:474`),
  не на каждый build; лукапы по `Map` — O(1).
- `poolSlots` / `isDirectionAutoTag` — Set/Map, кэш по `pingBatchGen`. Корректно.
- Виртуализация списка на месте (§071).

### Физика ядра, не наша

Отдельный от UI фактор, влияющий на ту же жалобу: все включённые узлы уходят в
конфиг ядра разом (`build_config.dart:387` — `outbounds`, `:413` — `endpoints`).
Для VLESS/Trojan/SS это дёшево — соединение поднимается по требованию. Для
WireGuard и AWG каждый endpoint держит состояние с таймерами независимо от
того, выбран он или нет. Пятьсот WG-узлов стоят ядру памяти и процессора,
сколько бы мы ни оптимизировали Flutter-слой.

## План

Волнами, каждая проверяема отдельно.

**Волна 1 — механические правки, снимают квадратичность.** Пункты 1, 2, 5 и
лишняя аллокация в `node_list.dart:249` (новый `Set` на каждый build, хотя
`_pinnedTags` уже готов в `HomeState:345`). `Set` вместо `List` в горячих
`contains`, `Map<String, CcGroup>`-индекс для `groupOf`.

**Волна 2 — кэш значков пула.** Пункты 6 и 7: `Map<String, String>` тег→бейдж,
строится раз на смену подписок; кэш скомпилированных regexp в `poolBadges`.

**Волна 3 — мемоизация `computeListData`.** Пункт 4: ключ из identity
`sortedNodes`, состояния фильтра, `pingBatchGen` и ревизии подписок. Заодно
убрать двойное построение pool.

**Волна 4 — гранулярность перестроения.** Пункт 3: трафик в свой
`ValueNotifier`, список на тик трафика не реагирует. Самая архитектурная
правка, делать после того, как первые три подтвердят выигрыш.

**Волна 5 — периферия.** Пункты 8, 9, 10.

## Верификация

- Синтетическая подписка ~500 узлов на AVD: скролл, переключение узла,
  mass-ping, перетаскивание строки.
- Профиль до и после по волнам; цифры в этот файл.
- Полный `flutter test` и `flutter analyze` в конце каждой волны.
