# 753 — руководство пользователя: пробелы и устаревшие места по обращениям поддержки

| | |
|---|---|
| **Статус** | In progress |
| **Дата** | 2026-11-19 |
| **Повод** | разбор ~8 600 сообщений Telegram-группы, 2 100 постов 4PDA и 378 issues для бота поддержки: файл `DOC_GAPS.md` в репозитории бота (`lxbox-support-bot/docs/DOC_GAPS.md`) — ~60 мест, где пользователи застревают из-за пробела, устаревшей или путаной документации |
| **Связанные** | 683 (DNS & Resolve, Fixed IP), 694 (NETWORK), 712 (regex в правиле), 691 (Bypass the tunnel), 709 (Core карточками, WireGuard), 729 (Sniff guard), 737 (TLS без detour), 589 (дубли), 713 (Parallel checks), 703 (cache-file timeout), 747 (два процесса) |

## Docs to update

- docs/USER_GUIDE.md, docs/USER_GUIDE.ru.md
- docs/ADVANCED_USER_GUIDE.md, docs/ADVANCED_USER_GUIDE.ru.md — если тема туда относится

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
