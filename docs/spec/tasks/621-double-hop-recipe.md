# §621 — Руководство: рецепт «двойной хоп без прямого пути к последнему серверу»

| Поле | Значение |
|------|----------|
| Тип | D (документация) |
| Статус | Implemented |
| Дата | 2026-10-09 |
| Связанные | [Leadaxe/LxBox#159](https://github.com/Leadaxe/LxBox/issues/159); §393 (цепочки хопов) |

## Проблема

В #159 пользователь строит `you → Proton → WARP → internet` и требует, чтобы
Cloudflare никогда не видел его IP. Совет «собери chain» этого не
обеспечивает: цепочка — outbound `chain`, который ссылается на теги
существующих узлов (`app/lib/services/builder/chain_nodes.dart`,
`resolveChains`), и сами звенья остаются в пуле самостоятельными узлами.
Направление с пустым Node filter предлагает голый WARP наравне с цепочкой:
ручной выбор, проба auto-двойника, пинг в списке серверов ходят к Cloudflare
напрямую.

В руководстве chain и detour описаны как равноправные («решают одну задачу с
разных концов»), рецепта под этот сценарий нет — его собирают из разделов
Detour, Directions и Regular expressions, не видя, где путь утекает.

## Решение

Только документация, `docs/USER_GUIDE.md` и `docs/USER_GUIDE.ru.md`:

1. Таблица «Chain or detour?» — строка «последний сервер нельзя доставать
   напрямую»: chain — нет (звенья остаются самостоятельными узлами), detour —
   да; ссылка на рецепт.
2. Рецепт в «Recipes»: detour на последнем сервере → Node filter направления
   только на него, auto выключен → Default traffic = VPN → проверка строкой
   Detour в Statistics. Ловушка AWG → plain WireGuard (для WARP — пересоздать
   без «Add Amnezia obfuscation»).

## Проверка

- Якоря ссылок совпадают с заголовками (GitHub-slug).
- Подписи UI в тексте сверены с кодом: `Detour`, `Node filter (regex)`,
  `Include auto (urltest)`, `Add Amnezia obfuscation`.
