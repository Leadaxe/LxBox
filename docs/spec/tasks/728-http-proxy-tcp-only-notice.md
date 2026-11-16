# 728 — Заметка «только TCP» на узле HTTP-прокси

| | |
|---|---|
| **Статус** | Done |
| **Дата** | 2026-11-12 |
| **Повод** | [issue #187](https://github.com/Leadaxe/LxBox/issues/187): HTTP-прокси оператора (WAP-шлюз) поставлен detour-сервером подписки, автор не понимает, почему «не работает» |
| **Связанные** | [222 — протокол HTTP-прокси](222-http-proxy-protocol.md), [features/008 NODE_EDITOR](../features/008-NODE_EDITOR/FEATURE.md) |

## Docs to update

- эта задача
- [CHANGELOG.md](../../../CHANGELOG.md) — Unreleased, Added
- [USER_GUIDE.md](../../USER_GUIDE.md), [USER_GUIDE.ru.md](../../USER_GUIDE.ru.md) — раздел о подходящих хопах цепочки

## Problem

HTTP-прокси открывает туннель методом CONNECT, то есть несёт только
TCP-соединения. Пользователь, который ставит такой прокси detour-сервером
подписки или выходом Направления, нигде в приложении об этом не узнаёт:

- узел с TCP-транспортом (VLESS, Trojan, VMess; ws, grpc, xhttp поверх h2) за
  HTTP-прокси работает полностью — UDP приложений он заворачивает в свой поток;
- узел, который сам ходит по UDP (Hysteria2, TUIC, WireGuard / AWG, MASQUE и
  xhttp на h3), за HTTP-прокси не соединяется, и причина не названа;
- сам HTTP-прокси, выбранный выходом, UDP приложений не передаёт.

В подписке вперемешку узлы обоих видов, и часть из них молча не работает.

## Diagnosis

Проверено по коду 12.11.2026:

- `node_warning.dart` знает про detour только кольцо, отсутствующую цель,
  detour на группу и глубину цепочки — про транспорт ничего;
- здоровье detour (задача 355) смотрит, жив ли узел-носитель;
- `core_chain_capability.dart` проверяет версию ядра и теги сборки;
- экран настроек подписки и пикер detour-сервера про UDP не говорят.

Единственное упоминание — USER_GUIDE, раздел о подходящих хопах, и только про
WireGuard и MASQUE за TCP-хопом.

## Solution

Решение владельца (12.11.2026): заметка на самом узле HTTP-прокси.

`app/lib/screens/node_settings_screen.dart`, вкладка Settings, секция Info:
под строкой Server у узла `HttpSpec` стоит текст в стиле существующих заметок
экрана (`bodySmall`, `onSurfaceVariant`), ключ `http-tcp-only-notice`:

> This proxy carries only TCP connections. Nodes with a TCP transport work
> through it fully; UDP-based nodes (Hysteria2, TUIC, WireGuard) do not.

Формулировка «TCP-соединения», а не «TCP-трафик», выбрана намеренно: внутри
TCP-соединения узел несёт что угодно, в том числе UDP приложений.

Переводы — `assets/l10n/ru/ui.json`, `assets/l10n/zh/ui.json`.

Заметка статична и условий не имеет: она описывает свойство протокола, а не
состояние конфигурации. `NodeWarning` не заводился: коды предупреждений живут
в общем с лаунчером реестре, а здесь нечего ни снимать, ни чинить.

## Risks and edge cases

- Shadowsocks за HTTP-прокси: TCP идёт, UDP приложений отправляется отдельными
  UDP-пакетами и не проходит, если на узле нет UDP-over-TCP. Заметка этот
  случай не называет.
- HTTP-узел, пришедший из подписки, открывается экраном разбора узла
  (`node_inspect_screen.dart`), там заметки нет.
- SOCKS5 не затронут: протокол умеет UDP ASSOCIATE, поддержка зависит от
  сервера.

## Verification

- `app/test/screens/node_settings_http_tcp_only_test.dart`: у http-узла
  заметка есть, у vless-узла её нет. Прогон локально 12.11.2026 — 2/2.
- На устройстве и эмуляторе не проверялось.

## Unresolved / follow-up

- Предупреждение на UDP-узле, чей detour — http, и строка со счётчиком таких
  узлов под полем Detour-сервер у подписки. Не делалось: решения владельца нет.
