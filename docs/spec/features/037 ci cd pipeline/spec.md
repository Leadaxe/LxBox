# 037 — CI/CD Pipeline

**Status:** Реализовано

## Контекст

Нужна автоматизация сборки и публикации APK через GitHub Actions. При пуше в main — только проверки. При пуше тега — полный цикл до создания релиза.

## Реализация

### Триггеры

| Событие | Действие |
|---------|----------|
| Push в `main` | Checks only (analyze + test) |
| Push тега `v*` | Meta → Checks → Android build → Release (draft) |
| `workflow_dispatch` | Ручной запуск с выбором `run_mode`: `checks`, `build`, `release` |

### Jobs

#### 1. meta

Определяет параметры запуска: какие jobs нужно выполнить, извлекает версию из тега.

#### 2. checks

- `flutter analyze` — статический анализ
- `flutter test` — юнит-тесты

#### 3. android-build

Зависит от `checks`. Собирает release APK:

```yaml
- uses: actions/setup-java@v4
  with:
    java-version: '17'
    distribution: 'temurin'
- uses: subosito/flutter-action@v2
  with:
    flutter-version: '3.x'
- run: flutter build apk --release
```

APK загружается как artifact:
- Для тегов: retention 1 день (APK попадёт в release)
- Для builds: retention 30 дней

#### 4. release

Зависит от `android-build`. Только для тегов `v*`. Создаёт draft GitHub Release:

```yaml
- uses: softprops/action-gh-release@v2
  with:
    draft: true
    files: build/app/outputs/flutter-apk/app-release.apk
    name: BoxVPN ${{ needs.meta.outputs.version }}
```

APK переименовывается в `BoxVPN-vX.Y.Z.apk`:

```yaml
- run: mv build/app/outputs/flutter-apk/app-release.apk BoxVPN-${{ needs.meta.outputs.version }}.apk
```

### workflow_dispatch

Параметр `run_mode`:
- `checks` — только analyze + test
- `build` — checks + android build
- `release` — checks + build + draft release

## Файлы

| Файл | Изменения |
|------|-----------|
| `.github/workflows/ci.yml` | **Новый** — полный CI/CD workflow |

## Критерии приёмки

- [x] Push в main запускает только checks (analyze + test)
- [x] Push тега v* запускает полный pipeline до release
- [x] Draft GitHub Release создаётся с APK
- [x] APK называется BoxVPN-vX.Y.Z.apk
- [x] workflow_dispatch с выбором run_mode
- [x] softprops/action-gh-release используется для релиза
- [x] Retention: 1 день для тегов, 30 дней для builds
