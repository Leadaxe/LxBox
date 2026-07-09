# §262 — детектор здоровья DNS в профайлере + баннер решений

**Статус:** Реализовано (не device-verified)
**Заменяет:** §259 (детектор direct-DNS-глушения с окном 10с на старте — не ловил
трафик, вырезан) — механику действий Route-DNS-through-VPN / Use-operator-DNS перенял
из его листа.
**Зависит от:** [§261](261-dns-stream-to-command-multiplex.md) — DNS-события теперь
неотделимы от профайлера (пришли через command-мультиплекс), поэтому детектор живёт
в `TrafficProfiler` как постоянный, а не разовый.
**Файлы:** `services/dns_health_detector.dart` (логика), `services/traffic_profiler.dart`
(геттеры + notify), `screens/live_events_tab/dns_health_banner.dart` (баннер),
`screens/live_events_tab/dns_health_sheet.dart` (лист решений), `screens/live_events_tab.dart`
(вставка баннера).
**Тип:** новая UI-фича поверх готовой логики детектора.

---

## 0. Проблема

DNS может массово не резолвиться, пока туннель жив (operator блокирует direct-DNS,
FakeIP выключен, `dns_final` смотрит в недоступный резолвер). Пользователь видит «интернет
не работает», но не знает, что виноват именно DNS. §259 пытался ловить это разовым окном
10с на старте — не успевал набрать трафик. §262 — постоянный детектор в профайлере: видит
весь поток DNS/conn-событий, пока идёт запись в `_globalRollingBuffer` (always-running).

## 1. Критерий вердикта (согласован)

`unhealthy` = **fail-доля ≥ 20%** И **fail-count ≥ 3** И **есть conn-активность** за
скользящее окно **30с**. Смысл: «DNS массово дохнет, а связь ЖИВА (tcp/udp open/close
происходят) → проблема именно в DNS, не в туннеле». При простое (нет conn-событий) —
молчим. Пороги захардкожены константами в `dns_health_detector.dart`:

| Константа | Значение | Назначение |
|---|---|---|
| `kDnsHealthWindow` | 30s | скользящее окно наблюдения |
| `kDnsHealthFailRatio` | 0.20 | минимальная доля fail |
| `kDnsHealthMinFails` | 3 | страховка от шума (пара мёртвых реклам не в счёт) |

Логика вынесена чистой функцией `evaluateDnsUnhealthy(samples)` + классом `DnsHealthStats`
(нейтральны к профайлеру, тестируются без него — 11 юнит-тестов). Склейка с
`TrafficEventKind` — в `traffic_profiler.dart` (`_computeDnsHealth`).

## 2. Геттеры профайлера

- `dnsHealthUnhealthy` → `bool` — вердикт (драйвит баннер).
- `dnsHealthFailPercent` → `int` — доля fail в процентах (текст баннера «N% failing»).

Оба считают по `_globalRollingBuffer`, отбрасывая события старше окна по возрасту
(`ageMs > kDnsHealthWindow`).

## 3. Нотификация (гашение вердикта)

Баннер **загорается** на новых событиях: SSE-фид (`globalLiveStream`) → `_onEvent` →
throttled `_rebuildFromBuffer` → `setState` → `build()` перечитывает `dnsHealthUnhealthy`.

Баннер **гаснет**, когда fail-события «остыли» и выпали из окна 30с без новых событий —
SSE молчит, `build()` не зовётся, вердикт залипает. Фикс: `_gcStaleConnIds` (тик 15с при
active session / recording) после тримминга буфера зовёт `notifyListeners()` — **только
если что-то реально стриммилось** (`trimmed`), чтобы на idle не будить UI зря. Это же
чинит залипание `unattributedBannerActive` (та же природа). `_onProfilerChanged` в
live-табе ловит notify и ребилдит.

## 4. UI

**Баннер** (`DnsHealthBanner`) — по образцу `UnattributedBanner`, но кликабельный
(`Material` + `InkWell`, chevron справа). Текст: «N% of DNS queries failing while the
connection is alive — tap to fix». Вставлен в `live_events_tab.dart` под
`UnattributedBanner`, гейт `if (TrafficProfiler.I.dnsHealthUnhealthy)`.

**Лист** (`showDnsHealthSheet` → `_DnsHealthSheet`) — **не меняет настройки молча**.
Объясняет, что можно сделать, и ведёт в нужный экран, где юзер решает сам. Решение
владельца: кнопки навигируют, а не мутируют (прежний вариант молча писал в storage —
отвергнут, плюс ловил баг «ложное already routed» когда резолверы не `google_udp`/
`cloudflare_udp`).

Текст-подсказка перечисляет варианты (route DNS-серверы через VPN-канал по их outbound /
переключить final resolver на оператора / FakeIP резолвит имена внутри туннеля). Кнопки:

| Кнопка | Условие | Действие |
|---|---|---|
| **Open DNS settings** | всегда (при наличии контроллеров) | push `DnsSettingsScreen` — серверы + final resolver в одном экране |
| **Enable FakeIP** | только пока пресет `fakeip` НЕ активирован | push `RoutingScreen(initialPresetsTab: true)` — открывает таб Presets, юзер добавляет FakeIP |

Активность FakeIP считается async в `initState` листа: `getCustomRules()` → есть
`CustomRulePreset presetId=='fakeip' && enabled`.

**Навигация требует контроллеры** (`subController` + `homeController`) — прокинуты через
`StatsScreen → LiveEventsTab → DnsHealthBanner → лист` (**nullable**: из `home_drawer` и
`traffic_bar` оба есть; если контроллеров нет — лист чисто информационный, кнопок нет).
`RoutingScreen.initialPresetsTab` (§262) — новый bool, ставит `DefaultTabController.
initialIndex=1` (таб Presets). Подсветки конкретного тайла нет (вариант B — проще и
надёжнее retry-скролла в дальнем табе).

## 5. Критерии готовности

- [x] `flutter analyze` (весь проект, включая `test/`) — чисто.
- [x] `flutter test` — все зелёные (11 тестов детектора + весь suite).
- [x] Сирота §259 `dns_direct_blocked_sheet.dart` удалена, устаревший коммент в
      `app_banner.dart` вычищен.
- [ ] Device-verify на CPH2411: спровоцировать DNS-сбой (например `dns_final` в мёртвый
      резолвер при живом туннеле) → баннер загорается → тап открывает лист → «Open DNS
      settings» ведёт в DNS-экран, «Enable FakeIP» (пока не активен) открывает таб Presets.

## 6. Ссылки

- Логика: `app/lib/services/dns_health_detector.dart`
- Тесты: `app/test/services/dns_health_detector_test.dart`
- §261 (мультиплекс DNS): `docs/spec/tasks/261-dns-stream-to-command-multiplex.md`
