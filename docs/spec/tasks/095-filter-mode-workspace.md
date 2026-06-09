# 095 — Filter mode: больше рабочей зоны при открытом фильтре

| Поле | Значение |
|------|----------|
| Тип | UX (home node-list) |
| Проблема | При `panelExpanded` стат-полоса + Nodes-хедер + чипы съедают экран — ноды почти не видно. |

## Решение

Когда фильтр-панель открыта (`NodeFilterViewModel.panelExpanded == true`):
- **скрыть** `TrafficBar` (стат-полоса);
- **скрыть** `NodesHeader` («Nodes (N)» + sort + tune-toggle) + его отступы;
- `FilterPanel` (он рендерится первым в node-list area) поднимается на место
  хедера → строка поиска оказывается вверху;
- в `FilterPanel` рядом со строкой поиска справа — кнопка **✕** (`togglePanel`),
  ровно там где была кнопка открытия (`Icons.tune`).
- Закрыл (✕) → `panelExpanded=false` → стат-полоса + Nodes-хедер возвращаются.

Channel-dropdown + Stop/Connected остаются.

## v2 — расширено (табы + точки + STOP)

**Видимость NODES-строки:** только когда `tunnelUp && !panelExpanded`.
- **STOP-режим** (не подключено) → нод нет, фильтровать нечего → строки нет.
- Фильтр открыт → строки нет (поиск наверху).

**Точка «фильтр применён»** на кнопке `Icons.tune` (закрытый режим) когда
`filter.isActive` — как amber-точка у sort.

**FilterPanel → табы** (`TabController`, рендерим активный таб = авто-высота):
- строка **поиска (regex)** всегда сверху + ✕ закрытия;
- **сводка активных фильтров** `InputChip`'ами: tap по чипу → его таб,
  ✕ → снять фильтр (regex / каждый протокол / подписка / ping);
- табы **Regex** (эмодзи-чипы) · **Protocol** · **Subscribes** · **Settings**
  (ping + Show-detour + Show-non-matching);
- **точка на табе** где есть активный фильтр (`regexActive`/`protocolActive`/
  `subscriptionActive`/`pingActive` — новые геттеры VM).

Цель: высота фильтра ~430px → ~150-230px; + NODES/стат уходят в STOP/open →
освобождает ~4-6 рядов нод.

## Файлы
- `home_screen.dart` — NODES gate `tunnelUp && !panelExpanded`; TrafficBar
  `tunnelUp && !panelExpanded`.
- `node_filter_view_model.dart` — +геттеры `regexActive`/`protocolActive`/
  `subscriptionActive`/`pingActive`; `isActive` через них.
- `widgets/nodes_header.dart` — точка на `Icons.tune` при `filter.isActive`.
- `widgets/filter_panel.dart` — StatefulWidget+TabController: поиск+✕, сводка
  InputChip, табы с точками, контент активного таба.

## Не в скопе
- Анимация перехода (можно позже).
- Сохранение выбранного таба между сессиями.
