# §252 — Route-строка: физический путь пакета + превью цепочки в настройках detour

> **СТАТУС: РЕАЛИЗОВАНО** (06.07.2026). Фидбэк владельца после §251: хвост
> Route-строки читался задом наперёд относительно движения пакета
> («пакет так не идёт — он выходит в WARP out», а WARP out стоял ПЕРВЫМ
> после `:`). Формат согласован владельцем на живом эталоне.

## Формат (эволюция §181, «нотацию не терять»)

`процесс ⇒ [net] правило ⇒ селекторы : физическая цепочка → цель`

Эталон владельца (реальное соединение, WARP-MASQUE через detour-канал):

```
Приложение ⇒ [tcp] final ⇒ vpn-1 : 🔥🎭 WARP in → vpn-4 (🇬🇧 England) → vpn-1 (🔥🎭 WARP out) → alive.github.com
```

- слева от `:` — ось РЕШЕНИЯ (⇒): процесс → `[net] правило` → селекторы
  сверху вниз (как раньше; `[net]` переехал к правилу, было префиксом);
- справа от `:` — ФИЗИЧЕСКИЙ путь пакета (→ = движение): транспорт изнутри
  наружу (`detour_chain` развёрнута — вход первым), затем выход ОДНИМ
  элементом `селектор (…вложенно… (node))`, затем цель;
- выход сворачивается ПО СТРУКТУРЕ `outbound_chain` (`[node, …selectors]`
  — роли известны от ядра §174), НЕ через SelectorInfo: даже при пустом
  держателе тегов селекторы не рассыпаются в ложные «хопы»;
- detour-ось фолдится §251-правилом (`селектор (выбор)`, вложенно для
  AUTO) и разворачивается в порядок пакета;
- строка **Detour** detail-карточек — тоже физический порядок:
  `WARP in → vpn-4 (🇬🇧)`;
- compact (Live-список) — без `процесс`/`[net]`, хвост тот же.

## Превью «как пакет пойдёт» в настройках detour (паритет с серверами)

`detourPathHops(stored, controller, channels, folder?)`
(widgets/detour_target_picker.dart) — разворот сохранённой цели в цепочку
хопов; экспансия идёт вглубь (интра-член папки, bare-тег с приоритетом
FolderDetourPlan → его `member.detour` → …; одиночка display-form → её
`overrideDetour` → …; detour-канал — терминал `⚙ label (выбор)`), результат
**возвращается в порядке пакета** (глубочайший транспорт первым — §245:
detour входной), консистентно с Route-строкой.
Гейт циклов storage (билдер рвёт только на сборке): visited + потолок 6.

Применено:
- Node Settings (сервер/член): `Phone → <hops> → <node> → Internet`;
- настройки подписки И папки (`SubscriptionSettingsTab`, новый параметр
  `detourPathHopsOf` — коллбек от экрана с его controller'ом):
  `Phone → <hops> → Nodes → Internet` — та же детализация, что у серверов.

## Файлы

| Файл | Изменение |
|---|---|
| `services/traffic_profiler/models.dart` | routingLineOf: `[net]` к правилу, физический хвост, структурная свёртка выхода |
| `vpn/cc_channel.dart` | то же (идентичная строка §204) |
| `screens/stats_screen/routing_section.dart` | Detour-строка в физическом порядке; header-нотация §252 |
| `widgets/detour_target_picker.dart` | `detourPathHops` |
| `screens/node_settings_screen.dart` | превью через `detourPathHops` (многозвенное) |
| `subscription_detail_screen/widgets/subscription_settings_tab.dart` | параметр `detourPathHopsOf` + превью-цепочка |
| `screens/subscription_detail_screen.dart`, `screens/folder_detail_screen.dart` | прокидка коллбека (папка — со своим интра-контекстом) |
| тесты | обновлены форматные ожидания (cc_connection_routing, traffic_profiler, selector_info) + detour_path_hops_test |

## Связанные

- §181 (исходная нотация), §204 (общая Routing-секция), §251 (fold
  «селектор (выбор)» — базовый механизм), §248 (detour-каналы), §245
  (направление превью detour — «входной, не выходной»).
