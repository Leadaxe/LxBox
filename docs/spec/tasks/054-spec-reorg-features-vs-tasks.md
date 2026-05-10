# 054 — Spec reorg: features vs tasks classification audit

| Поле | Значение |
|------|----------|
| Статус | **Done** (2026-05-10) — реорг выполнен: 7 demotions feature→task, все cross-refs обновлены, grep чист, `flutter analyze` без новых issues |
| Дата | 2026-05-10 |
| Связанные | [`spec/README.md`](../README.md) — определение features vs tasks |
| Затронутые файлы | `docs/spec/features/**`, `docs/spec/tasks/**`, ссылки в `docs/ARCHITECTURE.md`, `CHANGELOG.md`, `docs/api/*`, `docs/spec/features/*/spec.md` (cross-refs), Dart-комментарии с явными `§NNN` упоминаниями |

## Цель

Привести `docs/spec/` в соответствие с правилами из `spec/README.md`:

- **`features/`** — только **живые продуктовые / архитектурные** концепции. Каждая фича актуальна и функциональна, описывает раздел продукта или architectural layer.
- **`tasks/`** — тактические решения, рефакторинги, fix'ы, audit-проходы. Могут быть retrospective / закрытыми; **могут содержать** features которые потеряли актуальность (например, заменены преемником).

Сейчас в `features/` лежит несколько вещей которые по факту — таски (миграция libbox, MVP scope, начальные стек-решения, deprecated stuff). А в `tasks/` лежат записи которые по сути выросли в фичу (например wifi-routing).

## Правила переклассификации

1. **Фича остаётся фичей** если: описывает раздел продукта/архитектурный слой, реализована и активна сейчас, юзер видит/использует.
2. **Фича → таска** (demote) если: историческое решение (MVP scope, начальный stack), миграция / разовый рефактор, или фича заменена/depreciated.
3. **Таска → фича** (promote) если: задача выросла в новую user-facing capability которая теперь живёт продуктом (а не одноразовая правка).
4. **Удалить** (полностью): только дубликаты / `XXXx`-versioned superseded спеки **после переноса полезного контента** в актуальный аналог.

## Правила перенумерации

- Только вперёд: следующий свободный номер за текущим максимумом в целевой папке.
- Старые номера **не переиспользуются**. Освободившиеся номера остаются "дырами" — это нормально, чтобы archive-ссылки не ломались.
- При перемещении создаётся **новая нумерация в target-folder'е**; старая папка/файл удаляется.

## Метод

1. **Inventory** — собрать заголовок + статус + 1-line описание каждого spec'а (done).
2. **Классификация** — для каждого spec'а решить: stay / demote feature→task / promote task→feature / delete. Презентовать как table.
3. **Approval** — user подтверждает план до того как что-то трогаем.
4. **Execution**:
   - `git mv` каждого перемещаемого файла/папки с новой нумерацией;
   - update внутри spec'а — header, status, cross-refs на самого себя;
   - **обязательный grep** по всему репозиторию: `§NNN`, `spec NNN`, `features/NNN`, `tasks/NNN`, `tasks/NNN-` → точечно поправить;
   - update в `docs/ARCHITECTURE.md` (Feature Specs map / Task Specs map если есть);
   - update в `CHANGELOG.md` если есть упоминания.
5. **Verify**:
   - `grep -rn "§<old-num>\|spec <old-num>\|features/<old-num>\|tasks/<old-num>"` должен возвращать 0 hits для каждого освобождённого номера;
   - `flutter analyze` — комментарии с references компилируются.

## Outcome criteria

- В `features/` остаются только spec-и описывающие **существующие в продукте сейчас** capabilities / layers.
- В `tasks/` лежат: исторические migrations, audit'ы, single-PR fix'ы, demoted features.
- Ни одной dangling `§NNN` / `spec NNN` ссылки в коде или документации.
- README spec'а отражает фактическое состояние.

## Out of scope

- Переписывание содержимого spec'ов. Только moves + header fixes + ref updates.
- Удаление контента который ещё может быть полезен для понимания истории — `tasks/` для того и нужен.
- Удаление файлов из `processes/` (там другая семантика — повторяющиеся регламенты).

## Docs to update

- `docs/spec/README.md` — если уточнится формулировка правил.
- `docs/ARCHITECTURE.md` — если есть Feature Specs map / Tasks map.
- Точечные `§NNN` references в `app/lib/**/*.dart`, `app/android/**/*.kt`, `docs/**/*.md`.

## Acceptance

- [x] Inventory зафиксирован (заголовки + классификация — done в этой спеке).
- [x] Plan-таблица презентована user'у (вместе с full-autonomy grant).
- [x] User approved (или итерировали до approval).
- [x] All moves executed; refs updated; grep clean (0 hits на retired numbers `features/001|002|004x|005x|013|039|041`).
- [x] `flutter analyze` 0 errors (только pre-existing infos в чужих файлах).
- [x] Commit atomic (попало в `977f8fa` вместе с §053 Stage 2 — параллельный агент закоммитил оба чейнджсета вместе).

## Outcome

**Demoted features → tasks (7):**

| Был | Стал | Reason |
|-----|------|--------|
| `features/001 mobile stack` | `tasks/055-mobile-stack-decision/` | Historical architectural decision |
| `features/002 mvp scope` | `tasks/056-mvp-scope-historical/` | Historical milestone |
| `features/004x subscription parser` | `tasks/057-subscription-parser-v1-superseded/` | Superseded by §026 parser v2 |
| `features/005x config generator` | `tasks/058-config-generator-wizard-v1-superseded/` | Superseded by §026 parser v2 |
| `features/013 routing` | `tasks/059-routing-v1-superseded/` | Superseded by §030 custom routing rules |
| `features/039 libbox 1.13 migration` | `tasks/060-libbox-1-13-migration/` | One-shot migration (Done) |
| `features/041 dns rules refactor` | `tasks/061-dns-rules-refactor/` | Refactor; live spec — §014 |

**Promotions task → feature:** none.
**Deletions:** none (всё ценное перенесено в `tasks/`).

**Retired feature numbers:** 001, 002, 004, 005, 013, 039, 041 — больше не используются.

**Files touched:** ~40 (cross-refs в `docs/**/*.md`, `CHANGELOG.md`, `app/lib/**/*.dart`, `app/test/**/*.dart`).
