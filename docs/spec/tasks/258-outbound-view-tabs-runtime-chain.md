# 258 — View-экран ноды: вкладки Overview/JSON + кликабельная рантайм-цепочка detour

| | |
|---|---|
| Статус | done |
| Триггер | Юзер: «у нас классный новый инструмент — переход к узлу (§255). Переделаем меню: view json → view с вкладками: 1) view — основные параметры и все detour-цепочки в рантайме с возможностью кликнуть и перейти на сервер; 2) JSON» |
| Родители | §099 (Copy в View JSON), §091 (`ParsedConfig`), §252 (порядок «по ходу пакета»), §255 (навигация к владельцу тега), §125/§248 (каналы / detour-каналы) |

## Мотивация

`OutboundViewScreen` («View JSON» из контекстного меню ноды) показывал только
сырой JSON. Между тем у собранного конфига есть готовая структурная модель
(`ParsedConfig`, §091), у приложения — живые выборы селекторов
(`SelectorInfo`, §251) и проверенная навигация «тег → экран владельца» (§255).
Складываем: экран получает вкладку Overview с основными параметрами и
**рантайм-цепочкой detour** — реальный путь пакета по СОБРАННОМУ конфигу
(включая текущие выборы каналов), каждый хоп кликабелен и ведёт к владельцу.

## Решения (согласовано с юзером)

1. Цепочка — «по ходу пакета» (§252): Phone слева/сверху, Internet справа/снизу,
   самый глубокий транспорт первым, сама нода последней.
2. Клик по хопу — та же навигация, что в detour-cycle sheet (§255:
   папка+подсветка / подписка / одиночный сервер), **плюс** канал `vpn-N`
   (или его `-auto`-двойник) → Routing, таб Channels, подсветка канала.
3. Нода подписки → `SubscriptionDetailScreen` (Settings-таб) — персонального
   экрана у подписочной ноды нет, консистентно с §255.

## Рантайм-цепочка vs §252 `detourPathHops`

`detourPathHops` (§252) разворачивает **storage**-значение detour (превью в
редакторах, до сборки). Здесь другой источник — **собранный конфиг**:

- экспансия `ParsedConfig`-полем `detour`: `self → его detour → …`;
- **селектор/urltest не терминален**: продолжаем через текущий выбор
  `SelectorInfo.I.selectedOf(tag)` (туннель up); выбор неизвестен (туннель
  down) → цепочка честно обрывается на канале, в UI строка-эллипсис
  «connect to see the full path»;
- гейты: `seen`-set (циклов в собранном конфиге не бывает после §254, но
  guard остаётся) + потолок 12 хопов;
- результат разворачивается в порядок пакета (как §252).

`app/lib/services/runtime_chain.dart`:

```dart
class RuntimeHop {
  final String tag;
  final String type;        // '' = тега нет в конфиге (обрыв)
  final Channel? channel;   // хоп — канал §125 (tag или autoTag)
  final bool viaSelection;  // хоп достигнут через выбор селектора
}

Channel? channelForTag(String tag, List<Channel> channels); // tag | autoTag

List<RuntimeHop> runtimeChainOf(String tag, ParsedConfig config, {
  required List<Channel> channels,
  String? Function(String tag)? selectedOf, // default SelectorInfo.I (инъекция для тестов)
});
```

Трассировка (сага §254, туннель up):
`IN: WARP` → detour `vpn-4`, vpn-4 выбрал `[BL]`, `[BL]` → detour `vpn-5`,
vpn-5 выбрал `WARP OUT`:

```
экспансия: [IN: WARP, vpn-4, [BL], vpn-5, WARP OUT]
пакет:     Phone → WARP OUT → vpn-5 → [BL] → vpn-4 → IN: WARP → Internet
                   ^viaSelection      ^viaSelection
```

## Общая навигация: `openTagOwner`

§255-логика жила приватным `_goToCulpritOwner` в `home_screen`. Выносится в
`app/lib/screens/owner_navigation.dart` и расширяется каналом:

```dart
Future<void> openTagOwner(BuildContext context, String tag, {
  required SubscriptionController subController,
  required HomeController homeController,
  List<Channel>? channels,          // null → SettingsStorage.getChannels()
  required VoidCallback onOwnerNotFound,
});
```

Порядок веток:
1. **канал** (`tag == c.tag || c.autoTag`, любой канал — вкл/выкл) →
   `RoutingScreen(focusChannelTag: c.tag)`;
2. `ownerOfTag` (§255): папка → `FolderDetailScreen(focusMemberIndex)`;
   одиночный → `NodeSettingsScreen`; подписка → `SubscriptionDetailScreen`;
3. не найден → `onOwnerNotFound` (детур-sheet: список Servers как раньше;
   View-экран: SnackBar).

Приоритет канала над `ownerOfTag` безопасен: config-тег, равный тегу канала,
и есть канал (билдер дедуплицирует коллизии `allocateTag`-суффиксом).
Патология «нода, буквально названная `vpn-4`, при выключенном канале» ведёт
в Routing вместо ноды — принятый tradeoff (см. tradeoff-абзац §091 в
`sourcesOfTag`).

`home_screen._goToCulpritOwner` → тонкая обёртка над `openTagOwner`
(закрыть sheet + fallback на `SubscriptionsScreen`). Поведение §255 —
байт-в-байт, плюс новая канальная ветка.

## `RoutingScreen.focusChannelTag`

Аналог `focusMemberIndex` (§255): опциональный тег; после `_load()` —
post-frame `Scrollable.ensureVisible` по GlobalKey тайла + вспышка 2.2 с
(`AnimatedContainer`, стиль как у члена папки). Retry-акробатика §255 не
нужна: таб Channels — нелениый `ListView(children:)`, тайл смонтирован с
первого кадра.

## UI: `OutboundViewScreen`

`StatelessWidget` → `StatefulWidget`, `DefaultTabController(length: 2)`,
вкладки **Overview** / **JSON**. AppBar (заголовок `kind · tag`,
Copy-аффорданс §099) — общий.

**Overview:**
- Parameters: Type (`type` + `· endpoint` для endpoint-kind), Server
  (`server:server_port`), Transport / Security (готовые лейблы §102/§103
  из `ConfigNode`), для групп — Members (длина `outbounds`).
- Route: `Phone` → хопы → `Internet` (порядок пакета). Хоп-строка: иконка
  (канал/группа `hub`, нода `dns`, обрыв `help`), title (канал → `⚙ label`),
  subtitle (`type` · `current pick` для viaSelection · `this node` для
  последнего), chevron, tap → `openTagOwner` (не найден → SnackBar).
  Обрыв на неразрешённом селекторе (туннель down) → строка-эллипсис после
  Phone.

**JSON:** прежний read-only monospace TextField (контроллер теперь создаётся
один раз в `initState` — раньше протекал новым инстансом на каждый build).

Пункт меню ноды: `View JSON` → `View details` (внутреннее значение
`view_json` не трогаем).

Прокладка данных: `HomeNodeList` уже держит `controller`/`subController` —
`viewOutboundJson(context, tag, state, subController:, homeController:)`
передаёт их экрану вместе с `state.configModel`.

## Файлы

| Файл | Изменение |
|---|---|
| `app/lib/services/runtime_chain.dart` | NEW — `RuntimeHop`, `channelForTag`, `runtimeChainOf` |
| `app/lib/screens/owner_navigation.dart` | NEW — `openTagOwner` (§255-навигация + каналы) |
| `app/lib/screens/outbound_view_screen.dart` | вкладки Overview/JSON, chain-UI |
| `app/lib/screens/home/node_actions.dart` | `viewOutboundJson` — прокладка контроллеров |
| `app/lib/screens/home/widgets/node_list.dart` | call-site |
| `app/lib/widgets/node_row.dart` | пункт меню `View details` |
| `app/lib/screens/routing_screen.dart` | `focusChannelTag` + подсветка тайла |
| `app/lib/screens/home_screen.dart` | `_goToCulpritOwner` → `openTagOwner` |
| `app/test/services/runtime_chain_test.dart` | NEW — цепочка/каналы/выборы/гейты |

## Не делаем

- Не трогаем `detourPathHops` (§252) — редакторские превью живут на storage.
- Не строим экран настроек подписочной ноды (решение 3).
- Не показываем members-раскрытие групп на Overview (есть View pool §208).
