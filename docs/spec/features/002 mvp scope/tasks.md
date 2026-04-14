# Задачи: 002 — MVP scope + реализация + CI/CD

Спека: [`spec.md`](spec.md)

## Реализация MVP (бэклог, бывшая задача 004)

### Фаза 0 — Репозиторий и каркас

- [x] Каталог **`app/`** — проект **Flutter** (`flutter create`), `applicationId` / namespace, **minSdk** / **targetSdk** / compileSdk.
- [x] Структура: Dart-код под `lib/`; нативный Android VPN под `app/android/`.
- [x] Зависимости: HTTP-клиент для Clash API, хранилище.
- [x] Линтер / форматирование: `analysis_options.yaml`.

### Фаза 1 — Bridge и события (см. `001`)

- [x] **MethodChannel**: команды `startTunnel` / `stopTunnel` / `loadConfig`, события.
- [x] **Kotlin:** `VpnService`, foreground + notification.
- [x] Нормализация ошибок.

> Туннель и libbox вынесены в зависимость **`flutter_singbox_vpn`**.

### Фаза 2 — libbox / sing-box ядро

- [x] Подключить **libbox**; JNI/биндинги по референсу SFA.
- [x] Передача конфига в ядро при старте; корректный stop.
- [ ] Логи ядра: канал в Dart для строк.

> Плагин отдаёт стрим логов (`onLogMessage`); в UI MVP не подключён.

### Фаза 3 — Конфиг: Read и хранение

- [x] Кнопка **Read**: чтение clipboard, `jsonDecode`, сохранение файла конфига.
- [x] Ошибка только при невалидном JSON.

### Фаза 4 — Главный экран UI

- [x] **Start** / **Stop** + статус туннеля.
- [x] Запрос **VPN permission** при первом Start.

### Фаза 5 — Clash API

- [x] Клиент HTTP к `experimental.clash_api`.
- [x] Селектор групп, список узлов, **switch**, **одиночный ping**.

### Фаза 6 — Закрытие MVP

- [x] Прогон критериев — ручная проверка на устройстве.
- [x] Обновить `README`.

## CI/CD (бывшая задача 005)

- [x] Файл **`.github/workflows/ci.yml`**.
- [x] Job **analyze**: `flutter analyze`.
- [x] Job **test**: `flutter test`.
- [ ] Job **build-android**: `flutter build apk`.
- [ ] Артефакты: `actions/upload-artifact` с APK.
- [ ] JDK 17 для Android Gradle Plugin.

## Статус

| Блок | Статус |
|------|--------|
| Каркас + туннель + Read + главный экран + Clash API | сделано |
| Стрим логов ядра на экране | отложено |
| CI analyze + test | сделано |
| CI build-android | частично |
