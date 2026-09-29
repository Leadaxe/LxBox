[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Сборка, CI и релиз — версии, GitHub Releases, F-Droid и Google Play

LxBox собирается одним workflow GitHub Actions и выпускает каждую версию в GitHub Releases, F-Droid и
Google Play с тремя несовместимыми подписями. Здесь описаны инструментарий сборки, проверки до слияния,
вывод версии и кода сборки из git-тега и ритуал релиза. Это отдельная фича, потому что ошибки здесь не видны
тестами: версия «дрожит» в ветке, код сборки обгоняет релиз, магазин получает кандидата — и узнаёт об этом
пользователь, у которого не встаёт обновление.

| Поле | Значение |
|------|----------|
| Фича | 023-BUILD_CI_RELEASE |
| Тип | Процессная фича (инфраструктура поставки) |
| Поглотила | `§021F` |
| Слой | `.github/workflows/ci.yml` (единственный workflow), `scripts/version-code.sh`, `scripts/fetch-libbox.sh`, `scripts/build-local-apk.sh` |
| Регламент | [RELEASE_PROCESS.md](../../../RELEASE_PROCESS.md) — канонический протокол; здесь правила, не копия |
| Состояние | ✅ написана по коду, 2026-09-29 · релизы выходят (последний — `v2.25.8`) |

## Какие принципы защищает

1. **Тег — единственный источник версии.** Версия и код сборки вычисляются из
   git-тега при сборке; руками код не поднимается никогда.
2. **Одна формула кода сборки** — только в `scripts/version-code.sh`; CI,
   локальная сборка и рецепт F-Droid её вызывают, а не повторяют. Разошедшиеся
   коды ломают установку поверх в обе стороны.
3. **Зелёный CI — единственный тестовый гейт.** Полный набор тестов локально не
   гоняется; вердикт берётся по `head_sha` через API, а не по «последнему прогону».
4. **Кандидат до пользователей не доходит.** `-rc.N` — только pre-release на
   GitHub для тестеров: не Latest, не в `docs/latest.json`, не в Play, не в F-Droid.
5. **Сборка воспроизводима побайтно**, иначе F-Droid не опубликует релиз под
   нашей подписью.

## Реестр: CI

Один workflow `CI`; параллельные прогоны одной ветки отменяют друг друга.

| Событие | Что запускается |
|---------|-----------------|
| push тега `vX.Y.Z` / `vX.Y.Z-hotfixN` | `meta` → `checks` → `android` → `release` + `google-play` + `publish-manifest` |
| push тега `vX.Y.Z-rc.N` | то же, но `release` — pre-release; `google-play` и `publish-manifest` пропускаются |
| push в `develop` / `main`, PR в них | `checks` + `PublicSubsCorpus` |
| `workflow_dispatch`, `run_mode=checks` | `checks` (с `test_path` / `test_name` — точечный прогон без analyze) |
| `workflow_dispatch`, `run_mode=build` | + `android`: APK в артефактах, версия `X.Y.Z-dev.N` от последнего тега |
| `workflow_dispatch`, `run_mode=release` | полный релиз; падает, если HEAD не ровно на теге (аварийный перевыпуск) |

| Job | Что делает | Правило |
|-----|------------|---------|
| `meta` | версия из тега; флаг pre-release по суффиксу `-rc.N` | других суффиксов, кроме `rc.N`/`hotfixN`, нет — формула падает на неизвестном |
| `checks` | `flutter analyze` всего проекта; страж «pubspec в develop — placeholder»; L10n-чекеры (шаблон, UI, захардкоженные литералы, Kotlin); паритет RU/EN доков; changelog fastlane ≤ 500 символов; сверка lock контракта; `flutter test` | красный `checks` — отдельный коммит-исправление сразу |
| `PublicSubsCorpus` | разбор корпуса публичных подписок (без ядра и сети), отчёт артефактом | `continue-on-error`: эталон правит человек |
| `android` | fetch ядра по пину; версия и базовый код в pubspec; подпись из секретов; **четыре APK** отдельными прогонами (universal, `armeabi-v7a`, `arm64-v8a`, `x86_64`) с сужением нативных библиотек ядра; AAB | `--split-per-abi` не используется; `LXBOX_DISTRIBUTION=play` — **только** у AAB |
| `release` | GitHub Release: `LxBox-vX.Y.Z-{arm64-v8a,armeabi-v7a,x86_64,universal}.apk`, тело — `RELEASE_NOTES.md` | не зависит от `google-play` |
| `google-play` | AAB в Play Console; «что нового» — из changelog'ов fastlane (`en-US`, `ru` → `ru-RU`) | без секрета `PLAY_SERVICE_ACCOUNT_JSON` — предупреждение и пропуск; трек `PLAY_TRACK` (по умолчанию `production`), статус `PLAY_RELEASE_STATUS` (по умолчанию `draft` — Publish жмёт человек) |
| `publish-manifest` | переписывает `docs/latest.json` в `main` бот-коммитом `[skip ci]` | единственный автоматический коммит в `main` |

## Реестр: версия и код сборки

```
versionCode = ((major × 10000 + minor × 100 + patch) × 100 + PRE) × 10 + ABI
PRE: 01–49 = -rc.N · 50 = релиз · 51–98 = -hotfixN      ABI: 0 universal · 1 armeabi-v7a · 2 arm64-v8a · 4 x86_64
```

- Номер по умолчанию — **следующий патч**; minor/major — только решением владельца.
- В `develop` `version:` в pubspec — placeholder (`-dev.N`, исторически
  `0.0.0`); реальная версия коммитится **один раз**, в merge-коммит в `main`,
  и тег ставится на него: F-Droid читает версию из исходников коммита тега.
- Dev-сборка (локальная и `run_mode=build`) получает версию
  `X.Y.Z-dev.N` и **код своего последнего тега** — релиз и dev-сборка ставятся
  друг поверх друга. Без тегов — фоллбэк `0.0.0`.
- AAB несёт код universal (ABI=0); per-ABI коды Play строит сам.
- В рантайме версия читается из манифеста APK; проверка обновлений молчит на `-dev`.

## Реестр: каналы поставки

| Канал | Как попадает | Подпись | Кто обновляет |
|-------|--------------|---------|---------------|
| GitHub Releases | job `release` по тегу | наш ключ (секреты `ANDROID_*`; без них — временный ключ раннера, поверх не встаёт) | пользователь по уведомлению приложения |
| F-Droid | каталог сам видит тег (`UpdateCheckMode: Tags ^v\d+\.\d+\.\d+(-hotfix\d+)?$`), собирает из исходников на коммите тега, включая ядро форка и `libcronet`, сравнивает побайтно с APK из GitHub | **наша** (воспроизводимая сборка, `Binaries` + `AllowedAPKSigningKeys` — необратимо) | клиент F-Droid |
| Google Play | job `google-play`, AAB подписан upload-ключом | ключ Google (Play App Signing) | Play |

- APK одного канала **не встаёт** поверх другого; приложение знает свой канал
  и ведёт уведомление об обновлении в свой магазин (§390).
- Код сборки в рецепте F-Droid: `UpdateCheckData` читает код ABI=0 из pubspec,
  `VercodeOperation` добавляет `+1`, `+2`, `+4` по блокам. Версии тулчейна рецепт
  читает из исходников (`flutter.version`, `go.version` ядра, `libbox.version`).
- Fastlane (описания, скриншоты, changelog'и) читается **с коммита тега**:
  changelog, добавленный после тега, в каталог не попадёт.
- Воспроизводимость держится на фиксированном пути сборки, отключённом
  build-id у нативных библиотек и выключенных метаданных зависимостей в APK.
- `docs/latest.json` — фоллбэк проверки обновлений, когда API GitHub исчерпал
  лимит: `tag`, `name`, `published_at`, `html_url`, `apk_url` (universal),
  `apk_urls` по ABI, `min_supported` — см. [020-APP_SHELL](../020-APP_SHELL/FEATURE.ru.md).

## Реестр: платформа и тулчейн

| Параметр | Значение |
|----------|----------|
| minSdk | **24** (Android 7.0) — пол Flutter; понижен с 26 в §233 |
| targetSdk / compileSdk / NDK | из Flutter-плагина (`flutter.*`) |
| JVM | Java 17 (задана в `ci.yml`) |
| Flutter | `3.47.1` — `app/android/flutter.version`, CI читает файл |
| Ядро | пин `app/android/libbox.version` — см. [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.ru.md) |

| Уровень поддержки | Android | Статус |
|-------------------|---------|--------|
| Primary | 11+ (API 30+) | тестируется, всё работает |
| Best-effort | 7.0–10 (API 24–29) | собирается, ставится, базовый VPN должен работать; на ≤ 11 рендер переведён на Skia (§131) |
| Unsupported | < 7 | установка заблокирована |

Android TV — best-effort (§372): манифест совместим, отдельного интерфейса нет.

## Правила релизного ритуала

- **Pre-flight:** ядро — форк, не сток (AAR из пина, шаг fetch в CI); зелёный
  `checks` на голове `develop` по `head_sha`; `develop` — потомок прошлого
  стабильного тега; доки синхронны (CHANGELOG, README, статусы задач).
- **Заметки** — всегда двуязычные, обе версии полные, каждая в своём спойлере;
  копия в `docs/releases/vX.Y.Z.md`; changelog'и fastlane на код
  `armeabi-v7a` и `arm64-v8a`, ≤ 500 символов — **в релизный коммит**.
- **CHANGELOG** — формат Keep a Changelog, `[Unreleased]` сверху, записи со
  ссылками на задачи.
- **Слияние в `main` — в два шага** (`--no-commit`, затем `commit -m`); тег —
  отдельной командой. `--no-ff -m` падает на «empty commit message», и тег
  уезжает на старый коммит.
- **Post-flight:** сразу вернуть `main` в `develop`, **откатив pubspec** до
  коммита; иначе страж `checks` краснеет.
- **Проверка:** релиз Latest (у rc — pre-release); `docs/latest.json` на новом
  теге; ссылки приложения на документы в `main` отвечают 200; версия ядра в
  APK с суффиксом `-lx` и равна пину на теге; на прошлой версии всплывает
  уведомление (только при запуске).
- Force-push, `main`, теги и `gh pr create` — только по явной команде оператора.

## Задачи-ревизии

| # | Ревизия | Статус | Суть |
|---|---------|--------|------|
| 1 | [021F](../../tasks/021F-ci-cd-pipeline/spec.md) | Реализовано | исходный CI/CD: checks, сборка, релиз по тегу |
| 2 | [065](../../tasks/065-version-from-tag.md) | Done (v1.8.2) | версия из тега, без ручных бампов |
| 3 | [066](../../tasks/066-pubspec-sync-hook.md) | Released v1.9.0 | pre-commit хук синка pubspec — **снят в v2.11.x** |
| 4 | [125](../../tasks/125-local-versioncode-split-per-abi.md) | Реализовано | локальный код против релизного split-per-abi — заменено §379 |
| 5 | [186](../../tasks/186-local-build-vc-pin-to-tag.md) | ✅ | dev-сборка не обгоняет релиз по коду |
| 6 | [233](../../tasks/233-minsdk-24.md) | — | minSdk 26 → 24 |
| 7 | [379](../../tasks/379-version-code-from-version.md) | Реализовано (v2.20.0) | код из версии, отказ от `--split-per-abi`, реальная версия на merge в `main` |
| 8 | [390](../../tasks/390-install-source-aware-update-notice.md) | Done | канал установки, define только у AAB |
| 9 | [436](../../tasks/436-google-play-upload-ci.md) | In progress | заливка AAB в Play из CI, rc не публикуется |
| 10 | [486](../../tasks/486-ci-registry-tests.md) | Released v2.25.0 | реестровые тесты не скипаются на CI |

## Следить за

- **Устаревшие описания CI:** 021F (черновой релиз, один APK
  `L×Box-vX.Y.Z.apk`, push только в `main`); таблица CI в BUILD.md без
  `google-play`, `PublicSubsCorpus` и правил rc; «Versions» в BUILD.md называет
  ядро `v1.14.0-lx.28-rc.1` при пине `v1.14.2-lx.8`.
- **Противоречие о подписи F-Droid:** RELEASE_PROCESS.md — «F-Droid's key»,
  FDROID.md — публикация нашего APK под нашей подписью.
- **Противоречие о канале Play:** GOOGLE_PLAY.md — «без build-time define»,
  фактически AAB собирается с `LXBOX_DISTRIBUTION=play`, и приложение его читает.
- **Чек-лист RELEASE_PROCESS.md** требует «`gh run watch` is green», тогда как
  тот же документ и DEVELOPMENT_GUIDE запрещают верить `gh run watch`.
- **Play отстаёт от GitHub** при статусе `draft` (заметки v2.25.8: в Play
  последней была v2.25.5); §436 ещё In progress — актуальное значение
  `PLAY_RELEASE_STATUS` сверять в настройках репозитория.
- `(?m)^version:` в регулярках F-Droid ещё не заякорен (закомментированная
  строка в pubspec может совпасть первой); статус MR с `'%c + 4'` в FDROID.md
  мог устареть.
- Сверка lock контракта на CI сравнивает только то, что есть: копии контракта
  там нет — см. [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.ru.md).

## Связанные фичи

- [020-APP_SHELL](../020-APP_SHELL/FEATURE.ru.md) — проверка обновлений читает
  Releases и `docs/latest.json`, ссылка ведёт в магазин своего канала, `-dev`
  молчит.
- [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.ru.md) — пин ядра, fetch AAR, сверка контракта в `checks`.
- [022-ARCHITECTURE](../022-ARCHITECTURE/FEATURE.ru.md) — правила, которые CI
  проверяет автоматически (analyze, английский UI, тесты только на CI).
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.ru.md) — версия приложения и
  ядра в дампе как проверка релизного APK.
- [027-DEBUG_API](../027-DEBUG_API/FEATURE.ru.md) — версия приложения и ядра в
  `/device` как проверка релизного APK.

## Особенности сопровождения

- Свежий worktree не содержит AAR ядра, подписи и копии контракта:
  `./tool/worktree_bootstrap.sh` до сборки APK и корпусных тестов; без ключа
  APK получит debug-подпись и не встанет поверх продакшена.
- Отладочный и релизный APK подписаны по-разному: `install -r` между ними
  падает, `uninstall` стирает настройки.
- Перевыпуск тега: если CI упал до создания релиза — удалить тег, починить и
  повторить с тем же номером (безопасно); если релиз опубликован — крайняя
  мера: удалить релиз и тег, `docs/latest.json` может потребовать ручного
  отката; скачанный плохой APK лечится только следующим патчем
  (RELEASE_PROCESS §3).
