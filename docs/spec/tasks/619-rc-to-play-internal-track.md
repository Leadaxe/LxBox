# 619 — Релиз-кандидат уходит в Google Play на трек internal

| Field | Value |
|------|----------|
| Status | In progress |
| Start date | 2026-10-09 |
| Commits | — |
| Related | §436 (заливка в Play из CI, pre-release для rc), §379 (формула versionCode), `docs/RELEASE_PROCESS.md`, `docs/GOOGLE_PLAY.md` |

## Problem

Тег `vX.Y.Z-rc.N` даёт GitHub pre-release с APK, но в Play Console не попадает:
job `google-play` в `.github/workflows/ci.yml` пропускается по условию
`is_prerelease != 'true'`. Проверить кандидата через Play (подпись Play App
Signing, обновление поверх сторовой установки, внутренние тестеры) нельзя,
первый контакт сборки с Play — уже финальный релиз на production.

## Diagnosis

Единственный барьер — условие `if` джоба. Коды версий конфликта не создают:
по `scripts/version-code.sh` разряд PRE у rc.N равен 01–49, у релиза 50,
поэтому `vX.Y.Z-rc.N` < `vX.Y.Z` и > `vX.Y.(Z-1)-hotfixN`. Play требует
уникальности versionCode по всем когда-либо загруженным бандлам и допускает
на internal код ниже production — rc и финал одной версии не пересекаются.
Сервисный аккаунт уже имеет право «Release apps to testing tracks»
(`docs/GOOGLE_PLAY.md`). Трек Internal testing не проходит проверку Google,
сборка со статусом `completed` доступна тестерам через минуты.

Побочный разрыв: шаг «Release notes» ищет changelog по коду кандидата
(`…0Nx`), файлов под такими кодами в `fastlane/metadata/android/*/changelogs/`
нет — выпуск уйдёт без описания с warning.

## Solution

1. `ci.yml`, job `google-play`:
   - условие: `needs.meta.outputs.is_release == 'true'` (без запрета prerelease);
   - трек: для rc — `vars.PLAY_RC_TRACK || 'internal'`, для релиза/hotfix —
     `vars.PLAY_TRACK || 'production'` как сейчас;
   - статус: для rc — `vars.PLAY_RC_RELEASE_STATUS || 'completed'`, для
     релиза — `vars.PLAY_RELEASE_STATUS || 'draft'` как сейчас;
   - выбор через отдельный шаг с `id`, который кладёт `track`/`status` в
     `GITHUB_OUTPUT` (а не тернарные выражения в `with:` — читаемость и
     лог «track=internal status=completed» в выводе);
   - комментарий в шапке джоба и таблица переменных обновлены.
2. Шаг «Release notes»: если файла по коду кандидата нет, фоллбэк на код
   релиза той же версии (`PRE=50`, то есть `version-code.sh X.Y.Z universal`
   без суффикса) — заметки обычно пишутся заранее под финальный код. Если
   нет и его — прежний warning.
3. Документация: `docs/RELEASE_PROCESS.md` (таблица триггеров, абзац про rc
   §436, раздел «Google Play (AAB)»), `docs/GOOGLE_PLAY.md` (таблица
   «Which tags», переменные). Везде: rc уходит в Play на трек internal.

## Risks and edge cases

- Трек internal должен существовать в консоли и иметь список тестеров;
  иначе заливка пройдёт, но сборку никто не увидит. Проверка — владелец.
- Повторный rc с тем же N после правки тега невозможен: versionCode уже
  использован Play. Новый кандидат = новый N (как и было для релизов).
- Заметки из фоллбэка могут не совпадать с содержимым кандидата —
  допустимо, это internal.
- Провал заливки не снимает GitHub pre-release (джобы параллельны, как и
  раньше).

## Verification

- `actionlint`/синтаксис YAML не ломаем; локальных прогонов нет (CI).
- Ревью диффа: условие джоба, значения по умолчанию, фоллбэк changelog.
- Боевая проверка — на следующем `vX.Y.Z-rc.1`: в логе джоба
  `track=internal status=completed`, сборка видна во Internal testing.

## Unresolved / follow-up

- Промоут rc → production внутри Play (вместо отдельной заливки финала) не
  делается: финальный тег собирает свой AAB с кодом `…50x`, как и раньше.
