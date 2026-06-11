# 114 — User-Agent подписок: брендинг `LxBox-android` + токен `sing-box`

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

- клиента, опознанного как sing-box (UA содержит `sing-box` **с дефисом**),
  кормят base64/URI-списком подписки — его парсер v2 умеет ингестить;
- неопознанному клиенту (UA с голым `singbox` без дефиса, либо вовсе без
  `sing-box`-токена) панель может отдать полный sing-box JSON-конфиг
  (`{dns,route,inbounds,outbounds,...}`) или generic-заглушку — такой формат
  парсер не переваривает, добавление подписки падает/крашится.

Эмпирически на боевой панели (`curl -A "<UA>" https://sub.vern13.ru/D3eYJ7bcN1Wwor1h`):

| UA | Ответ |
|----|-------|
| `singbox-launcher/1.1.4` | JSON-объект — **плохо** |
| `LxBox-desktop/1.1.4 (sing-box/1.13.13-lx.6; macos arm64)` | base64 — **хорошо** |
| любой UA с `sing-box` (дефис) или `LxBox` | base64 — **хорошо** |

Десктопный лаунчер уже пофикшен (коммит `18aaafd`). Андроид-сборка слала
`LxBox Android subscription client` — содержит `LxBox` (vern13 на нём отдаёт
base64), но **не несёт** токена `sing-box/<core>`, поэтому ломается на панелях,
которые опознают именно по `sing-box`. Приводим Android к десктопному формату.

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

Источники для runtime-сборки UA: appVersion — `VersionInfo.I.version`
(PackageInfo); core — `BoxVpnClient.getCoreVersion()` (`Libbox.version()` через
method-channel); SDK/ABI — `device_info_plus` (как в `debug/handlers/device.dart`).

## Решение

Зеркалим десктопный `LxBox-desktop/<ver> (sing-box/<core>; <os> <arch>)`.

### A. Новый билдер UA — [`subscription/user_agent.dart`](../../app/lib/services/subscription/user_agent.dart)

- `buildSubscriptionUserAgent({appVersion, coreVersion, platform})` — чистая
  функция, формат:

  ```
  LxBox-android/<appVersion> (sing-box/<coreVersion>; android <sdk> <abi>)
  ```

  например `LxBox-android/2.0.4 (sing-box/1.13.13-lx.6; android 34 arm64-v8a)`.
  Санитайзит токены (срез ведущего `v`, вырез `()`/`;`/пробелов), на пустых
  значениях — `unknown`, чтобы инварианты держались всегда.
- `resolveSubscriptionUserAgent()` — резолвит runtime-источники, кеширует
  результат; degraded core (`''`, ранний старт / тесты) **не** кешируется, чтоб
  следующий fetch получил настоящую версию ядра. Источники best-effort.

### B. Проводка в fetch — [`sources.dart`](../../app/lib/services/subscription/sources.dart)

- `UrlSource.userAgent` → `String?`, дефолт `null` (const-конструктор сохранён).
- `_fetch`: `final effectiveUa = ua ?? await resolveSubscriptionUserAgent();`.
- Явный UA по-прежнему можно передать (override) — поведение не сломано.

### Инварианты (как на десктопе)

1. бренд-токен начинается с `LxBox-android/`;
2. присутствует `sing-box/<core>` (распознавание панелями);
3. голого `singbox` (без дефиса) нет нигде.

## Риски и edge cases

- **Core ещё не поднят** на момент первого fetch → `sing-box/unknown`. Инвариант
  №2 (`sing-box/`) держится, панель опознаёт; реальная версия подтянется позже
  (degraded не кешируется).
- **Не-Android / тесты** → platform-токен схлопывается в `android`,
  device_info/method-channel недоступны → ловятся try/catch.
- Намеренно **не** трогали GitHub-UA (update/rule-set/support) — privacy, и они
  не ходят к подписочным панелям.

## Верификация

- Unit: [`user_agent_test.dart`](../../app/test/subscription/user_agent_test.dart)
  — три инварианта + санитайзинг (срез `v`, вырез скобок, fallback'и).
- `flutter analyze` чисто; полный `flutter test` зелёный (965 тестов).
- **Live-панель (curl против vern13)** — подтверждён routing UA → формат тела:
  - `singbox-launcher/1.1.4` → JSON-объект (плохо, 2008 байт);
  - `LxBox Android subscription client` (старый) → base64 (308 байт);
  - `LxBox-android/2.0.3-dev.2 (sing-box/1.13.13-lx.6; android 34 arm64-v8a)`
    (новый) → base64, декодится в `vless://`-узел (308 байт).
- **Pending device-smoke**: добавление подписки vern13 в самом приложении без
  краша; старые подписки работают как раньше.

## Нерешённое / follow-up

- Стейл-дрифт в §3.1 о retry («2 попытки × 2с» vs фактические 3 попытки exp
  backoff 1s/3s) — не трогал в этом таске, чисто документационный.
