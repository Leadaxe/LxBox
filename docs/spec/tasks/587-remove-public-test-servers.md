# 587 — Убрать «Get Public Test Servers»

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

«Давай выключим этот пункт про бесплатные сервера». Убирается целиком, во всех
сборках (Play, F-Droid, GitHub).

## Что сделано

- Удалены `app/lib/services/community_servers_loader.dart` и
  `app/lib/screens/subscriptions_screen/public_test_servers.dart`.
- Из overflow-меню экрана Servers убран пункт «Get Public Test Servers».
- С пустого экрана убран блок «No provider yet?» с кнопкой; параметры
  `busy` и `onPickPublicTestServer` у `SubscriptionsEmptyState` больше не нужны.
- Из `ru`/`zh` словарей удалены ключи, которые использовал только этот
  экран: «Get Public Test Servers», «Test servers list unavailable»,
  «No provider yet?», «Try a public test server…», «List %d», «View on GitHub».
- Удалён `public-servers-manifest.json`. Уже установленные версии читают его
  из `main`. Когда файл пропадёт из `main` (со следующим релизом или отдельным
  коммитом по команде владельца), старые версии получат 404 и покажут
  «Test servers list unavailable».
- `docs/FDROID.md`, `docs/GOOGLE_PLAY.md`: из таблицы сетевых запросов убрана
  строка манифеста; для скриншотов вместо манифеста — тестовая подписка
  с замаскированными адресами.

## Проверка

- `grep -rn "PublicTestServer\|community_servers\|public-servers-manifest" app/lib`
  ничего не находит.
- CI: `flutter analyze`, `ui_check --strict` (нет осиротевших ключей).
