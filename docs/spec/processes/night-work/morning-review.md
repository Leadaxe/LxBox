# Morning review — контракт оператора

После ночной сессии, прежде чем mergeить ветку в main, пройти этот чеклист. Должен занимать **≤15 минут**. Если занимает больше — сессия содержит что-то большое, нужно разбираться отдельно, возможно revert.

## 1. TLDR session-отчёта

Открыть `docs/spec/processes/night-work/sessions/YYYY-MM-DD.md`, прочитать **только TLDR + Incidents**. Этого должно хватить чтобы понять:
- Что сделано (таблица циклов)
- Что сломано / incidents
- Как откатить
- Что проверить на устройстве

Если TLDR пуст или не структурирован — процесс нарушен (агент не обновил wrap-коммитом). → **revert всю сессию** и разбираться.

## 2. Проверки git

```bash
# Количество коммитов должно соответствовать таблице TLDR
git log --oneline main..night/autonomous-YYYY-MM-DD

# Diff не должен касаться blacklist-файлов
git diff main..night/autonomous-YYYY-MM-DD --stat | grep -E "android/|ios/|macos/|web/|windows/|pubspec.yaml|CHANGELOG|RELEASE_NOTES|docs/releases/|\.github/"
# → если что-то вылезло, проверь что это explicit scope текущей сессии
```

## 3. CI / quality gates

```bash
git checkout night/autonomous-YYYY-MM-DD
flutter analyze    # → 0 issues
flutter test       # → all green
```

Если не green — либо агент не прогнал перед коммитом (нарушение), либо регрессия просочилась. → revert / fix.

## 4. Визуальные сценарии

Session-отчёт в TLDR указывает **"Сценарии для ручной проверки"**. Прогнать их на устройстве (USB / wifi adb). Если сценарий не работает — revert конкретного цикла, а не всей сессии.

## 5. Проверка "silent pivot"

Для каждого цикла убедиться что:
- Commit-сообщение описывает **реально сделанное**
- В session-отчёте есть строка "Tn-m reassigned: X → Y" **если** план разошёлся с фактом

Если pivot прошёл молча — это **spec issue**, но commit'ы валидны. Добавить заметку в `spec.md §Anti-patterns` + записать в issues.

## 6. Marketer-стат проверка

Найти в отчёте любые claims вида "70% юзеров / топ-3 жалоб / форумы сообщают". Каждое такое — должно иметь **ссылку на тред** (WebFetch URL). Если claim без ссылки — confabulation. Либо агент должен был подтвердить ссылкой, либо rationale переписать без чисел.

Если нашёл unsourced claim — **не revert**, но пометь в issues + прими что merchandiseer voice надо ужесточить в spec.

## 7. Merge decision

Варианты:

- **✅ Merge всё** (`git merge --no-ff night/autonomous-YYYY-MM-DD`) — если TLDR чист, scenarios прошли, никаких blacklist-violations, no silent pivot, no unsourced claims.
- **🔀 Cherry-pick** — если часть циклов нравится, часть нет. `git cherry-pick <good-cycle-commits>`.
- **⏪ Revert / reset** — если TLDR сыроват, сценарии не проходят, или blacklist-violations.
  ```bash
  git branch -D night/autonomous-YYYY-MM-DD
  git tag -d night-baseline-YYYY-MM-DD
  ```

## 8. Обновить deferred

Если есть `Deferred` секция в session-отчёте — перелить ценные идеи в `docs/spec/tasks/` как новые task-файлы или в memory (`feedback_deferred_ideas.md`). Иначе забудутся.

## 9. Обновить spec.md если надо

Если в session-отчёте "Process feedback" есть конкретное предложение, и оно касается **повторяющегося** паттерна (2+ сессии подряд) — обновить `spec.md`. Одиночный инцидент — не повод трогать процесс, записать как incident.

## 10. Закрыть session

После merge / revert — session-файл **остаётся** в `sessions/`. Это архив. Не удалять, даже если сессия откачена целиком — следующая сессия может прочитать "что уже пробовали и почему откатили".
