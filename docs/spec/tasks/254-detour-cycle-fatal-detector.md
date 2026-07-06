# §254 — detour-циклы: fatal-детектор с минимальным набором виновников (вместо тихого edge-strip)

> **СТАТУС: СОГЛАСОВАНО с владельцем** (06.07.2026). Заменяет
> «Разрыв detour-циклов» из фичи 248 (`docs/spec/features/248
> detour-channels/spec.md`) — семантика меняется с авто-правки на
> fatal + диагностику.

## Проблема (реальный кейс, device CPH2411)

Пользователь строит линейную цепочку каналов (путь пакета):
`app → vpn-5 (WARP IN) → vpn-4 ([BL], 150 нод) → vpn-1 (WARP OUT) → internet`.
Одна нода внутри vpn-5 (`IN: WARP (AWG 1.5)`) по ошибке несёт
`detour: vpn-4` — граф замыкается в кольцо `vpn-4 → vpn-5 → IN:AWG → vpn-4`.

Существующий edge-strip (§248, `_stripChannelDetourCycles`) отреагировал так:

1. **Разорвал не то ребро**: снял `detour` у всех **150 членов** канала
   vpn-4 ([BL]-ноды — транзитные, невиновные), а ребро-виновник
   (`IN:AWG → vpn-4`, одна нода) оставил нетронутым.
2. **Молча**: warning `removed detour from 150 node(s)…` ушёл только в
   `AppLog` (subscription_controller.dart:1383) — в UI ничего; юзер узнал
   о потере всей WARP-цепочки по мёртвому трафику.

## Решение (согласовано)

**«Не делаем сами действий, но и конфиг не собираем».** Детектор находит
циклы и **минимальный набор нод-виновников**; конфиг с циклом — fatal
(ядро всё равно отклонит его на старте: топосорт `startOutbounds`,
`circular outbound dependency`; selector объявляет зависимостями ВСЕХ
членов). Мы ловим то же условие раньше и говорим юзеру, **какие ноды
развязать**.

| Было (§248) | Стало (§254) |
|---|---|
| авто-снятие `detour` у членов замыкаемого канала | ничего не снимается |
| конфиг собирается молча-исправленным | конфиг НЕ собирается (fatal, как §141) |
| warning в лог | bottom sheet при попытке старта: короткая ошибка + цикл при раскрытии |
| виновник не назван | минимальный набор виновников (1 нода, не 150) |

Ядро не трогаем (рантайм-кольца через `SelectOutbound` — вне скоупа,
решение владельца).

## Детектор (validator-слой)

Живёт в `validateConfig` (validator.dart) — единая точка на ГОТОВОМ
конфиге (ловит и Debug API `PUT /config`, и ручные бэкапы). Поглощает
старый `_findDetourCycle` (§141 P1.8a): чистые node→node циклы —
частный случай нового графа.

### Граф

Два вида рёбер по собранному конфигу (`outbounds` + `endpoints`):

- **removable** — `node → node.detour` (ребро можно устранить правкой
  юзера); только на существующий tag (dangling уже отдельный issue);
- **структурные** — `selector|urltest → каждый член outbounds[]`
  (семантика группы, устранению не подлежит).

### Алгоритм окраски (минимальный набор виновников)

Повторять, пока в графе есть циклы:

1. **SCC** (Tarjan, итеративный). Циклические узлы = SCC размера >1
   или self-loop.
2. **Кандидаты** = removable-рёбра `(u→v)`, где u и v в одном
   циклическом SCC.
3. **Окраска**: `score(e)` = сколько узлов перестают быть циклическими
   при виртуальном снятии e (= |cyclic| − |cyclic после снятия|).
   Ребро, через которое проходят ВСЕ циклы компоненты, разваливает её
   целиком → максимальный score.
4. **Победитель** = max score (>0); тай-брейк — лексикографически по тегу
   источника (детерминизм). Виртуально снять, добавить в culprits.

**Cap `kMaxDetourCulprits = 3`**: окраска обрывается после 3 виновников.
Юзер чинит первые, пересобирает, видит следующие. Заодно рубит квадратичную
патологию (150 нод, каждая детурит в свой канал: без капа ~1.3с внутри
`generateConfig`; с капом ~0.1с — device-safe). Если набралось ровно 3 —
sheet показывает «More loops may remain — fix these and try again».

**Structural-only кольца** (кандидатов нет / все score ≤ 0 — кольцо из
`selector↔selector`, достижимо лишь ручной правкой JSON): виновников-нод
нет, репортится group-only `DetourCycle` (пустые `culprits`, сам цикл) —
компонента снимается из графа (structural-рёбра неустранимы), НЕ теряя уже
накопленных culprits других компонент и не зацикливаясь.

Каждая итерация снимает ≥1 ребро (или закрывает structural-компоненту) →
терминируется. Повторная проверка после каждого снятия: «обнажившиеся»
циклы ловятся следующей итерацией.

Для каждого culprit строится **репрезентативный цикл** (кратчайший путь
BFS от culprit.detour обратно до culprit + само ребро) — для раскрытия
в UI.

### Трассировки (проверено прототипом)

| Кейс | Циклических узлов | Кандидатов | Culprits |
|---|---|---|---|
| реальный (150 [BL] ↔ WARP) | 154 | 151 | `IN:AWG → vpn-4` — **1, не 150** |
| симметричный A∈C1→C2, B∈C2→C1 | 4 | 2 | 1 ребро (тай-брейк) |
| флагман §248 (Relay∈C, все→C) | — | 3 | `Relay → vpn-2` (1) |
| транзитивный Client→Mid→C | — | 2 | 1 ребро (equal score, тай-брейк) |
| два независимых кольца | — | — | 2 (по одному на кольцо) |
| чистый node→node A↔B | — | — | 1 (= старый `_findDetourCycle`) |

## Модель

`DetourCycle` (validation.dart) расширяется:

```dart
final class DetourCycle extends ValidationIssue {
  final List<String> cycle;                     // репрезентативный цикл (раскрытие)
  final List<({String tag, String detour})> culprits; // минимальный набор к устранению
}
```

`message` (короткая строка, EN, самодостаточно): 1 виновник →
`Routing loop: "<tag>" points back into "<detour>" — change or remove its
detour to start the VPN.`; N виновников — то же со списком тегов.
Один issue на цикл-компоненту (несколько независимых колец → несколько
issues).

## UI — bottom sheet при попытке старта

Сейчас fatal при старте → SnackBar 5с (home_screen.dart:272-291) с
плоским текстом. Для `DetourCycle` вместо SnackBar — **модальный bottom
sheet** (паттерн `aggregate_detail_sheet.dart:83-129`: grabber + header +
divider + ListView):

- **Header**: warning-иконка + `Routing loop — VPN can't start`.
- **Короткая ошибка**: `N node(s) route traffic back into their own
  chain. Fix their detour to start the VPN.`
- **Список виновников**: карточка на ноду — тег + `detour → <target>` +
  chevron (тап-affordance); **раскрытие** (ExpansionTile) показывает цикл
  целиком: `vpn-4 → [BL-нода] → vpn-5 → IN:AWG → vpn-4`.
- group-only цикл (`culprits` пуст) → лид-текст «A routing loop was found
  between groups…», карточки некликабельны.
- Прочие fatal-issues — прежний SnackBar-путь (не трогаем).

Гейт на ВСЕХ старт-путях (иначе тихая подмена конфига): `_rebuildAndStart`,
`_startWithAutoRefresh` И `_rebuildAndReconnect` (последний при VPN off =
фактический старт).

Поток данных: `SubscriptionController` получает новое поле
`lastFatalIssues` (`List<ValidationIssue>`, заполняется в catch
`generateConfig` из `FatalValidationException.issues`, очищается при
успешной генерации И на раннем return `config_locked_for_debug` — иначе
залипший цикл показал бы ложный sheet). home_screen при показе ошибки
старта проверяет: есть `DetourCycle` в `lastFatalIssues` → sheet, иначе
SnackBar.

### Навигация тап → владелец + подсветка (§255)

Тап по карточке виновника → закрыть sheet → найти ВЛАДЕЛЬЦА ноды
(`ownerOfTag`, source_lookup.dart — суперсет `sourcesOfTag`: ловит и
`UserServer` без префикса, и члена папки по bare-тегу; инвертирует
`tag_prefix` + снимает возможный dedup-суффикс `-<N>`) → открыть Servers с
`focusEntryId` → проскроллить (`Scrollable.ensureVisible`) + мигнуть строкой
(таймер-вспышка ~2.2с, локально — в экране нет `HomeState` для
персистентного кольца). Владелец не найден (custom JSON) → Servers без
вспышки. Ведём к СТРОКЕ владельца, не внутрь: detour ноды мог прийти из
личного (`member.detour`/`overrideDetour`) ИЛИ из override владельца — по
конфигу не различить, юзер сам видит где править.

## Осознанное изменение поведения: флагман-кейс §248

Старый rationale edge-strip: «relay живёт в ТОЙ ЖЕ подписке, на которую
повешен override=C → исключение опустошило бы канал». Теперь этот кейс
— **тоже fatal** (culprit = relay). Юзер устраняет вручную: выносит relay
отдельным сервером (копия URI) и целит `node_filter` канала в копию,
либо снимает подписочный override. Per-node detour у нод подписки нет —
если кейс окажется частым, отдельная фича (не в этой таске).

## Файлы

| Файл | Изменение |
|---|---|
| `services/builder/validator.dart` | детектор: граф со структурными рёбрами, SCC + окраска, cap `kMaxDetourCulprits`, structural-ветка, culprits + репрезентативный цикл; `_findDetourCycle` поглощён |
| `models/validation.dart` | `DetourCycle` + `culprits`; новый message (1/N/group-only) |
| `services/builder/build_config.dart` | удалён `_stripChannelDetourCycles` + вызов; комментарий nodeEntries |
| `controllers/subscription_controller.dart` | поле `lastFatalIssues`; заполнение в catch, очистка при успехе И на locked-return |
| `screens/home_screen.dart` | DetourCycle → sheet на всех старт-путях; `_goToCulpritOwner` (§255) |
| `screens/home/widgets/detour_cycle_sheet.dart` | новый: sheet (grabber/header/тап-карточки+chevron/раскрытие/cap-строка) |
| `screens/home/source_lookup.dart` | `ownerOfTag` (§255 — суперсет `sourcesOfTag`) |
| `screens/subscriptions_screen.dart` | `focusEntryId` + scroll-to + таймер-вспышка (§255) |
| `docs/spec/features/248 detour-channels/spec.md` | секция «Разрыв detour-циклов» → ссылка на §254, новая семантика |
| тесты | см. ниже |

## Тесты

- `builder/validator_*`: канальный цикл через selector-фан-аут → fatal
  `DetourCycle` с 1 culprit (реальный кейс в миниатюре); два независимых
  кольца → 2 issue; чистый node→node — как раньше; self-loop; urltest-
  двойник в кольце; ацикличная линейная цепочка каналов (`vpn-1 → vpn-4 →
  vpn-5`) — НЕ fatal (регрессия юзер-кейса).
- `builder/validator_test.dart` §254-группа: selector-фан-аут цикл → 1
  culprit; node-цикл НЕ теряется при structural-кольце (находка №1);
  group-only кольцо → issue с пустыми culprits; cap ≤ `kMaxDetourCulprits`.
- `builder/detour_channel_gates_test.dart`, группа переписана на §254:
  цикл теперь `validation.hasFatal` + culprits (detour НЕ снят), warning
  `removed detour` не существует; реальный кейс (3 [BL]∈C→C2, 1 AWG∈C2→C)
  → culprit ровно AWG (не флот); линейная цепочка → ok; флагман — fatal с
  culprit=Relay; два кольца → 2 issue.
- `screens/home/source_lookup_test.dart` §255-группа `ownerOfTag`:
  prefixed sub / bare UserServer / член папки / dedup-суффикс / bare `-2`
  выигрывает / null / первый-матч.
- Контракт: `hasFatal` → `FatalValidationException` → конфиг не
  сохраняется (существующий §141-путь, тест есть).

## Связанные

- §248 detour-каналы (фича; секция разрыва циклов заменяется этой таской).
- §141 P0.1/P1.8a (fatal-контракт + старый цикл-детектор).
- §250 last_start_error (диагностика падений старта).
- §239 FolderDetourPlan (интра-циклы папки — НЕ трогаем: другой слой,
  рвёт до эмиссии; validator ловит то, что просочилось).
