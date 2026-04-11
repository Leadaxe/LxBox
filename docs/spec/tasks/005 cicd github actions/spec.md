# Задачи: 005 — CI/CD (GitHub Actions)

Цель: **каждый push / PR** в основной ветке проходят проверки на **GitHub-hosted runners**; на `main` — **сборка Android** (APK или AAB) и **артефакт** для скачивания из вкладки Actions.

## Требования

- [ ] Файл **`.github/workflows/ci.yml`** (или разделение `ci.yml` + `release.yml` по желанию).
- [ ] Триггеры: **`push`** и **`pull_request`** на ветку **`main`** (при необходимости — `develop`).
- [ ] Job **analyze**: установка Flutter (channel **stable**, версия **зафиксирована** в workflow или через `FLUTTER_VERSION` env), `flutter pub get`, `dart analyze` / `flutter analyze`.
- [ ] Job **test**: `flutter test` (падает при ошибках тестов; тесты добавляются по мере появления кода).
- [ ] Job **build-android**: `cd app && flutter build apk --debug` или **`release`** с `--split-per-abi` по политике репозитория; кэш pub и Gradle.
- [ ] **Артефакты:** `actions/upload-artifact` с APK (путь `app/build/app/outputs/flutter-apk/*.apk` или аналогично).
- [ ] **JDK 17** для Android Gradle Plugin (указать в `setup-java`).

## Не в первой итерации (по необходимости)

- Подпись release keystore (secrets `KEYSTORE_*`) — для внутренних сборок достаточно unsigned/debug или debug APK из CI.
- **iOS** build (macOS runner) — вне MVP Android.
- **gh** CLI внутри workflow для релизов — опционально; достаточно артефактов Actions.

## Проверка

- [ ] После merge workflow зелёный; артефакт скачивается с последнего run.
- [ ] В [`README`](../../../README.md) корня — абзац «CI» со ссылкой на вкладку Actions.

## Статус

| Пункт | Статус |
|-------|--------|
| Workflow в репозитории | см. `.github/workflows/` |
