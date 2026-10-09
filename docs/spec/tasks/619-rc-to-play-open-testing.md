# 619 — Релиз-кандидат уходит в Google Play в открытое тестирование (трек beta)

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
(`docs/GOOGLE_PLAY.md`). Решение владельца 2026-10-09: кандидат идёт в
**Открытое тестирование** (Play API: трек `beta`), не во Internal. Открытое
тестирование, в отличие от internal, проходит проверку Google как и
production; со статусом `completed` выпуск уходит на проверку сам, после
одобрения публикуется участникам открытого теста. На internal код ниже
production допустим; для open testing Play тоже допускает код ниже
production (предупреждает, но принимает).

Побочный разрыв: шаг «Release notes» ищет changelog по коду кандидата
(`…0Nx`), файлов под такими кодами в `fastlane/metadata/android/*/changelogs/`
нет — выпуск уйдёт без описания с warning.

## Solution

1. `ci.yml`, job `google-play`:
   - условие: `needs.meta.outputs.is_release == 'true'` (без запрета prerelease);
   - трек: для rc — `vars.PLAY_RC_TRACK || 'beta'` (открытое тестирование),
     для релиза/hotfix —
     `vars.PLAY_TRACK || 'production'` как сейчас;
   - статус: для rc — `vars.PLAY_RC_RELEASE_STATUS || 'completed'`, для
     релиза — `vars.PLAY_RELEASE_STATUS || 'draft'` как сейчас;
   - выбор через отдельный шаг с `id`, который кладёт `track`/`status` в
     `GITHUB_OUTPUT` (а не тернарные выражения в `with:` — читаемость и
     лог «track=beta status=completed» в выводе);
   - комментарий в шапке джоба и таблица переменных обновлены.
2. Шаг «Release notes»: если файла по коду кандидата нет, фоллбэк на код
   релиза той же версии (`PRE=50`, то есть `version-code.sh X.Y.Z universal`
   без суффикса) — заметки обычно пишутся заранее под финальный код. Если
   нет и его — прежний warning.
3. Документация: `docs/RELEASE_PROCESS.md` (таблица триггеров, абзац про rc
   §436, раздел «Google Play (AAB)»), `docs/GOOGLE_PLAY.md` (таблица
   «Which tags», переменные). Везде: rc уходит в Play в открытое
   тестирование (трек `beta`), проходит проверку Google.

### Реализация (где лежит)

- `.github/workflows/ci.yml`, job `google-play` (`name: GooglePlay`, ~стр. 537):
  `if: needs.meta.outputs.is_release == 'true'` (~стр. 543); шапка джоба —
  таблица `PLAY_TRACK` / `PLAY_RELEASE_STATUS` / `PLAY_RC_TRACK` /
  `PLAY_RC_RELEASE_STATUS`.
- Шаг «Play track and status» (`id: target`, ~стр. 585, после `gate`):
  `vars.*` через `env:`, выбор по `IS_PRERELEASE`, в `GITHUB_OUTPUT` —
  `track`/`status`, в лог — `track=… status=…`.
- Шаг «Release notes» (~стр. 614): `RBASE` = `version-code.sh "${VERSION%%-rc.*}"
  universal` только для `-rc.`; второй проход суффиксов 0 2 1 4 по `RBASE`,
  в логе — какой файл взят; warning перечисляет оба диапазона.
- Шаг «Upload to Google Play»: `track:`/`status:` из `steps.target.outputs.*`
  (~стр. 677–678).
- Комментарий §436 в job `meta` (~стр. 114) переформулирован; логика
  `is_prerelease`, GitHub pre-release и пропуск `publish-manifest` не менялись.
- Доки: `docs/RELEASE_PROCESS.md` (таблица триггеров, абзац про rc, раздел
  «Google Play (AAB)»), `docs/GOOGLE_PLAY.md` (CI upload: Track, Which tags,
  Release candidate status, Release notes),
  `docs/spec/features/023-BUILD_CI_RELEASE/FEATURE{,.ru}.md` (принцип 4,
  таблица триггеров, строка `google-play`).
- `actionlint .github/workflows/ci.yml` — чисто.

## Risks and edge cases

- Открытое тестирование должно быть создано в консоли (страница Open
  testing, страны); иначе API вернёт ошибку трека. Проверка — владелец.
- Открытый тест виден любому пользователю Play по ссылке/в карточке
  «Join the beta»: кандидат фактически публичен, хоть и помечен как beta.
- Проверка Google занимает часы-дни; «completed» для rc не означает
  мгновенной доступности.
- Повторный rc с тем же N после правки тега невозможен: versionCode уже
  использован Play. Новый кандидат = новый N (как и было для релизов).
- Заметки из фоллбэка могут не совпадать с содержимым кандидата —
  допустимо для теста, финальный релиз несёт свои.
- Провал заливки не снимает GitHub pre-release (джобы параллельны, как и
  раньше).

## Verification

- `actionlint`/синтаксис YAML не ломаем; локальных прогонов нет (CI).
- Ревью диффа: условие джоба, значения по умолчанию, фоллбэк changelog.
- Боевая проверка — на следующем `vX.Y.Z-rc.1`: в логе джоба
  `track=beta status=completed`, выпуск появляется в Open testing на
  проверке.

## Unresolved / follow-up

- Промоут rc → production внутри Play (вместо отдельной заливки финала) не
  делается: финальный тег собирает свой AAB с кодом `…50x`, как и раньше.
