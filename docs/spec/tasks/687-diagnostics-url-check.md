# 687 — Раздел Diagnostics: вкладки URL Check и Speed Test

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата начала | 2026-10-27 |
| Источник | issue [#176](https://github.com/Leadaxe/LxBox/issues/176), ядро [sing-box-lx#59](https://github.com/Leadaxe/sing-box-lx/issues/59) |
| Ядро | SPEC 139 `StartConnectionTest`, релиз 1 (`lx` 58791f1e6); пин — первый релиз ядра с ним |
| Связанные спеки | [392F](392F-node-diagnostics/) — диагностика узла (GET через узел); [634](634-speed-test-upload-honest.md) — Speed Test; [666](666-speed-test-open-rangeerror-empty-servers.md) — гард первого кадра Speed Test; [581](581-tailscale-network-tab.md) — образец стримового RPC (Tailscale ping) |

## Проблема

Пользователь видит «сайт не открывается» и не знает, где сломалось: DNS,
правило маршрута, выбор в группе, узел, его detour или сервер за туннелем.
Сырые логи ядра для этого не годятся. Ядро в SPEC 139 научилось делать
настоящий запрос через весь свой конвейер и отдавать дерево стадий с
длительностями, исходом и корневой причиной.

## Решение (слово владельца 26–27.10.2026)

1. Пункт бокового меню **Speed Test** заменяется пунктом **Diagnostics**
   (подпись «URL check and speed test»). Экран — две вкладки:
   **URL Check | Speed Test**. Открывается на URL Check.
2. **Speed Test** — прежний экран целиком, без изменений поведения: тело
   экрана становится вкладкой, `Scaffold` и `AppBar` уходят в экран раздела.
3. **URL Check** — новая вкладка поверх `CommandClient.StartConnectionTest`.

### Вкладка URL Check

**Ввод.**

| Элемент | Поведение |
|---|---|
| Поле URL | `example.com` → `https://example.com/`; `http://`/`https://` — как есть; другое — ошибка под полем «Enter an http or https URL» |
| App | Необязательно. Пикер приложений (`AppPickerScreen`) → `source.packageName`; чип с именем и ✕. Пусто — запрос без источника-приложения |
| Depth | Сегменты **Full · Connect · Route · DNS** → `DEPTH_HTTP / CONNECT / ROUTE / DNS`. По умолчанию Full |
| From scratch | Переключатель → `fresh`. По умолчанию выключен: как в работе (кэш, живые соединения) |
| Run / Stop | Run запускает тест; во время теста кнопка — Stop (`session.Cancel()`). Пока туннель не поднят — Run неактивна, под ней «Start VPN to run a check» |

Постоянные параметры запроса: путь через роутер (`outboundTag` пуст),
`appDNS = true` (тест повторяет DNS-запросы приложения), `network = tcp`,
таймаут ядра по умолчанию (15 с). Тест через конкретный узел здесь не
делается — для этого есть экран узла (§392).

**Вывод.**

- **Итог** — строка над деревом:
  - путь пройден (`rootCause == 0`): «HTTP 204 · 842 ms» (для Connect/Route/DNS
    — «Completed · N ms»);
  - путь оборван: «Failed at `kind` `subject`: `error`» по стадии `rootCause`;
  - ошибка самого теста (`result.error`): текст как есть (`busy` →
    «Too many checks running, try again»).
  - `stagesTruncated` → приписка «trace truncated».
- **Находки** (`findings`) — список под итогом: значок уровня (info / warning
  / problem), текст по коду, атрибуты мелким шрифтом. Неизвестный код —
  код + атрибуты (словарь открыт, §6 SPEC 139). Тексты — таблица ниже.
- **Дерево стадий** — строки по мере прихода (`OnStage`, новая стадия
  `RUNNING` и её завершение с тем же `id`). Отступ = глубина по `parent`.
  В строке: значок исхода, `kind`, `subject`, справа длительность.
  Корневая причина подсвечена. Тап по строке раскрывает атрибуты
  (`key: value`) и ошибку. `kind` и ключи атрибутов показываются как есть
  (словарь ядра открыт, это идентификаторы, не текст).

  | Исход | Значок |
  |---|---|
  | RUNNING | крутилка |
  | OK | ✓ (зелёный) |
  | FAILED | ✗ (красный) |
  | SKIPPED | — (серый) |
  | REUSED | ↺ + возраст из атрибутов |
  | NO_ACK | ? (жёлтый) — «sent, not confirmed» |
  | NOT_EVALUATED | ∅ (серый) |

- **Copy** в шапке итога: текстовая трасса — строка на стадию
  (`startMs`, значок, отступ, `kind`, `subject`, длительность, ошибка),
  затем итог и находки. Для issue и поддержки.

**Жизненный цикл.** Один тест за раз. Уход с вкладки или экрана, новый Run,
остановка VPN — отмена сессии. Результат живёт, пока открыт экран.

### Тексты находок

| Код | Текст |
|---|---|
| `excluded_from_vpn` | This app does not go through the VPN. The path shown is hypothetical |
| `resolve_via_rules_in_source_context` | The server address is resolved by DNS rules for this app; for another app the path may differ |
| `dependency_outside_route` | The path depends on a server that is not on the route |
| `resolve_cycle` | Resolve cycle: a server address is resolved through itself |
| `ip_rules_not_evaluated` | IP rules were not evaluated: the address is unknown |
| `fakeip_not_persisted` | Fake IP is not kept across restarts: apps with cached addresses fail after a restart |
| `fakeip_pool_wrapped` | The fake IP pool wraps faster than the answer TTL: an old address may now belong to another domain |
| `fakeip_unknown_address` | The address is in the fake IP range but has no record |
| `fakeip_address_reassigned` | The address now belongs to another domain |
| `fakeip_ipv6_without_tun_ipv6` | IPv6 fake IP is returned, but the tunnel has no IPv6 address |
| `https_query_rejected` | HTTPS DNS queries are rejected: no ECH and no ALPN hints for the app |
| `quic_rejected` | UDP 443 is rejected: browsers fall back to TCP |
| `reality_not_recognized` | The REALITY server did not recognize the client: check public key, short ID, server name |
| `failed_after_no_ack` | The connection broke after an unconfirmed step: wrong UUID or password, the server cannot reach the target, or large packets are lost |
| `partially_reused` | Some steps were reused: this does not prove the path comes up from scratch |

### Навигация

- `route:speedtest` (поддержка, §356) → Diagnostics на вкладке Speed Test.
- Новый слаг `route:diagnostics` → Diagnostics на URL Check.

## Устройство

| Слой | Что |
|---|---|
| Kotlin `BoxCommandClient` | `startConnectionTest(args)` / `stopConnectionTest()`: свой `CommandClient`, сессия, поколение (как Tailscale ping §581); колбэки из Go-потока в `runCatching`; события в EventChannel `lxbox/cc/connection_test`: `{event: stage …}`, `{event: result …}`, `{event: error, message}`. Тело ответа (`body`) не передаётся — только статус, тип и размер |
| Kotlin `VpnPlugin` | методы канала `startConnectionTest`, `stopConnectionTest` |
| Dart `cc_channel.dart` | вызовы + поток событий |
| Dart модель `connection_test.dart` | стадии по `id`, дерево по `parent`, итог; текстовая выгрузка. Чистая логика, unit-тест |
| Dart UI | `diagnostics_screen.dart` (вкладки), `url_check_tab.dart`, `speed_test_screen.dart` → вкладка |

## Что не делаем

- Тест через выбранный узел (`outboundTag`), `connectIP`, UDP, заголовки.
- Ручку Debug API.
- Сохранение последнего URL и результатов между открытиями экрана.

## Проверка

1. Эмулятор, туннель поднят: `https://www.google.com/generate_204` → итог
   «HTTP 204», дерево с `app_dns`, `route`, `group`/`dial`, `tls`, `http`.
2. Недоступный домен (`https://nonexistent.invalid/`) → корень на DNS.
3. Depth Route — нет стадий `tcp_connect`/`tls`; итог «Completed».
4. Stop во время теста — дерево замирает, итога нет, повторный Run работает.
5. Туннель выключен — Run неактивна.
6. Вкладка Speed Test работает как прежний экран.
7. Copy даёт текстовую трассу.
