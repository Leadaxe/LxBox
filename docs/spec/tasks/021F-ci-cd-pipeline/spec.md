# 021 — CI/CD Pipeline

| Поле | Значение |
|------|----------|
| Статус | Реализовано |

## Контекст

Автоматизация сборки и публикации APK через GitHub Actions.

## Триггеры

| Событие | Действие |
|---------|----------|
| Push в `main` | Checks only (analyze + test) |
| Push тега `v*` | Meta → Checks → Android build → Release (draft) |
| `workflow_dispatch` | Ручной запуск с выбором `run_mode`: `checks`, `build`, `release` |

## Jobs

### 1. meta
Определяет параметры запуска: какие jobs нужны, версия из тега.

### 2. checks
- `flutter analyze`
- `flutter test`

### 3. android-build
Зависит от `checks`. Собирает release APK.
- APK retention: 1 день для тегов, 30 дней для builds.

### 4. release
Только для тегов `v*`. Draft GitHub Release с APK (`L×Box-vX.Y.Z.apk`).

## Файлы

| Файл | Изменения |
|------|-----------|
| `.github/workflows/ci.yml` | Полный CI/CD workflow |

## Критерии приёмки

- [x] Push в main → только checks
- [x] Push тега v* → полный pipeline до release
- [x] Draft GitHub Release с APK
- [x] APK называется L×Box-vX.Y.Z.apk
- [x] workflow_dispatch с выбором run_mode
