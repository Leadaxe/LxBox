# 436 — Заливка AAB в Google Play из CI

| Поле | Значение |
|------|----------|
| Статус | In progress — job добавлен. Решение владельца 14.09.2026: полный цикл сразу, `PLAY_RELEASE_STATUS=completed` выставлен до первого прогона (черновик не нужен, ручную отправку на проверку он уже проходил). Done после первого зелёного прогона на теге |
| Дата старта | 2026-09-14 |
| Триггер | Вопрос владельца: релиз на GitHub должен сам уезжать в Play и F-Droid. F-Droid уже автоматический (`AutoUpdateMode: Version` + `UpdateCheckMode: Tags` в рецепте, см. [FDROID.md](../../FDROID.md)); в Play AAB заливался руками из артефакта прогона |
| Связанные | [§379](379-version-code-from-version.md) (versionCode из версии), [§390](390-install-source-aware-update-notice.md) (канал установки, define только у AAB), [§219](219-deep-audit-2026-07.md) (перезапуск release-режима на теге), [GOOGLE_PLAY.md](../../GOOGLE_PLAY.md), [RELEASE_PROCESS.md](../../RELEASE_PROCESS.md) §2 «Google Play (AAB)» |

## Проблема

На тег CI собирает `app-release.aab` (job `android`, шаг «Build AAB (Google
Play)») и кладёт его в артефакт прогона. Дальше — руками: скачать артефакт,
открыть консоль, создать выпуск, вставить описание. Шаг откладывается, Play
отстаёт от GitHub на дни (22301500 уехал через трое суток после тега).

## Решение

Job `google-play` (имя в UI — `GooglePlay`) в [ci.yml](../../../.github/workflows/ci.yml): `needs: [meta, android]`,
гейт `is_release && !is_prerelease`, параллельно с `release`. Шаги:

| Шаг | Что делает |
|---|---|
| Checkout (sparse) | только `scripts/version-code.sh` и `fastlane/metadata/android` |
| Service account present? | нет секрета `PLAY_SERVICE_ACCOUNT_JSON` → `::warning`, остальные шаги пропущены. Форки и прогоны без ключа не ломаем |
| Download AAB | артефакт `android-aab-release` того же прогона |
| Release notes | `fastlane/metadata/android/<locale>/changelogs/<code>.txt` → `play/whatsnew/whatsnew-<play-locale>` |
| Upload to Google Play | `r0adkll/upload-google-play` (пин по SHA коммита `v1.1.5`): `packageName`, `releaseFiles`, `track`, `status`, `whatsNewDirectory` |

Откуда что берётся:

| Что | Откуда |
|---|---|
| Учётка | сервисный аккаунт в Google Cloud-проекте владельца («LxBox CI»), включён Google Play Android Developer API. В Play Console приглашён на L×Box с двумя правами: «Выпуск рабочей версии, исключение устройств и Play App Signing» + «Выпуск версий для тестирования». Ни админа, ни витрины, ни отзывов |
| Ключ | секрет репозитория `PLAY_SERVICE_ACCOUNT_JSON` — JSON-ключ целиком. Локальная копия `.keys/google-play-publisher.json`; каталог `.keys/` в `.gitignore` |
| Трек | `vars.PLAY_TRACK`, по умолчанию `production` |
| Статус выпуска | `vars.PLAY_RELEASE_STATUS`, по умолчанию `draft` |
| versionCode | `scripts/version-code.sh <ver> universal` — тот же, что зашит в AAB (ABI=0) |
| Описание выпуска | fastlane-каталог `en-US` → Play-локаль `en-US`, `ru` (соглашение F-Droid) → `ru-RU` |

**Релиз-кандидаты в Play не идут** (решение владельца 14.09.2026). Job `meta`
отдаёт `is_prerelease=true` для тега `vX.Y.Z-rc.N`; job `google-play` на таком
теге пропускается (skipped), GitHub-релиз и AAB-артефакт собираются как обычно.
Hotfix `vX.Y.Z-hotfixN` — полноценный релиз и уходит в Play. Других суффиксов
нет: `version-code.sh` падает на неизвестном. Проверка на подстроку `-rc.`,
поэтому dev-сборка после rc-тега (`X.Y.Z-rc.N-dev.M`) тоже помечена, но у неё
и так `is_release=false`.

**Почему `draft` по умолчанию.** Первый прогон надо увидеть глазами в консоли:
что легло на трек, с каким кодом, с какими notes. Плюс две внешние задержки,
на которые job не влияет: права свежеприглашённого сервисного аккаунта
доезжают до API до суток («The caller does not have permission»), а VPN-категория
идёт на ручную проверку. Черновик кладётся рядом с чем угодно и ничего не
запускает. Переключение без коммита:

```
gh variable set PLAY_RELEASE_STATUS -b completed
```

**Коды changelog.** AAB несёт universal-код (`…0`), а файлы в
`changelogs/` лежат под per-ABI кодами (`…1`, `…2`, содержимое одинаковое) —
так их читает F-Droid, по коду каждого своего APK. Job перебирает `…0`, `…2`,
`…1`, `…4` и берёт первый найденный; нет ни одного — warning и выпуск без
описания для этой локали (не ошибка: описание дописывается в консоли).

**Лимит 500 символов** проверяется в job `checks` на каждом push
(шаг «Fastlane changelogs ≤ 500 chars», все файлы каталога), а не в `google-play`:
тег неподвижен, чинить файл после него некуда. Сейчас максимум — 473.

**Почему action, а не `fastlane supply`.** supply тянет Ruby + gem (~2 мин на
прогон), ждёт Play-локали в именах каталогов (`ru-RU`, у нас `ru` ради
F-Droid) и по умолчанию перезаливает всю витрину — описания, скриншоты.
Action делает ровно одно: AAB + notes на трек. Пин по SHA, а не по `@v1`:
шаг получает ключ сервисного аккаунта, мажорный тег подвижен.

## Что НЕ делается

| Не делается | Почему |
|---|---|
| `mappingFile` / `debugSymbols` | minify выключен, `mapping.txt` не существует; символы `libbox` — отдельная история, в консоли это warning, не блокер |
| Метаданные витрины (описания, скриншоты, рейтинг) | остаются ручными: fastlane-каталог общий с F-Droid, а правила и локали у Play свои |
| `release` / `publish-manifest` зависят от `google-play` | каналы независимы: провал заливки в Play не должен снимать GitHub-релиз и `latest.json` |
| Ретраи, ожидание пропагации прав | перезапуск руками: `workflow_dispatch` → `run_mode=release` на теге (§219) |
| `changesNotSentForReview` | включать вслепую нельзя: тогда выпуск виснет в консоли до ручного «Send for review». Если API так ответил — в консоли незакрытая декларация, закрыть её |

## Риски и edge cases

- **Кандидат на GitHub** (решение владельца 14.09.2026, закрыто): job `release`
  ставит `prerelease: true` для rc, job `publish-manifest` на rc пропускается.
  UpdateChecker ходит в `/releases/latest`, который pre-release не отдаёт, а
  фоллбэк `latest.json` остаётся на прошлом stable — кандидат пользователям
  не предлагается. APK лежат на странице pre-release для тестеров.
- **F-Droid** мог взять rc-тег как новую версию. Решение владельца 14.09.2026:
  шаблон тега в `UpdateCheckMode: Tags ^v\d+\.\d+\.\d+(-hotfix\d+)?$`,
  [fdroiddata!48904](https://gitlab.com/fdroid/fdroiddata/-/merge_requests/48904).
  `UpdateCheckIgnore` не подошёл: `checkupdates` применяет его только в
  режиме `HTTP` и при разборе манифеста, в `Tags` с `UpdateCheckData` — нет.
  Подробности в [FDROID.md](../../FDROID.md).
- **Код уже занят в Play** (заливали руками) → API «Version code N has already
  been used», job красный, GitHub-релиз цел. Ничего не делать.
- **401/403 в первые сутки** после приглашения — пропагация прав, не ошибка
  настройки. Перезапустить job позже.
- **Параллельно висит выпуск на проверке** (сейчас 22301500) — черновик ляжет
  рядом; `completed` заменит его в очереди. Штатно.
- **Переезд аккаунта в organization** (D-U-N-S) прав сервисного аккаунта не
  трогает: они висят на приложении, а не на владельце.
- **Секрет не задан** → warning, job зелёный. Не ошибка: AAB остаётся в
  артефакте.

## Верификация

- [x] YAML валиден (`python3 -c yaml.safe_load`), job виден в графе.
- [ ] Первый тег после мержа: job `google-play` зелёный; в консоли на `production`
  черновик с versionCode = universal-код тега и notes en-US / ru-RU.
- [x] `PLAY_RELEASE_STATUS=completed` — выставлен 14.09.2026 по слову владельца, без
  этапа черновика. Fallback в YAML остаётся `draft`: если переменную удалить,
  job вернётся к черновику, а не к автопубликации.
- [ ] Выпуск ушёл на проверку Google сам (в консоли статус «На проверке»),
  после одобрения опубликовался без ручного Publish → статус спеки Done.

## Нерешённое / follow-up

- Native debug symbols для `libbox` в Play — если понадобятся крэш-репорты
  ядра из консоли. Отдельная задача.
- VpnService-декларация после перевода аккаунта в organization — см.
  [GOOGLE_PLAY.md](../../GOOGLE_PLAY.md).

## Docs to update

- `CHANGELOG.md` → Unreleased.
- `docs/GOOGLE_PLAY.md` → Per release, новый раздел «CI upload».
- `docs/RELEASE_PROCESS.md` → §2 «Google Play (AAB)», чеклист, troubleshooting.
