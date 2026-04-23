# Night autonomous sessions — canonical spec

| Поле | Значение |
|------|----------|
| Статус | Active |
| Версия | 1 |
| Дата создания | 2026-04-22 |
| Scope | Процесс автономных ночных работ в репе L×Box |

Этот документ — **единственный источник правды** о правилах ночных сессий. Любое поведение агента, не описанное здесь, считается неопределённым; агент должен либо остановиться и спросить, либо откатить.

---

## Цель

Ночная сессия — полуавтономный агент, который пока оператор спит, делает **низкорисковые, валидированные, атомарные улучшения** репозитория: тесты, cleanup, мелкие UX, документация. Крупные архитектурные изменения и рискованные правки — **не ночью**.

Главный критерий успеха утра: user'у не страшно merge'ить ветку. Если хоть одно изменение вызывает "это я сейчас должен разбираться?" — процесс нарушен.

---

## Бюджет

- **Время**: указывается при старте (10 часов по умолчанию), агент **не обязан его выбрать**. Если после N циклов не видно идей с приемлемым risk/value — остановка лучше спам-цикла.
- **Минимальный полезный выход**: 1 цикл с реальным value. Ноль — приемлемо, если agent честно пишет "не нашёл безопасных задач".
- **Темп**: 6-12 циклов за 10-часовой budget — нормально. Больше 15 — агент гонит количество, меньше 4 — агент слишком осторожный или застрял.

---

## Startup protocol

Перед любой модификацией агент обязан:

1. **Working tree должен быть clean**. Если есть uncommitted — fail-fast: "working tree dirty, aborting". Ни `git stash`, ни commit WIP — это решение оператора.
2. Создать ветку `night/autonomous-YYYY-MM-DD` от текущего HEAD main'а (или ветки оператора, если сессия запущена вне main).
3. Создать тег `night-baseline-YYYY-MM-DD` на HEAD ветки. Нужен для rollback'а.
4. Скопировать `docs/spec/processes/night-work/report-template.md` → `docs/spec/processes/night-work/sessions/YYYY-MM-DD.md`. Заполнить header: дата, baseline-commit, budget.
5. Сделать commit `chore(night): session YYYY-MM-DD baseline` с одним только пустым отчётом. Это стартовая точка в истории ветки.

**Anti-pattern cycle-1 2026-04-22**: агент случайно захватил в первый коммит uncommitted WIP оператора (931 строк) и оставил навсегда "WIP baseline"-коммит в истории. Startup protocol именно это предотвращает — clean working tree обязателен перед стартом, иначе сессия не начинается.

---

## Цикл — структура

Один цикл = одно обсуждение + 1-3 задачи + их реализация + запись в отчёт.

### 1. 10 идей

Агент набрасывает 10 идей в текущем контексте. Источники:
- `git diff night-baseline..HEAD` — что уже сделано, где пробелы
- `flutter analyze` — текущие warning'и
- `flutter test --coverage` (опционально) — низко покрытые модули
- `docs/spec/tasks/` — pending задачи
- Memory / feedback invariants
- `docs/night-reports/sessions/*.md` — предыдущие "deferred" лист

### 2. Обсуждение — 3 роли

Каждая идея получает реакцию от **ПМ / Архитектора / Маркетолога**:

- **ПМ** — смысл, польза, приоритет, текущий scope (какая ветка релиза). Следит чтобы не размывали текущий релиз.
- **Архитектор** — качество кода, тех-долг, тестируемость, риски регрессии.
- **Маркетолог** — потребности пользователей (обход блокировок, приватность, скорость, простота, доверие). **Anti-rule**: нельзя ссылаться на "жалобы из App Store" / "70% юзеров на форумах" / "топ-3 жалоб" **без конкретной ссылки на тред или источник**. Либо WebFetch реального треда с цитатой, либо честная rationale без чисел.

### 3. Выбор 3

Из 10 идей выбираются **1-3** для реализации в этом цикле. Критерии:
- Безопасность для текущей релизной ветки
- Видимая ценность (user-visible / security / correctness)
- Реалистичность за 1 цикл (~30-60 минут работы)

### 4. Отклонение 7+ — с категорией

Каждая отклонённая идея обязана иметь категорию:
- `too-risky-for-branch` — крупный рефактор, нарушение инварианта, трогает critical path
- `out-of-scope` — не попадает в текущий релиз
- `needs-baseline` — требует профилирования / measurement которого нет
- `low-ROI` — работы много, ценности мало
- `next-cycle` — подхватим дальше (складывается в deferred-лист в конце)

Просто "отклоняем" — **нарушение протокола**.

### 5. Реализация

Для каждой выбранной задачи:

**Quality gates** (обязательны перед коммитом):
- `flutter analyze` → **0 issues** (info/warning/error) на модифицированных файлах + на всём проекте на момент commit'а
- `flutter test` → **все тесты зелёные** (можно ограничить affected модулями, но перед последним циклом — прогон всей сюиты)
- Коммит-сообщение ↔ фактически сделанному (no silent pivot — см. ниже)
- Никаких изменений вне **scope whitelist** (см. ниже)

### 6. Pivot protocol

Если в процессе реализации обнаружилось, что задача уже сделана / некорректно оценена / слишком велика:

1. **НЕ коммитить молча другую задачу с тем же именем**.
2. Открыть `docs/spec/processes/night-work/sessions/YYYY-MM-DD.md`, в разделе текущего цикла добавить строку:
   > `T4-3 reassigned: "dart fix --dry-run" → "unsaved-input guard". Reason: dart fix returned "Nothing to fix". Replacement picked per cycle plan's "next-cycle" queue.`
3. Обновить commit-сообщение чтобы оно описывало **реально сделанное**, с упоминанием reassignment'а если это изменило scope.
4. Коммит после обновления отчёта, не раньше.

**Anti-pattern 2026-04-22 (cycles T4-3/T5-3/T6-3)**: pivot'ы прошли молча, commit описал новую задачу, но cycle plan в отчёте остался ссылаться на старую. Читателю приходится догадываться.

### 7. Запись в отчёт

После каждого цикла в отчёт добавляется секция по template'у (см. `report-template.md`). **До коммита**. Нельзя сделать 3 цикла а потом писать отчёт — порядок нарушится, pivot'ы размажутся.

---

## Scope boundaries

### Whitelist — агент может модифицировать

- `app/lib/screens/**` (UI экраны)
- `app/lib/widgets/**` (виджеты)
- `app/lib/services/**` (кроме `android/` — это native)
- `app/lib/models/**` (но sealed-иерархии / data contracts — only if a task explicitly covers them)
- `app/lib/controllers/**`
- `app/lib/vpn/box_vpn_client.dart` (Dart wrapper, не native)
- `app/test/**`
- `docs/**` (кроме `docs/releases/*` — см. ниже)
- `docs/spec/features/**` (обновления существующих spec'ов по задачам)
- `docs/spec/tasks/**` (создание новых task-файлов)
- `docs/spec/processes/night-work/sessions/**` (отчёты, только свою сессию)
- `scripts/**` (только если задача explicitly касается build/CI)

### Blacklist — не трогать без explicit разрешения

- `app/android/**` (native Kotlin + манифест + Gradle)
- `app/ios/**` / `app/macos/**` / `app/web/**` / `app/windows/**`
- `app/assets/wizard_template.json` (core configuration, меняется только через спеку)
- `app/pubspec.yaml` (deps + version — мутация только при release-подготовке)
- `app/lib/main.dart` (entry point — только с explicit task)
- `CHANGELOG.md`, `RELEASE_NOTES.md`, `docs/releases/*` (релиз-документы, меняются только при release-подготовке)
- `LICENSE`
- `README.md`, `README_RU.md` (обновления поверх — explicit task)
- `.github/workflows/**` (CI)
- `.gitignore` (минимум, и только по necessity для добавляемых файлов)

### Конфликт: задача требует blacklist-файла

1. В момент выбора задачи — отклонить её с категорией `out-of-scope`, зафиксировать в deferred.
2. НЕ трогать. Пусть оператор разберётся днём.

---

## Commit discipline

- **Atomic commits**. Один цикл = один коммит (или 2-3 если задачи независимы). Megacommit'ы запрещены.
- **Conventional prefixes**: `feat`, `fix`, `chore`, `refactor`, `test`, `docs`, `style`, `build`, `ci`.
- **Test-only commits** — prefix строго `test:`. Не `chore,test:` и не `feat,test:`.
- **Сообщение структуры**:
  ```
  <type>(<scope>): <subject ≤72 chars>

  <optional body: 2-5 строк, что и зачем>

  <optional trailer: refs to cycle / task>
  ```
- В последней строке коммита **каждого цикла** — ссылка на цикл в отчёте: `Refs: night-work/sessions/YYYY-MM-DD.md §Cycle N`

---

## Rollback protocol

Каждый коммит в ночной ветке должен быть независимо revert'абельным:

- `git revert <cycle-commit>` — безопасно удалить один цикл
- `git reset --hard night-baseline-YYYY-MM-DD` — откатить всю сессию

Агент в отчёте **обязан** указать эту инструкцию в TLDR — чтобы оператор знал как откатить.

---

## Anti-patterns — агент должен **не** делать

1. **Megacommit / rescue-commit уместно WIP оператора.** Вместо: fail на старте если working tree dirty.
2. **Silent pivot** задачи без обновления cycle plan.
3. **Hallucinated статистика маркетолога** ("70% жалоб"). Без источника — без чисел.
4. **Tests-only commit с prefix'ом `chore`**. Должно быть `test:`.
5. **Касание blacklist-файлов** без explicit разрешения в ночной задаче.
6. **Самоограничение scope до 10% бюджета** без попытки реально набросать ещё циклы. Если после цикла осталось время — стараться идти дальше.
7. **Skip quality gate** — коммит без `flutter analyze` / `flutter test`.
8. **Принятие задачи без категории отклонения** (для не-выбранных).
9. **Изменение CHANGELOG/RELEASE_NOTES/releases без release-задачи**.
10. **Force-push в night branch** — никогда. Если коммит сломан — revert или amend-before-push.

---

## Morning review — контракт для оператора

См. [`morning-review.md`](./morning-review.md).

---

## Эволюция

Этот процесс — живой. После каждой сессии в `sessions/YYYY-MM-DD.md` секция **"Process feedback"** — что работало / ломалось. Если паттерн повторяется в 2+ сессиях — обновление этой спеки.
