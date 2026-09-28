# 587 — Выключить «Get Public Test Servers»

| Поле | Значение |
|------|----------|
| Статус | Implemented |
| Дата старта | 2026-09-28 |
| Дата завершения | 2026-09-28 |
| Коммиты | см. `git log -- docs/spec/tasks/587-remove-public-test-servers.md` |
| Связанные spec'ы | tasks/149, tasks/422, features/025 |

## Проблема

Экран Servers предлагал готовые публичные подборки серверов: пункт меню
«Get Public Test Servers» и кнопка на пустом экране. Список тянулся из
`public-servers-manifest.json` в ветке `main` (подборки igareck). Приложение
выглядело как «клиент плюс доступ из коробки», а не как клиент для своих
серверов. Это лишний повод для снятия из Google Play в РФ и для претензий
к автору.

## Решение владельца (28.09.2026)

«Давай выключим этот пункт про бесплатные сервера», затем «спрячь за
константу». Код не удаляется, экран выключен во всех сборках (Play, F-Droid,
GitHub).

## Что сделано

- `CommunityServersLoader.enabled = false`
  (`app/lib/services/community_servers_loader.dart`). При `false`:
  - в overflow-меню экрана Servers нет пункта «Get Public Test Servers»;
  - на пустом экране нет блока «No provider yet?» с кнопкой
    (`SubscriptionsEmptyState.onPickPublicTestServer == null`);
  - манифест не запрашивается.
- Код экрана, загрузчик и переводы остаются; включение — `true` плюс
  возврат манифеста в `main`.
- Удалён `public-servers-manifest.json`. Уже установленные версии читают его
  из `main`. Когда файл пропадёт из `main` (со следующим релизом или отдельным
  коммитом по команде владельца), старые версии получат 404 и покажут
  «Test servers list unavailable».
- `docs/FDROID.md`, `docs/GOOGLE_PLAY.md`: из таблицы сетевых запросов убрана
  строка манифеста; для скриншотов вместо манифеста — тестовая подписка
  с замаскированными адресами.

## Проверка

- При `enabled = false` пункта меню и блока на пустом экране нет.
- CI: `flutter analyze`, `ui_check --strict`.
