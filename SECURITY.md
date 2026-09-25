# Security Policy

[Русская версия ниже](#политика-безопасности)

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Use GitHub's private reporting instead:
**[Report a vulnerability](https://github.com/Leadaxe/LxBox/security/advisories/new)**.
The report is visible only to you and the maintainer until a fix is released.

Include what you can:

- affected app version (Settings → About, e.g. `2.25.4`), Android version and device;
- the feature involved (VPN mode / per-app rules, subscription import, node parsing,
  the Intent API, the debug/support feed, on-device secrets, …);
- steps to reproduce, a minimal config or subscription link, or a proof of concept;
- impact as you understand it: traffic leak, local attack surface, secret exposure.

You will get a reply within a few days. Fixes ship as a patch release on the current
line; the advisory is published after the fix, with credit to the reporter unless you
ask otherwise.

## Scope

Report here for anything in the LxBox app itself: the Android client, the Flutter UI,
the config pipeline (parsing, guards, emitted sing-box JSON), the VPN service and its
routing policy, the public Intent API, storage of keys and subscription credentials.

The tunnel core is [sing-box-lx](https://github.com/Leadaxe/sing-box-lx). If the problem
is in the core (transports, protocols, DNS engine), report it there; if you are not sure,
report here and we will route it.

The threat model and the protections in place are described in
[docs/SECURITY.md](docs/SECURITY.md).

## Supported versions

Only the latest release (see [Releases](https://github.com/Leadaxe/LxBox/releases))
receives security fixes. Older versions and pre-releases are not patched.

---

# Политика безопасности

## Как сообщить об уязвимости

**Не открывайте** публичный issue для проблемы безопасности.

Используйте приватную форму GitHub:
**[Report a vulnerability](https://github.com/Leadaxe/LxBox/security/advisories/new)**.
Отчёт виден только вам и мейнтейнеру до выхода исправления.

Укажите, что сможете:

- версию приложения (Settings → About, например `2.25.4`), версию Android и устройство;
- фичу (VPN-режим / per-app правила, импорт подписок, разбор узлов, Intent API,
  отладочная/support-лента, секреты на устройстве, …);
- шаги воспроизведения, минимальный конфиг или ссылку подписки, либо PoC;
- последствия, как вы их понимаете: утечка трафика, локальная поверхность атаки,
  раскрытие секретов.

Ответ — в течение нескольких дней. Исправление выходит патч-релизом в текущей линии;
advisory публикуется после фикса с упоминанием репортёра, если вы не против.

## Область

Сюда — всё, что относится к самому приложению: Android-клиент, Flutter-UI, конвейер
конфига (разбор, гарды, итоговый sing-box JSON), VPN-сервис и его политика маршрутизации,
публичный Intent API, хранение ключей и учётных данных подписок.

Ядро туннеля — [sing-box-lx](https://github.com/Leadaxe/sing-box-lx). Если проблема
в ядре (транспорты, протоколы, DNS-движок), сообщайте туда; если не уверены — сюда,
мы перенаправим.

Модель угроз и реализованные защиты описаны в [docs/SECURITY.ru.md](docs/SECURITY.ru.md).

## Поддерживаемые версии

Исправления безопасности получает только последний релиз
(см. [Releases](https://github.com/Leadaxe/LxBox/releases)). Старые версии и пререлизы
не патчатся.
