# 114 — User-Agent подписок: брендинг `LxBox-android`

| Поле | Значение |
|------|----------|
| Статус | In progress — код/тесты готовы, UA-routing подтверждён curl'ом против vern13, on-device add-flow pending |
| Дата старта | 2026-06-11 |
| Дата завершения | — |
| Коммиты | — |
| Связанные spec'ы | features/026 (parser v2, §3.1 fetch + §11 решение 11); десктоп singbox-launcher коммит `18aaafd` (`BuildSubscriptionUserAgent`) |

## Проблема

Часть subscription-панелей (Remnawave / Marzban-типа) маршрутизирует **тело**
ответа по подстроке в `User-Agent`:

- клиента, опознанного панелью, кормят base64/URI-списком подписки — его парсер
  v2 умеет ингестить;
- неопознанному клиенту (в частности UA с голым `singbox` без дефиса) панель
  может отдать полный sing-box JSON-конфиг (`{dns,route,inbounds,outbounds,...}`)
  или generic-заглушку — такой формат парсер не переваривает, добавление
  подписки падает/крашится.

Эмпирически на боевой панели (`curl -A "<UA>" https://sub.vern13.ru/D3eYJ7bcN1Wwor1h`):

| UA | Ответ |
|----|-------|
| `singbox-launcher/1.1.4` | JSON-объект — **плохо** |
| любой UA с подстрокой `LxBox` (или `sing-box` с дефисом) | base64 — **хорошо** |

Андроид-сборка слала `LxBox Android subscription client` — содержит `LxBox`,
так что vern13 на нём уже отдаёт base64. Приводим UA к чистому брендовому
формату, согласованному с десктопом (`LxBox-desktop`).

## Диагностика

Поиск по дереву (`User-Agent`/`userAgent`/`singbox`/OkHttp-интерсепторы):

- **Подписки**: [`sources.dart`](../../app/lib/services/subscription/sources.dart)
  — `UrlSource.userAgent`, дефолт `'LxBox Android subscription client'`,
  ставится в `_fetch` → `headers: {'User-Agent': ua}`. **Единственное место,
  релевантное маршрутизации панелей.**
- Прочие исходящие UA (GitHub-эндпоинты, не панели — менять не нужно):
  `update_checker.dart` (`LxBox/1.x`, намеренно обезличен ради privacy),
  `rule_set_downloader.dart` (`LxBox`), `support_message.dart` (`LxBox/1.x`).
  Все начинаются с `LxBox`, голого `singbox` не содержат — оставлены как есть.
- Кастомного UA в UI/настройках нет.

Источник для runtime-сборки UA: appVersion — `VersionInfo.I.version`
(PackageInfo). Платформа/ядро сознательно не включаются.

## Решение

Бренд-токен `LxBox-android` сам по себе опознаётся панелями (проверено curl'ом).
По решению владельца UA = **только бренд + версия приложения**: ни `sing-box`/
`singbox`, ни платформенный комментарий (SDK/ABI) не включаются.

### A. Новый билдер UA — [`subscription/user_agent.dart`](../../app/lib/services/subscription/user_agent.dart)

- `buildSubscriptionUserAgent({appVersion})` — чистая функция, формат:

  ```
  LxBox-android/<appVersion>
  ```

  например `LxBox-android/2.0.4`. Санитайзит версию (срез ведущего `v`, вырез
  `()`/`;`/пробелов), на пустом значении — `unknown`, чтобы инварианты держались
  всегда.
- `resolveSubscriptionUserAgent()` — **синхронный**, читает `VersionInfo.I.version`
  (инициализируется в `main()` до `runApp`). Async-источников больше нет, кеш не
  нужен.

### B. Проводка в fetch — [`sources.dart`](../../app/lib/services/subscription/sources.dart)

- `UrlSource.userAgent` → `String?`, дефолт `null` (const-конструктор сохранён).
- `_fetch`: `final effectiveUa = ua ?? resolveSubscriptionUserAgent();`.
- Явный UA по-прежнему можно передать (override) — поведение не сломано.

### Инварианты

1. бренд-токен начинается с `LxBox-android/` (распознавание панелями);
2. голого `singbox` (без дефиса) нет нигде; токена `sing-box` нет вовсе.

## Риски и edge cases

- **Опора только на `LxBox`-бренд.** Распознавание держится на подстроке
  `LxBox`. Если попадётся панель, которая роутит **строго** по `sing-box` и не
  знает про `LxBox`, она вернёт не тот формат. На целевой панели (vern13)
  `LxBox` распознаётся; решение сознательное (владелец отказался и от токена
  `sing-box`, и от платформенного комментария).
- **До `VersionInfo.init()`** (тесты / ранний старт) версия = `0.0.0` →
  `LxBox-android/0.0.0`. Инвариант №1 держится. На практике fetch идёт сильно
  после `init()`.
- Намеренно **не** трогали GitHub-UA (update/rule-set/support) — privacy, и они
  не ходят к подписочным панелям.

## Верификация

- Unit: [`user_agent_test.dart`](../../app/test/subscription/user_agent_test.dart)
  — инварианты (старт с `LxBox-android/`, отсутствие `singbox`/`sing-box`) +
  санитайзинг (срез `v`, вырез скобок, dev-версии, fallback).
- `flutter analyze` чисто; полный `flutter test` зелёный.
- **Live-панель (curl против vern13)** — подтверждён routing UA → формат тела:
  - `singbox-launcher/1.1.4` → JSON-объект (плохо, 2008 байт);
  - `LxBox Android subscription client` (старый) → base64 (308 байт);
  - `LxBox-android` и `LxBox-android/2.0.4` (новые) → base64, декодится
    в `vless://`-узел (308 байт).
- **Pending device-smoke**: добавление подписки vern13 в самом приложении без
  краша; старые подписки работают как раньше.

## Нерешённое / follow-up

- Стейл-дрифт в §3.1 о retry («2 попытки × 2с» vs фактические 3 попытки exp
  backoff 1s/3s) — не трогал в этом таске, чисто документационный.
