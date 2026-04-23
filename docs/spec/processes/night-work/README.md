# Night autonomous sessions

Полуавтономный агент работает в репозитории ночью, пока оператор спит. Делает **безопасные, валидированные, атомарные** улучшения: тесты, cleanup, мелкий UX, документация. Ничего крупного / рискованного / трогающего core.

## Что здесь лежит

| Файл / папка | Назначение |
|---|---|
| [`spec.md`](./spec.md) | **Канонический процесс** — единственный источник правды. Правила циклов, quality gates, scope, anti-patterns. Читать **перед любой сессией**. |
| [`startup-prompt.md`](./startup-prompt.md) | Готовый prompt для агента при запуске сессии. Paste as-is. |
| [`report-template.md`](./report-template.md) | Skeleton отчёта сессии. Агент копирует в `sessions/YYYY-MM-DD.md` на старте и заполняет по ходу. |
| [`morning-review.md`](./morning-review.md) | Чеклист оператору утром — что проверить перед merge'ом ночной ветки. |
| [`scripts/session-start.sh`](./scripts/session-start.sh) | Precondition check + branch + tag + report skeleton. Один вызов на сессию. |
| [`sessions/YYYY-MM-DD.md`](./sessions/) | Отчёты по дням. Один файл = одна ночь. |

## Как стартовать сессию

1. **Оператор вечером**, working tree clean:
   ```bash
   ./docs/spec/processes/night-work/scripts/session-start.sh
   ```
   Скрипт:
   - Проверит что working tree clean (fail если нет — оператор решает commit / stash)
   - Создаст ветку `night/autonomous-YYYY-MM-DD`
   - Тегнет `night-baseline-YYYY-MM-DD` на HEAD ветки
   - Скопирует `report-template.md` → `sessions/YYYY-MM-DD.md` с заполненным header
   - Сделает commit `chore(night): session YYYY-MM-DD baseline`
   - Распечатает инструкцию "now run agent with prompt at:"

2. **Запустить Claude Code агента** с промптом из [`startup-prompt.md`](./startup-prompt.md). Prompt ссылается на spec, template и scope rules — всё в одном месте.

3. **Утром оператор**: прогнать [`morning-review.md`](./morning-review.md) чеклист, решить merge / revert / cherry-pick.

## Инвариант процесса

Если ночной агент ведёт себя непредсказуемо — **виноват процесс**, не агент. Обновление [`spec.md`](./spec.md) с добавлением anti-pattern'а, а не правка логики агента по месту.

## Эволюция

Каждый session-отчёт должен содержать секцию **"Process feedback"** — что сработало, что сломалось. Паттерн, повторившийся в 2+ сессиях, — повод обновить `spec.md`.
