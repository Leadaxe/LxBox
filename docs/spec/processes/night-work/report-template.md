# Night autonomous session — {{DATE}}

> ⚠ Это **skeleton**. Скрипт `scripts/session-start.sh` копирует этот файл
> в `sessions/{{DATE}}.md` и подставляет `{{DATE}}` / `{{BASELINE_COMMIT}}`
> / `{{BUDGET_HOURS}}`. Агент затем заполняет остальные секции по ходу
> работы.

**Ветка:** `night/autonomous-{{DATE}}`
**Baseline-tag:** `night-baseline-{{DATE}}` (commit `{{BASELINE_COMMIT}}`)
**Бюджет:** {{BUDGET_HOURS}} ч
**Фактически потрачено:** <заполнить в конце>
**Бейслайн-метрики:** <заполнить после шага 4 startup'а> — тесты / analyze / APK size
**Итог:** <заполнить в конце> — тесты / analyze / APK size

---

## TLDR утром

> Заполняется ПОСЛЕДНИМ коммитом сессии. Утренний оператор читает **только** этот
> раздел + Incidents, чтобы решить merge / revert / cherry-pick.

### Rollback-инструкция

```bash
# Откатить всю сессию
git reset --hard night-baseline-{{DATE}}

# Откатить конкретный цикл (пример — Cycle 3)
git revert <cycle-3-commit>
```

### Что сделано (по циклам)

| # | Тема | Коммит | Тесты ∆ |
|---|------|--------|---------|
| 1 | <title> | `<hash>` | +N |
| 2 | <title> | `<hash>` | +N |
| ... | | | |

### Самые полезные видимые изменения

1. <…в порядке ценности для юзера…>
2. <…>

### Сценарии для ручной проверки на устройстве

- [ ] <…что конкретно делать + что ожидается…>
- [ ] <…>

### Deferred — в следующую сессию

Список идей, отклонённых как `next-cycle`, плюс инсайты из неудачных pivot'ов.

---

## Baseline snapshot (после шага 4 startup'а)

```
flutter analyze: <N issues / clean>
flutter test:    <N tests, all pass>
APK size:        <MB>
git log --oneline night-baseline..HEAD:
<здесь ничего кроме baseline-коммита на этом шаге>
```

---

## Cycle 1

### Идеи (10)

> Каждая идея с **источником** в скобках: `(analyze)` / `(task:NNN)` /
> `(memory:feedback_name)` / `(diff-gap)` / `(prev-deferred)` / `(personal-obs)`.

1. <idea> (<source>)
2. …
10. …

### Обсуждение

> ПМ / Архитектор / Маркетолог. Маркетолог: **без confabulated статистики**.
> Если ссылаешься на "жалобы юзеров" — WebFetch реального треда с цитатой,
> иначе rationale без чисел.

**ПМ:** <текст>

**Архитектор:** <текст>

**Маркетолог:** <текст>

### Выбраны

- **T1-1**: <name> — <why>
- **T1-2**: <name> — <why>
- **T1-3**: <name> — <why>

### Отклонены (с категориями)

> Категории: `too-risky-for-branch` / `out-of-scope` / `needs-baseline` /
> `low-ROI` / `next-cycle` / `blacklist-touched`

- Idea N (`<category>`): <одна строка почему>
- …

### Реализация

> Заполняется по мере делания. Если pivot — добавить строку
> "Tn-m reassigned: X → Y, reason: Z" **до** коммита.

**T1-1 — <what happened>**

Commit: `<hash>` — <subject>

**T1-2 — …**

### Результат цикла

- Commits: `<hash>`, `<hash>`, …
- Тесты: `N → M` (+K)
- `flutter analyze`: `<0 issues / N warnings>`
- Incidents: `<none / <краткое описание>>`

---

## Cycle 2

<тот же шаблон>

---

## (дальше сколько циклов было)

---

## Incidents

> Всё что пошло не по плану. Empty OK — значит было чисто.

- <timestamp> — <что произошло — что сделал>

---

## Process feedback

> Что в процессе работало хорошо / что мешало. Основа для эволюции `spec.md`.

- **Сработало**: <…>
- **Было неудобно / сломалось**: <…>
- **Предложения в spec.md**: <…>

---

## Deferred

> Идеи отклонённые как `next-cycle` + те что всплыли но не успели обсудить.
> Служит входом для следующей сессии.

- <…>
