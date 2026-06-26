# Отчёт: что сделано с релиза v2.4.4

**Период:** `v2.4.4` (2026-06-23) → HEAD (`ac46982`, 2026-06-26)
**Ветка:** `feat/libbox-1.14-migration`
**Объём:** 57 коммитов · 86 файлов · +5648 / −2125 строк
**Статус:** не зарелижено (ветка не влита в `main`)

Главное событие периода — **миграция ядра на sing-box-lx `v1.14.0-lx.1` и
полный отказ от Clash API**: управляющий канал UI переведён с Clash HTTP на
libbox `CommandClient` (server-stream push вместо Timer-polling). Плюс серия
критических фиксов, найденных при device-тестировании на новом ядре.

---

## 1. Миграция libbox 1.14 + CommandClient (§121 / §122)

Самый крупный блок. Clash HTTP-сервер выпилен; статус, группы, соединения и
URLTest идут напрямую из ядра через libbox `CommandClient`.

- **Нативный канал `BoxCommandClient`** (Kotlin) — три CommandClient'а с разной
  ролью: `statusClient` (always-on), `screenClient` (per-screen, ref-counted),
  `profilerClient` (per-recording). 11 handler-колбэков в fail-safe try/catch.
- **Dart-слой `cc_channel`** — push-стримы status/outbounds/groups/connections
  поверх EventChannel; императивы urlTestOutbound/getRules/selectOutbound.
- **unary-pull `getGroups`** (ядро SPEC 015 / rc.4) — детерминированный lifeline
  там, где push дырявый.
- Kotlin-обвязка адаптирована под breaking-изменения 1.14 (Tailscale/SSH-сервер
  влил новые обязательные методы PlatformInterface/CommandServerHandler).
- Выпил Clash-моста: `proxiesJson`/adapter/`ClashApiClient` удалены.

## 2. Критические фиксы (config/VPN не вставал)

| § | Баг | Фикс |
|---|---|---|
| **172** | Битый `detour` (на отсутствующий outbound, напр. `warp gen`) ронял **весь** конфиг → VPN не вставал | post-step `healDanglingDetours` снимает битый detour, нода работает напрямую (деградация, не fatal) |
| **169** | Битый REALITY `pbk=enabled/true` из подписки отравлял `reality.public_key` → ядро отвергало **весь** config | REALITY только при валидном X25519 (32 байта); невалидный → plain TLS |
| **170** | Заход в Stats при Live recording ронял **процесс** (SIGABRT, гонка map в ядре) | по-клиентный Connections-аккумулятор (screen/profiler раздельно) |
| **122** | Заход в Stats рвал VPN (sink-война) → ложный мёртвый туннель → revoke | один upstream-listen + broadcast-фан-аут стримов |
| **122** | Пустые группы (2 корня: дребезг Stopped + пустой push-снапшот) | native-dedup + Dart stale-guard + getGroups-pull |

## 3. Статистика / профайлер

| § | Что |
|---|---|
| **168** | Профайлер Live/per-app не наполнялся (`buffer_count=0`) → переведён на `CcChannel.connections`, per-app атрибуция через `packageName` |
| **171** | DNS не показывался в Live (ANSI-strip не срезал голые ESC-байты) → исправлен regex |
| **165/166** | Имена правил на Stats/Conns (`Home wifi` вместо обрезков) — справочник `c.rule→title` + кэш; фикс фриза Stats при FAST 0.1с |
| **122** | Conns 0/0 (показывали дельту вместо total); пустой `rule` → `final`; app-иконки; наносекундный `setStatusInterval` (было мельтешение памяти) |

## 4. Энергомодель (§164)

Адаптивная частота CC-клиентов: NORMAL 0.5с (главный) / FAST 0.1с (Stats открыт)
/ пауза status+screen в фоне. Профайлер — единственный живёт в фоне (recording
не глохнет при сворачивании).

## 5. Debug API + automation

- Полное покрытие Debug API: +9 роутов (action: reconnect/reload/clear-error/
  urltest-cancel; settings: interrupt_on_switch/node_sort/enabled_groups/
  vpn_mode).
- `POST /action/start-vpn-headless` — поднять VPN без consent (для self-test).

## 6. UX

- §166 — ошибки (включая пинг) → всплывашка снизу вместо красного баннера сверху.

---

## Device-проверки (все на железе)

| Фикс | Устройство / vc | Результат |
|---|---|---|
| §122 главный экран | тест-телефон | VPN стартует, группы держатся через 5 реконнектов |
| §168 профайлер | CPH2411 vc2817 | buffer 9 (было 0), атрибуция gsf/chrome |
| §170 краш | CPH2411 vc2818 | Stats+Live >70с + стресс = 0 краш-строк |
| §171 DNS | CPH2411 vc2819 | 10 dnsResolve в Live (было 0) |
| §172 detour | CPH2411 vc2822 | rebuild → 248 outbounds, 0 битых detour |

## Открытые хвосты (не блокеры релиза)

- §169 — прогон на самой битой подписке (BLACK LIST) для финального
  подтверждения деградации на живом конфиге (regression-сторона уже зелёная).
- §172 — имя подписки-источника в тексте ошибки (сейчас даёт только tag ноды).
- §167 — переписать билдер на rule_set для wifi+ полей (1.14 headless умеет
  больше) — оптимизация, не баг.
- Merge `feat/libbox-1.14-migration` → `main` и релиз.

## Выводы по миграции (оценка 2026-06-26)

Разбор «стали больше/меньше жрать электричество + откатывать ли эксперимент»
(4 агента, адверсариально верифицировано — опровергнуть ключевые утверждения
не удалось).

### 1. Энергопотребление снизилось

| | ДО (Clash polling) | ПОСЛЕ (CommandClient push + §164) |
|---|---|---|
| Фон | heartbeat `Timer.periodic(20с)` → loopback-HTTP + парс всего `/connections`, **always-on** | `onAppPaused` гасит status+screen → **0 тиков/0 drain** |
| Профайлер | `Timer.periodic(5с)` HTTP | push-дельты, только при записи |
| Тик | HTTP-GET + TCP + полный JSON-decode | внутрипроцессный gRPC + дельты |
| Частота | нет адаптации | NORMAL 0.5с / FAST 0.1с (только Stats) / сон в фоне |

Главный выигрыш — **фон**: было always-on, стало 0. На переднем плане тики
чаще (2/с vs ~0.05/с), но каждый радикально дешевле + UI-ребилд троттлится до
1с; FAST 0.1с физически невозможен в фоне. **Чистый баланс — меньше.**

### 2. НЕ откатывать — необходимый долгосрочный шаг

4 самостоятельных довода: **безопасность** (старый Clash открывал TCP-порт на
`127.0.0.1`, доступный любому приложению устройства; теперь не открывается),
**ядро 1.14** (WG-GRO §010 — download на LTE 0.44→16 Mbps; anti-DPI Hysteria2),
**чистота** (4 поллера → 1 стрим, −~1000 строк pull-diff, типизированный
контракт), **новое** (per-app профайлер, closed-история, +9 Debug-роутов).
Откат тянет назад также §010/§169/§172 + возвращает секьюрити-дыру.

### 3. Системный долг #1 — ядровой мьютекс (обойдён, не починен)

§170 (SIGABRT `concurrent map iteration and map write` в
`libbox.Connections.ApplyEvents`) решён клиент-стороной (по-клиентный
аккумулятор), но мьютекса в ядре нет → третий потребитель `CommandConnections`
вернёт краш. Задокументирован: `sing-box-lx/SPECS/016-CONNECTIONS_MAP_MUTEX`.

### 4. Системный долг #2 — JNI-смоук на старом Android (релиз-гейт)

11 fail-safe `CommandClientHandler`-колбэков (§050/§151) не прогнаны на
Android 10 — unchecked-исключение через JNI там = abort процесса. Смоук на
старом API — гейт перед merge в `main`. Также: server-less AAR держится на
дисциплине, не на автоматике.

**Вердикт:** меньше жрём + продолжать; перед релизом закрыть оба долга.

## Тесты

Полный сьют **1245 зелёных** (2026-06-26). Парсер 200, builder 185, +
профайлер/resolver/detour-degradation. `flutter analyze` чист.

При финальном прогоне на железе всплыл хвост §166 (перенос ошибок пинга в
SnackBar): `app_banner_test` ещё ожидал `last_error`-баннер, удалённый в §166 —
тесты обновлены под новое поведение (баннера нет, ошибка в snackbar).
