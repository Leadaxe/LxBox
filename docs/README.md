# L×Box — индекс документации

Оглавление всей проектной документации. Точка входа для навигации: начните
отсюда, а не с поиска по файлам.

## Автоматизация и управление

L×Box управляется **тремя** способами помимо самого UI. Выбор зависит от того,
кто и откуда управляет:

| Канал | Для чего | Документ |
|---|---|---|
| **Public Intent API** (§047) | Фоновая автоматизация на устройстве — Tasker / MacroDroid / Locale-plugin. Broadcast-команды и события (Wi-Fi-триггеры, авто-вкл/выкл, switch-node, реакция на падение подписки). Без root, без USB. | [AUTOMATION.md](AUTOMATION.md) |
| **Debug API** (HTTP) | Программное / скриптовое управление и диагностика — полный CRUD подписок и правил, старт/стоп, конфиг, логи, профайлер. Bearer-токен, порт 9269, обычно через adb-forward или Wi-Fi. Для CI, отладки, автоматизации с ПК. | [api/debug-api-reference.md](api/debug-api-reference.md) · живой `GET /help` |
| **Clash API** | Совместимость со сторонними Clash-дашбордами (read-only мониторинг). | [api/clash-api-reference.md](api/clash-api-reference.md) |

Разница коротко: **Public Intent** — «телефон сам себя автоматизирует» по
событиям; **Debug API** — «управляю телефоном снаружи скриптом/руками». Оба
описывают одни и те же операции, но с разных сторон.

## Основная документация

| Документ | Описание |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Tech stack, поддерживаемые Android, дерево исходников, Parser v2 pipeline, потоки данных, native side (Kotlin) |
| [STORAGE.md](STORAGE.md) | Полная схема `lxbox_settings.json` + per-key семантика + история миграций |
| [TEMPLATE.md](TEMPLATE.md) | Схема `wizard_template.json` (пресеты/vars/секции) + синтаксис подстановки vars |
| [PROTOCOLS.md](PROTOCOLS.md) | Детали VPN-протоколов (vless/vmess/trojan/…): URI-форматы, параметры, sing-box mapping |
| [KERNEL.md](KERNEL.md) | sing-box-lx fork: build-теги, ловушки при бампе версии, история rc |
| [SECURITY.md](SECURITY.md) | Threat model — защита от утечек трафика, локальная поверхность атаки, on-device secrets |

## Разработка и эксплуатация

| Документ | Описание |
|---|---|
| [DEVELOPMENT_GUIDE.md](DEVELOPMENT_GUIDE.md) | Философия, принципы, критические gotchas, организация spec'ов |
| [BUILD.md](BUILD.md) | flutter build команды, CI, signing, local-build marker |
| [RELEASE_PROCESS.md](RELEASE_PROCESS.md) | Версии, теги, GitHub Releases, post-flight |
| [DIAGNOSTICS.md](DIAGNOSTICS.md) | Playbook диагностики на устройстве: Debug/Clash API endpoints, анализ TCP/DNS, `scripts/lxbox-diag.sh` |
| [USER_GUIDE_RU.md](USER_GUIDE_RU.md) | Пользовательское руководство (RU) — как это работает |

## Справочники API

| Документ | Описание |
|---|---|
| [api/debug-api-reference.md](api/debug-api-reference.md) | Debug API — полный список endpoint'ов (зеркалит живой `GET /help`) |
| [api/clash-api-reference.md](api/clash-api-reference.md) | Clash API — совместимость со сторонними дашбордами |

## Спецификации

| Тип | Где |
|---|---|
| **Фичи** (крупные концепты, разделы приложения) | [spec/features/](spec/features/) — папки `NNN name/spec.md` |
| **Таски** (мелкие изменения, bug-fix'ы, cleanup'ы) | [spec/tasks/](spec/tasks/) — `NNN-name.md` |
| **Процессы** (ночная работа и т.п.) | [spec/processes/](spec/processes/) |
| **Conventions** оформления spec'ов | [spec/README.md](spec/README.md) |

## Прочее

| Каталог | Содержимое |
|---|---|
| [releases/](releases/) | Per-version release notes (EN + RU) |
| [features/](features/) | Deep-dive заметки по отдельным фичам (per-app-trace, wifi-aware-routing) |
| [research/](research/) | Исследования (аудит кода, аудитория, 4pda-фидбэк) |
| [examples/](examples/) | Примеры конфигов (`minimal_local_test.json`) |
