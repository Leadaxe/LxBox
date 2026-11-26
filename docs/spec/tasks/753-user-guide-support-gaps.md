# 753 — руководство пользователя: пробелы и устаревшие места по обращениям поддержки

| | |
|---|---|
| **Статус** | Done — правки на ветке `claude/docs-gaps-9ec896`, в develop не влиты |
| **Дата** | 2026-11-19 |
| **Повод** | разбор ~8 600 сообщений Telegram-группы, 2 100 постов 4PDA и 378 issues для бота поддержки: файл `DOC_GAPS.md` в репозитории бота (`lxbox-support-bot/docs/DOC_GAPS.md`) — ~60 мест, где пользователи застревают из-за пробела, устаревшей или путаной документации |
| **Связанные** | 683 (DNS & Resolve, Fixed IP), 694 (NETWORK), 712 (regex в правиле), 691 (Bypass the tunnel), 709 (Core карточками, WireGuard), 729 (Sniff guard), 737 (TLS без detour), 589 (дубли), 713 (Parallel checks), 703 (cache-file timeout), 747 (два процесса) |

## Docs to update

- docs/USER_GUIDE.md, docs/USER_GUIDE.ru.md
- README.md, README.ru.md — витрина повторяла снятые окно Action & Resolve и WireGuard в System

## Problem

Бот поддержки отвечает по документации трёх репозиториев и раз в неделю
пересобирает знания со стабильных веток. Руководство отстало от интерфейса
(окно Action & Resolve, секция WI-FI NETWORK, Custom tunnel routes, WireGuard
в System) и молчит о темах, которые спрашивают постоянно: логика условий
правила, DNS-петля, OEM-убийцы фона, пинг, дубли, Disable unreachable, vpn-1
как detour, правила по приложениям в режиме Proxy, ошибки старта.

## Решение

Правка только документации. Каждый факт сверяется с кодом (`app/lib`,
`app/assets/wizard_template.json`, Kotlin) и CHANGELOG; что в коде не
подтверждается — не пишется и перечисляется в отчёте. Стиль —
`docs/EDITORIAL_POLICY.ru.md` глава 2.

Жёсткое требование бота: у EN-документа и его `.ru.md`-двойника одинаковая
структура заголовков (число, уровни, порядок) — бот сопоставляет разделы по
позиции. Проверка — скрипт перед каждым коммитом.

## Проверка

- паритет заголовков EN/RU у USER_GUIDE и ADVANCED_USER_GUIDE;
- grep штампов из EDITORIAL_POLICY 2.4.5 по RU-версии;
- grep старых названий (Action & Resolve, WI-FI NETWORK, Custom tunnel
  routes, Send DNS to dedicated server) — пусто.

## Итог

Сделано (EN и RU, паритет заголовков 91/91):

- Rules: Action с пунктом Resolve only, секции APPS (Package name regex),
  MATCH (Domain regex), NETWORK (тип сети, Metered networks only);
  подраздел «Условия из разных секций должны совпасть все»; раздел DNS &
  Resolve (Answer Default/Dedicated/Fixed IP, Force IPv4, Resolve before
  routing, Advanced); зеркала DNS-правил и Strategy правила — новыми именами;
  WI-FI NETWORK в Diagnostics → NETWORK.
- VPN Settings: System = Memory limit + Tunnel sleep mode; Core семью
  карточками; Align MTU to the path; TUN: Split default route, Bypass the
  tunnel; TLS Fragmentation — не для серверов с detour, REALITY фрагментируется
  как все (665); новые подразделы Sniff guard, WireGuard (перенесён из
  System), QUIC.
- Серверы: склейка дублей, Test actions, Parallel checks, подраздел «Пинг —
  это запрос через узел», `~` от замеров ядра, View pool, почему окно detour
  не предлагает серверы подписки и другой папки, почему у vpn-1 нет Use as
  detour.
- Частые проблемы: 13 новых симптомов (выбор Направления на главном, разные
  приложения через разные серверы, все узлы ERR, OEM-прошивки, две ошибки
  старта, Proxy и правила по приложениям, Deny-list при блокировке без VPN,
  Ru internet segment и зарубежный сайт, 172.16.0.1/STUN, память и
  `:bg`/`:ui`, смена канала установки); Share dump с предупреждением о
  ключах; URL Check в таблице инструментов; путь Speed Test через Diagnostics.
- Рецепт «Сервис, закрытый в вашей стране», список схем ссылок, uTLS,
  системные приложения в Tunnel apps, текст уведомления, указатель на «с нуля».

Не сделано — в коде не подтверждается или вне L×Box (подробно — в отчёте
сессии): требование формата `.srs` 1.14+, даунгрейд после 2.24, отставание
Play и российские аккаунты, «Suspend execution for cached apps», AdGuard,
WARP-фольклор (colo DME, один ключ на устройство, keepalive), MASQUE поверх
VLESS в панелях, пример URL runetfreedom, Samsung Secure Folder, TV +
Always-on, XHTTP `mode: auto` → packet-up (в коде иначе), iOS, экспорт на
Samsung, Tailscale на десктопе, поля DNS-сервера, правка JSON узла, Usage
region простыми словами.
