# §233 — понизить minSdk 26 → 24 (Android 7.0+, best-effort)

## Контекст

Запрос пользователя: поставить приложение на устройство с Android 7.1.1
(API 25). Текущий `minSdk = 26` блокирует установку на всём Android 7.x,
хотя технических причин для границы именно в 26 нет — она выбрана в v1.4.0
как «historical claim» из release notes («Android 8.0+»), см.
[ARCHITECTURE.md → Supported platforms](../../ARCHITECTURE.md) и комментарий
в `app/android/app/build.gradle.kts` (там же заранее допускалось понижение
до 24 при жалобах).

**24 — абсолютный пол**: Flutter 3.41.x поддерживает минимум API 24
(`FlutterExtension.minSdkVersion = 24`), ниже движок не пустит.

## Аудит совместимости (проведён 2026-07-04)

| Компонент | Требование | Статус |
|---|---|---|
| libbox.aar | `minSdkVersion=23`, ABI: arm64-v8a, armeabi-v7a, x86, x86_64 | OK |
| Flutter 3.41.6 engine | API 24+ | OK (ровно пол) |
| androidx.core-ktx 1.12 / lifecycle 2.7 / coroutines 1.7 | minSdk ≤ 19 | OK |
| Flutter-плагины (file_picker, share_plus, …) | minSdk 19–21 | OK, merger проверяет |
| APK Signature Scheme v2 | поддержан с API 24 | OK |

Нативный код уже гейтится по `SDK_INT` везде, где нужно:

- `NotificationChannel` — за `>= O` (`ServiceNotification.createChannel`,
  `BoxService.sendNotification`); оба билдера уже ставят `setPriority(...)`,
  так что на pre-O приоритет уведомлений корректен без каналов.
- Запуск FGS — `ContextCompat.startForegroundService` (на <26 → `startService`;
  ограничений на background-start до API 26 нет).
- `DefaultNetworkListener` — ветка `>= 24` (`registerDefaultNetworkCallback`
  без handler) уже существует.
- `BoxApplication.fixAndroidStack` — включается **ровно** на N..N_MR1 (24–25),
  воркараунд libbox под Android 7.x уже подключён.
- Impeller выключен ниже API 31 (§131) → на 7.x Skia, как на 8–11.
- `TileService` — API 24+; `ShortcutManager`/`StatusBarManager` — за `>= R`/`>= T`.
- Legacy launcher-иконки (`mipmap-*dpi/ic_launcher.png`) есть — adaptive
  (`mipmap-anydpi-v26`) деградирует штатно.
- `java.time` в Kotlin-коде не используется — desugaring не нужен.

`lintVitalRelease` (гоняется автоматически при release-сборке) — контрольная
сетка на пропущенные `NewApi`.

## Что меняется

1. `app/android/app/build.gradle.kts` — `minSdk = 26` → `24`, комментарий
   тиров обновить.
2. `docs/ARCHITECTURE.md` — Supported platforms: minSdk 24, тир best-effort
   расширяется до 7.0–10 (API 24–29), unsupported <7.0; секцию «Почему именно
   26» переписать под 24.
3. `docs/BUILD.md` — упоминание «у нас minSdk 26» → 24.
4. `CHANGELOG.md` — запись в текущий цикл.

Kotlin/Dart-код не меняется.

## Known limitations тира 7.x (документируются, не фиксятся)

- **Android 7.0 (API 24) не содержит корня ISRG Root X1** (Let's Encrypt) —
  HTTPS-подписки с LE-сертификатами не пройдут валидацию системным trust
  store. На 7.1.1 (API 25) корень уже есть. Обходной путь для юзера — источник
  подписки с не-LE сертификатом или file-подписка (§129).
- Свежие корневые CA (пост-2017) в системе отсутствуют — отдельные
  подписочные URL могут падать по цепочке доверия.
- Тир не тестируется регулярно (нет устройства 7.x в парке; эмуляторных
  arm64-образов API 24 нет — на Apple Silicon проверка только на живом
  устройстве). Статус — best-effort, как существующий 26–29.

## Верификация

- `flutter build apk --release` проходит (merger + lintVitalRelease).
- Установка/запуск на реальном Android 7.x — silent-запрос владельцу
  устройства с 4PDA после релиза (best-effort).
