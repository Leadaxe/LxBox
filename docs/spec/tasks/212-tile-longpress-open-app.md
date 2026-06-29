# §212 — long-press на QS-плитке открывает приложение

> **СТАТУС: РЕАЛИЗАЦИЯ.** Манифест-only (intent-filter) + проверка на устройстве.

## Проблема

QS-плитка ([LxBoxTileService](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/LxBoxTileService.kt))
обрабатывает `onClick` (toggle VPN), но **long-press** ничего не делает —
Android по умолчанию открывает системный экран «о приложении» или ничего, если
не объявлена preferences-activity. Конкуренты по long-press открывают само
приложение — это ожидаемый жест.

## Механизм Android

При long-press на QS-плитке система ищет в **том же пакете** activity с
`<intent-filter>` на действие `android.service.quicksettings.action.QS_TILE_PREFERENCES`
и запускает её. Это штатный hook для «настроек плитки». Мы используем его, чтобы
открыть `MainActivity` (= открыть приложение).

## Решение

Добавить intent-filter на `MainActivity` в
[AndroidManifest.xml](../../../app/android/app/src/main/AndroidManifest.xml):

```xml
<intent-filter>
    <action android:name="android.intent.action.MAIN"/>
    <category android:name="android.intent.category.LAUNCHER"/>
</intent-filter>
<!-- Long-press на QS-плитке открывает приложение -->
<intent-filter>
    <action android:name="android.service.quicksettings.action.QS_TILE_PREFERENCES"/>
</intent-filter>
```

`MainActivity` уже `launchMode="singleTop"` + `exported="true"` → системный
long-press-intent просто поднимет существующий/новый инстанс. Никакого Kotlin-
кода не нужно: action не несёт нашего `EXTRA_ACTION`, MainActivity откроется в
дефолтном состоянии (home), что и требуется.

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| manifest | `AndroidManifest.xml` | +intent-filter `QS_TILE_PREFERENCES` на MainActivity |

## НЕ трогаем

- `onClick` (toggle) в LxBoxTileService — остаётся.
- `connectOrPromptConsent` — отдельный путь (короткий тап на остановленной плитке).

## Тесты

- Device: добавить плитку в шторку → long-press → открывается L×Box.
- Манифест-only, unit-теста нет.

## Связанные

- §032 — Quick Connect tile.
- [Feature 126 first-run wizard](../features/126%20first-run-wizard/spec.md) —
  add-tile промпт (откуда плитка появляется в шторке).
