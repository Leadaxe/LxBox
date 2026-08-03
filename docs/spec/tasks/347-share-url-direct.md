# §347 — «Поделиться URL» шарит сразу, без диалога masked/full

| | |
|---|---|
| Статус | Реализовано |
| Дата | 2026-08-02 |
| Связанные | night T6-2 (исходный masked-share), §129 (file-подписки), §234 (меню записи) |

## Проблема

Long-press на подписке → «Поделиться URL…» открывал промежуточный диалог
с выбором «Маскированный» (`https://host/***`) / «Полный». Жалоба юзера:
диалог выглядит как бессмысленное сообщение — человек нажал «поделиться»,
а получил лекцию про токены и два непонятных варианта. Маскированный URL
при этом бесполезен получателю: подписку по нему не добавить.

## Решение

Промежуточный диалог убран (решение юзера 02.08.2026): пункт сразу
открывает системный share-sheet с полным URL — как «Copy URL», только
через шаринг. Предупреждение про токен не нужно: действие явное, юзер
сам выбрал «поделиться URL».

Заодно закрыт смежный гейт: для **file-подписки** (`entry.url` =
`file:<uuid>`, §129) пункт скрыт — шарить локальный ключ кэша бессмысленно.
Раньше гейт был только `entry.url.isNotEmpty`, и file-подписка предлагала
поделиться `file:<local>`.

## Изменения

| файл | что |
|---|---|
| `screens/subscriptions_screen/entry_context_menu.dart` | share инлайн (`Share.share(entry.url)`), гейт `!isFileSubscription`; параметр `onShareUrl` снят |
| `screens/subscriptions_screen/share_subscription_url.dart` | удалён (диалог больше не нужен) |
| `screens/subscriptions_screen.dart` | снята обвязка `_shareSubscriptionUrl` |
| `assets/l10n/ru/ui.json` | ключи диалога удалены («Share subscription URL», «Masked URL is safe…», «Full URL contains…», «Share masked», «Share full») |

`maskSubscriptionUrl` (`services/url_mask.dart`) остаётся — им пользуются
логи и debug-API (night T2-3); снят только share-вызов.

## Границы

«Copy URL» не трогаем: для file-подписки она по-прежнему копирует
`file:<uuid>` — отдельный вопрос, если всплывёт.

## Docs to update

- `CHANGELOG.md` — Unreleased. ✅
