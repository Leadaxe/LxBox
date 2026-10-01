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
константу», затем «не надо ничего удалять, просто закрой». Файлы не
удаляются, экран выключен во всех сборках (Play, F-Droid,
GitHub).

## Что сделано

- `CommunityServersLoader.enabled = false`
  (`app/lib/services/community_servers_loader.dart`). При `false`:
  - в overflow-меню экрана Servers нет пункта «Get Public Test Servers»;
  - на пустом экране нет блока «No provider yet?» с кнопкой
    (`SubscriptionsEmptyState.onPickPublicTestServer == null`);
  - манифест не запрашивается.
- Код экрана, загрузчик, переводы и `public-servers-manifest.json` остаются;
  включение — `enabled = true`.
- Уже установленные версии читают манифест из `main` и показывают пункт, как
  раньше; константа действует с версии, в которую войдёт.

## Проверка

- При `enabled = false` пункта меню и блока на пустом экране нет.
- CI: `flutter analyze`, `ui_check --strict`.
