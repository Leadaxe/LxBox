# Задачи: 004 — Реализация MVP (бэклог)

Спеки: [`002 mvp scope`](../../features/002%20mvp%20scope/spec.md), [`003 servers tab`](../../features/003%20servers%20tab/spec.md), [`001 mobile stack`](../../features/001%20mobile%20stack/spec.md)

Порядок ниже — **логический**; параллельно можно вести ветки, но **CI** (см. [`005 cicd github actions`](../005%20cicd%20github%20actions/spec.md)) должен быть зелёным на `main` после появления приложения.

## Фаза 0 — Репозиторий и каркас

- [ ] Каталог **`app/`** — проект **Flutter** (`flutter create`), `applicationId` / namespace (например `com.leadaxe.boxvpn`), **minSdk** / **targetSdk** / compileSdk зафиксировать в спеке или `README`.
- [ ] Структура: Dart-код под `lib/`; нативный Android VPN под `app/android/`.
- [ ] Зависимости: HTTP-клиент для Clash API, хранилище (например `shared_preferences` или файл в `getApplicationDocumentsDirectory()` для единственного конфига).
- [ ] Линтер / форматирование: `analysis_options.yaml`, правила команды.

## Фаза 1 — Bridge и события (см. `001`)

- [ ] **MethodChannel** (или Pigeon позже): команды `startTunnel` / `stopTunnel` / `loadConfig`, события из §6 спеки `001`.
- [ ] **Kotlin:** `VpnService`, foreground + notification по требованиям Android; заглушка вызова libbox (или интеграция в фазе 2).
- [ ] Нормализация ошибок в единую модель для Flutter (не сырой stack).

## Фаза 2 — libbox / sing-box ядро

- [ ] Подключить **libbox** (версия sing-box зафиксирована в Gradle/доке); JNI/биндинги по референсу SFA.
- [ ] Передача конфига в ядро при старте; корректный stop.
- [ ] Логи ядра: канал в Dart для строк (диагностика на главном экране — краткие сообщения по `002`).

## Фаза 3 — Конфиг: Read и хранение

- [ ] Кнопка **Read**: чтение clipboard, `jsonDecode`, сохранение файла конфига, замена предыдущего.
- [ ] Ошибка только при невалидном JSON (по допущениям `002`).

## Фаза 4 — Главный экран UI (`002`)

- [ ] **Start** / **Stop** + статус туннеля.
- [ ] Запрос **VPN permission** при первом Start (см. `002` §5).

## Фаза 5 — Clash API (`003`)

- [ ] Клиент HTTP к `experimental.clash_api` (base URL + secret из распарсенного конфига).
- [ ] Селектор групп, список узлов, **switch**, **одиночный ping**; порядок как в API; без сортировок/фильтров/mass ping.

## Фаза 6 — Закрытие MVP

- [ ] Прогон критериев [`002` §7](../../features/002%20mvp%20scope/spec.md) и [`003` §9](../../features/003%20servers%20tab/spec.md).
- [ ] Обновить `README` корня: как собрать локально, как смотреть артефакты CI.

## Статус

| Блок | Статус |
|------|--------|
| Весь бэклог | не начато |
