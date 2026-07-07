# §259 — детектор «DNS глушится на direct-маршруте» + попап выбора резолвера

> **СТАТУС: ЧЕРНОВИК, согласуется с владельцем** (08.07.2026). Родился из
> разбора жалобы пользователя 4PDA (Билайн, «режим БС»): на мобильной сети
> сайты не открываются, хотя пинг есть; лечится ручным заворотом DNS в VPN.
> Один device-пункт остаётся открытым (см. §7).

## Проблема (реальный кейс, пользователь 4PDA, сеть Билайн)

На мобильной сети Билайн в «режиме БС» (агрессивный DPI базовой станции) при
режиме белых списков: **VPN-туннель поднимается (пинг есть), но сайты не
открываются**. Причина — DNS-запросы приложений уходят к внешнему резолверу
**напрямую, мимо туннеля**, и оператор их глушит.

### Как дошло до этого (две ступени регрессии от 2.4)

Три бэкапа пользователя (2.4.0 / 2.5.0 / 2.14.0) объективно показывают:
**настройки DNS во всех версиях идентичны, пользователь ничего не менял.**
Значит регрессия целиком в том, как приложение строит конфиг.

| Ступень | Что сменилось | Эффект |
|---|---|---|
| 2.4 → 2.5 | ядро `1.13.13-lx.14` → `1.14.0-lx.1` (§122) | DNS-движок 1.14; деградация скорости резолва при тех же настройках («5 минут думало») |
| 2.6.2 (§206, `ed06c68`) | `dns.final`: `local_dns_resolver` → `cloudflare_udp` | fallback-DNS приложений стал direct к `1.1.1.1`; Билайн его глушит → «пинг есть, сайтов нет» |

Механика ступени 2 (корень жалобы):
- у template-сервера `cloudflare_udp` дефолтный `outbound = direct-out`;
- `normalizeDnsDetour` (`preset_expand.dart:476`) вырезает `detour == direct-out`
  → сервер в конфиге **без** `detour` → идёт напрямую через оператора;
- `dns.final = cloudflare_udp` → все нематченные DNS-запросы приложений
  падают на этот direct-сервер;
- Билайн в «режиме БС» глушит прямой DNS к `1.1.1.1` → домены не резолвятся.

Заворот DNS в VPN лечит: запрос уходит внутри туннеля, мимо DPI.

**§206 сделал полдела**: сменил fallback на приватный внешний DNS, но оставил
его ходить `direct`. Компромисс «приватность ↔ работоспособность» на
агрессивных мобильных сетях качнулся не в ту сторону, и молча.

## Решение (согласовано)

**Не менять дефолт для всех** (глобальный откат `dns.final` вернул бы утечку
DNS оператору всем Wi-Fi-пользователям). Вместо этого — **обнаружить** ситуацию
и **предложить** пользователю выбор:

1. **Детектор**: первые ~6 секунд после подъёма туннеля пассивно слушать
   §180 DNS-поток (`CcChannel.dnsQueries`) и по структурным признакам событий
   определить «живые DNS-запросы через direct массово не доходят».
2. **Баннер** на главном экране (`AppBanner`, palette warning).
3. **Bottom sheet** по тапу — объяснение + две кнопки-действия + «Not now».

| Было | Стало (§259) |
|---|---|
| direct-DNS молча глушится, «пинг есть, сайтов нет», пользователь сам гадает | детектор ловит, баннер + попап объясняют и дают починку в один тап |
| единственный дефолт для всех (компромисс приватность/работа) | дефолт не меняем; выбор отдан пользователю на затронутой сети |

Ядро не трогаем. Детектор и действия — Dart-only, на существующем §180-потоке.

## Детектор — формула (выверена по коду ядра sing-box-lx)

Формула построена итеративно и **сверена с исходниками форка ядра**
(`dns/client.go`, `dns/client_log.go`, `dns/transport_adapter.go`). Три ранних
варианта отброшены как «предикат, который никогда не истинен» — зафиксировано,
чтобы не воспроизвести:

- ❌ `is_direct = outbound содержит "direct-out"` — у нашего дефолтного сервера
  **нет** `detour` (вырезан), а `outbound` в DNS-событии = статический
  `server.Detour` (`transport_adapter.go:48`), т.е. на нём **пусто**. Условие
  дало бы 0 срабатываний.
- ❌ `is_glush` с `is_live` в одном предикате — `rcode == -1` ⟹
  `source == "failed"` (хардкод `SourceFailed` в `emitFailedQuery`,
  `client_log.go`), что проваливает `is_live ∈ {exchanged,refreshed}`. Пустое
  множество всегда.
- ❌ матч `error` по подстроке `"timeout"` — основной путь глушилки Билайна
  даёт `context.DeadlineExceeded` → текст `"context deadline exceeded"`, слова
  `timeout` в нём НЕТ. Плюс `connection reset` / `network unreachable`
  пропускались бы. Заменено на структурный признак.

### Итоговая формула

```
# окно 6 секунд после TunnelStatus.connected, слушаем CcDnsQuery-поток

is_direct    = q.outbound пуст  ИЛИ  любой tag в q.outbound содержит "direct"
                 # server.Detour == "" → outbound пуст → это direct (дефолт)
                 # server.Detour == "direct-out" → ["direct-out"] → тоже direct

is_glush     = q.source == "failed" && q.rcode == -1 &&
               q.error НЕ содержит ("loopback" | "rejected")
                 # rcode==-1 = RcodeNoAnswer (нет ответа): timeout/network/
                 # loopback/rejected-cached. Два локальных отказа отсеиваем по
                 # имени (тексты стабильны, заданы в client.go:214/221) —
                 # остаётся реальный сетевой облом (что нам и нужно).

# аккумуляция за окно:
fail_domains = { q.domain : is_glush && is_direct }        # SET по домену
success_any  = ∃ q : q.source ∈ {"exchanged","refreshed"} && q.rcode == 0
                 # is_live нужен ТОЛЬКО здесь: отсекает cached/optimistic
                 # (старый успех из кэша, который замаскировал бы живой провал)

# решение по закрытию окна:
success_any                            → DNS жив, молчим
|fail_domains| >= 2  &&  !success_any  → dnsDirectBlocked = true → баннер
иначе                                  → молчим (мало данных / туннель виноват)
```

**Почему set по домену, а не счётчик событий**: один мёртвый домен даёт 2
события (A + AAAA), оба `rcode==-1`. Порог по событиям выстрелил бы от
полутора доменов. `|fail_domains| >= 2` = минимум два РАЗНЫХ мёртвых домена
при нуле успехов — консервативно, против ложных тревог.

### Точные поля `CcDnsQuery` (`cc_channel.dart:560-647`)
`domain`, `source` (exchanged/cached/optimistic/refreshed/rejected/failed),
`rcode` (signed; `-1` = нет ответа), `failed`, `error`, `outbound` (List).
Все нужные поля уже есть — правок ядра/Kotlin/модели НЕ требуется.

## Встраивание — детектор (Dart)

Образец — автопинг §158 (`ping_orchestration.dart`), тот же lifecycle.

| Точка | Файл | Якорь |
|---|---|---|
| Триггер старта окна | `controllers/home_controller.dart` | в `_handleStatusEvent`, ветка `tunnel == connected` (~стр.294), после `_scheduleAutoPing()` — вызвать `_scheduleDnsDirectDetector()` |
| Отмена при disconnect | `controllers/home_controller.dart` | disconnect-ветка (~стр.323): `_dnsDetectorTimer?.cancel()` + отписка |
| Новый mixin | `controllers/home_controller/dns_direct_detector.dart` *(новый)* | окно-таймер, подписка, аккумулятор, эмиссия |
| Подписка на поток | `vpn/cc_channel.dart` | `_cc.dnsQueries.listen(...)` — broadcast-поток, доп. подписчик безопасен |
| Флаг состояния | `models/home_state.dart` | `final bool dnsDirectBlocked` (default false) + в `copyWith` (образец: `configChangedNeedRestart`) |
| Сброс флага | `home_controller.dart` | при новом старте и disconnect → `dnsDirectBlocked: false` |

### ⚠️ Тонкость: profilerClient (рефкаунт)

§180 DNS-события из ядра идут только когда **поднят profilerClient**
(`ccConnectProfiler` включает native `subscribeDNSQueries`). `dnsQueries` —
broadcast-поток; `.listen()` безопасен, но если профайлер не активен —
**событий не будет** и детектор ослепнет.

`connectProfiler`/`disconnectProfiler` (`cc_channel.dart:172`) — **без
рефкаунта на Dart-стороне**. Наивный `disconnectProfiler()` в конце окна
оборвёт подписку активному профайлеру (открытый экран Profiler).

**Требование**: детектор поднимает profilerClient на время окна и опускает
его, ТОЛЬКО если поднял сам (профайлер-экран не был активен). Реализовать
простой рефкаунт/флаг «profiler держится детектором» в `CcChannel` или мьютекс
на уровне контроллера. Не оборвать `traffic_profiler`.

## Встраивание — UI (баннер + bottom sheet)

Система баннеров — `screens/home/widgets/app_banner.dart`.

**Баннер** (в `activeBanners()`, перед `return`):
```
if (s.dnsDirectBlocked) → AppBanner(
  key: 'dns_direct_blocked',
  message: 'DNS not responding on this network — tap to fix',
  icon: Icons.dns_outlined,
  palette: BannerPalette.warning,
  onTap: a.onDnsBlockedHelp,   // новый колбэк в BannerActions
)
```
`BannerActions` (`app_banner.dart:46`) — добавить `onDnsBlockedHelp`;
прокинуть из `home_controls.dart` (открывает bottom sheet).

**Bottom sheet** — образец `screens/home/widgets/detour_cycle_sheet.dart`
(ручка-handle + header + `showModalBottomSheet(isScrollControlled:true)`):

```
────────── ручка ──────────
⚠  DNS server not reachable

Your operator seems to block direct DNS queries on this
network. Choose how to resolve names:

┌────────────────────────────────────────────┐
│  Route DNS through VPN        (recommended) │  → действие 1
└────────────────────────────────────────────┘
  Queries go inside the tunnel — private, and
  works past the operator's block.

┌────────────────────────────────────────────┐
│  Use operator's DNS                         │  → действие 2
└────────────────────────────────────────────┘
  Works everywhere, but your operator sees
  every domain you visit.

              [ Not now ]
```

> Тексты — черновик (English-only по правилу проекта). Отшлифовать при
> реализации; §NNN в видимые строки НЕ писать.

## Действия кнопок

Обе кнопки **применяют настройку и запускают штатный цикл пересборки** (не
рвут соединение молча). После записи → `configDirty` → баннер «Settings
changed / restart to apply» → пользователь подтверждает рестарт. Так же, как
любое другое изменение DNS-настроек сегодня.

**Кнопка 1 — «Route DNS through VPN»** (рекомендуемая):
- для каждого enabled template DNS-сервера (`google_udp`, `cloudflare_udp`)
  выставить `varValues['outbound'] = <vpn-канал>` (по умолчанию `vpn-1`;
  канал взять из `SettingsStorage.getChannels()`, `enabled || isRequired`);
- `SettingsStorage.saveDnsServers(updated, flush:false)` → `markConfigDirty()`.

**Кнопка 2 — «Use operator's DNS»** (не рекомендуемая):
- `SettingsStorage.setVar('dns_final', 'local_dns_resolver', flush:false)`
  (`dns_final` ∈ `_configVarKeys` → авто-dirty);
- восстанавливает 2.4-поведение (системный DNS оператора). Пользователь увидит
  штатный `LocalResolverWarningBanner` (утечка) — это ожидаемо, конфликта нет
  (тот баннер локален для экрана DNS Settings).

**Кнопка 3 — «Not now»**: закрыть sheet, ничего не менять. Баннер остаётся
до следующего старта / успешного резолва.

| Файл действий | Якорь |
|---|---|
| `services/settings_storage/network.dart` | `getDnsServers` / `saveDnsServers` |
| `services/settings_storage/vars.dart` | `setVar('dns_final', …)` |
| `services/settings_storage.dart` | `_configVarKeys` (dns_final внутри), `flushToDisk` |
| `controllers/subscription_controller.dart` | `generateConfig()` (пересборка) |

## Что НЕ делаем (границы)

- Дефолт `dns.final` в шаблоне **не трогаем** — остаётся `cloudflare_udp`.
- Авто-применение без подтверждения — нет; кнопка ведёт через штатный
  rebuild/restart-цикл.
- Ядро/Kotlin/модель `CcDnsQuery` — без изменений.
- Не путать с §246–§253/§256 (Force IPv4 / AAAA «мёртвый рунет») — **другая**
  проблема (direct-IPv6 на сетях без IPv6); здесь про direct-DNS-глушение.

## §7 — device-верификация (открытые пункты)

Форк ядра `sing-box-lx` (SPEC 018) не в этом репо → часть контракта взята из
наших тестов/комментариев. Снять на живом баге (Билайн, «режим БС»):

1. **Ключевой (единственный незакрытый кодом)**: поймать live-`failed`-событие
   от `cloudflare_udp` и убедиться, что `outbound` **пуст** (подтвердить, что у
   дефолтного сервера нет `detour`). Если пришло `["direct-out"]` — формула
   всё равно корректна (ветка «содержит direct»), но факт зафиксировать.
2. Убедиться, что `error` при глушилке Билайна = `deadline exceeded` /
   `connection reset` / `network unreachable` и **не** содержит случайно
   `rejected`/`loopback`.
3. Подтвердить, что `refreshed` — живой сетевой запрос (для `success_any`).
4. Сверить, что `loopback` и `rejected (cached)` — единственные локальные
   `rcode==-1`-отказы (нет третьего, который посчитаем за глушение).

Пункты 2–4 ожидаются подтверждёнными грепом по ядру (владелец); §7.1 — глазами
на устройстве через debug-хендлер DNS-стрима
(`domain / source / rcode / outbound / error`).

## Тесты

- `test/` — юнит на аккумулятор детектора: набор `CcDnsQuery` →
  `dnsDirectBlocked` (кейсы: 2 мёртвых direct-домена → true; есть success →
  false; cached-фейлы → игнор; loopback/rejected → игнор; 1 домен A+AAAA →
  false, т.к. один уникальный домен).
- Регресс: пустой `outbound` == direct; `["direct-out"]` == direct.
