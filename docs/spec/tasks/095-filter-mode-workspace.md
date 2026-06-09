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

Channel-dropdown + Stop/Connected + чипы + Test/Show-detour/Show-non-matching —
**остаются** (юзер их не убирал). Sort-кнопка прячется вместе с хедером
(доступна при закрытом фильтре).

## Файлы
- `screens/home_screen.dart` — gate `TrafficBar` + `NodesHeader`(+SizedBox'ы) на
  `!_filter.panelExpanded` (home_screen ребилдится на `_filter` notify).
- `screens/home/widgets/filter_panel.dart` — строка поиска → `Row[Expanded(
  RegexFilterField), IconButton(✕ → togglePanel)]`.

## Не в скопе
- Скрытие чипов/Test/Show-тоглов (это сам фильтр).
- Анимация перехода (можно позже).
