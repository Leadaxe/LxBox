# Ядро — sing-box-lx (fork)

Всё про VPN-ядро L×Box: откуда берём, как пинится, какие build-теги, ловушки при
бампе версии. ARCHITECTURE.md ссылается сюда.

## Что это

Ядро — наш форк [`Leadaxe/sing-box-lx`](https://github.com/Leadaxe/sing-box-lx)
(ветка `lx-1.14`, база upstream — см. «Текущий пин» ниже): upstream sing-box +
AmneziaWG 2.0 + нативный XHTTP + LxBox-специфичные фичи (idle-suspend,
round-robin balancer, XHTTP full params, DNS-стрим и др.).

Управление — через **libbox CommandClient** (§122; Clash HTTP-server выпилен).

## Откуда берётся AAR

| | |
|---|---|
| Пин версии | `app/android/libbox.version` — single source of truth (local + CI) |
| Скачивание | `scripts/fetch-libbox.sh` → `libbox.aar` из GitHub Releases форка + SHA256-проверка; идемпотентен (маркер `.libbox.version`) |
| Вызывается из | `scripts/build-local-apk.sh` и CI (`ci.yml` → android job → «Fetch sing-box-lx core») |
| AAR в git | НЕТ (~97 MB, `app/android/app/libs/` в `.gitignore`); `build.gradle.kts` → `implementation(files("libs/libbox.aar"))` |

**Текущий пин: `v1.14.0-lx.17-rc.4`** (v2.19.0) — два самолечащихся фикса
поверх rc.3, оба без клиентских правок.

**rc.4 / SPEC 041** (feature HOTFIXES) — WG/AWG-эндпоинты чинят себя после сна
устройства вместо вечного ERR до ручного реконнекта. Пока телефон спит, UDP-
5-tuple туннеля умирает на пути (истекает NAT-мэппинг и/или протухает
flow-запись DPI), а upstream wireguard-go бесконечно повторяет handshake в тот
же мёртвый сокет — тот же исходящий порт, тот же мёртвый 5-tuple. Реконнект
«чинил» ровно тем, что открывал новый сокет со свежим эфемерным портом. Теперь
это делает ядро: когда цикл повторов handshake у пира исчерпан (~90 с
неотвеченных initiation — существующее give-up-событие, срабатывает только под
спросом на трафик), bind переоткрывается один раз со свежим портом и сразу
инициируется новый handshake. Для masquerade-профилей decoy `i1` уезжает с
первой initiation нового 5-tuple, переоткрывая поток на DPI. Дебаунс — один
rebind на give-up-цикл; явно закреплённый `listen_port` сохраняется
(самолечение сменой порта тогда недоступно, by design); обе схемы bind (прямая
и через `detour`) лечатся одним механизмом. В исправном состоянии, во сне и
после закрытия не стоит ничего — ни таймеров, ни горутин, ни трафика: на
спящем устройстве rebind вырождается в no-op и с idle-suspend (SPEC 020) не
конфликтует.

**rc.4 / SPEC 040** (feature HOTFIXES) — system-стек TCP больше не умирает
навсегда, когда его listener убивают из-под ядра. При `stack: "system"` каждое
новое TCP-соединение из TUN NAT-переписывается на локальный forwarder-listener.
Его accept-цикл считал **любую** ошибку `Accept` терминальной и молча выходил —
поэтому когда что-то ещё в общем Android-процессе закрывало fd этого listener'а
(шальной close на переиспользованном номере дескриптора — тот самый отказ §047
«браузер мёртв, QUIC жив»), стек продолжал работать и переписывать каждый новый
SYN на мёртвый порт. ОС отвечала мгновенным RST: любое приложение получало
`ECONNREFUSED` за ~16 мс до перезапуска VPN, при живых UDP/QUIC/DNS.
Воспроизведение на устройстве: ~1 раз на 8–36 быстрых перезапусков VPN, хуже на
«грязном» процессе — поэтому месяцами не ловилось. sing-tun теперь
fork-сабмодуль (`submodules/sing-tun`, пин на точную upstream-ревизию из
go.mod) с однофайловым патчем: неожиданная ошибка `Accept` логируется с errno
(он называет виновника), listener пересоздаётся на том же адресе, порт
форвардера переопубликовывается атомарно, цикл продолжает обслуживать.
Намеренный `System.Close()` по-прежнему молчит. Счётчик восстановлений — как
телеметрия: если тикает, клиентский триггер закрытия fd жив. Device-verified
01.08.2026 (§329): два живых срабатывания, **errno = `EINVAL`**.

**rc.2:** ротация архива отчётов (SPEC 039 / feature
HOTFIXES) — каталоги `files/oom_reports` и `files/crash_reports` не чистились
никогда, на устройстве накопилось **575 каталогов / 427 МБ за 19 дней**;
теперь перед записью нового отчёта архив подрезается до **32 каталогов и 64 МБ**
(что раньше сработает), удаление — по mtime, не по имени (суффиксы коллизий
`-1`…`-1000` ломают лексикографический порядок). Плюс **240 upstream-коммитов**:
из заметных для форка — URLTest теперь *требует* history storage в контексте
вместо молчаливого создания. **rc.3:** `Endpoint.Close()` снова возвращает
ошибку закрытия tun-устройства (nil-guard из SPEC 020 глотал её и рапортовал
чистое завершение); nil-проверка осталась, изменилось только распространение
ошибки. **javap-diff rc.1 → rc.3: изменений НЕТ** — `PlatformInterface`,
`CommandClient`, `BoxService`, `Libbox` идентичны, состав классов совпадает
(226 в обоих AAR). Device-verified 30.07.2026 (CPH2411): старт чистый,
`last_start_error` пуст, 0 ошибок/fatal в логах, 54 живых замера.

Внимание при бампе через rc.2: он несёт 240 upstream-коммитов, поэтому
javap-diff обязателен даже когда release notes обещают «one-line fix» —
проверять надо против **своего** пина, а не против предыдущего rc. Оба фикса
rc.4 живут целиком внутри ядра (wireguard-go bind и sing-tun accept-цикл),
Java-поверхности не касаются — клиентских правок не потребовалось.

**Предыдущий пин: `v1.14.0-lx.17-rc.1`** — SPEC 038: `GetRunningConfig` возвращает
объект `RunningConfig` с геттером `content()` вместо голого `String`. Голая
строка **убивала процесс ядра на android/arm64 при каждом вызове**: gomobile
кодирует Go-строку в `nstring{void*, len}`, cgo кладёт её в `__packed__`-фрейм,
тот теряет 8-выравнивание, и присваивание слота с указателем идёт через
`runtime.wbMove` → `bulkBarrierPreWrite` → `throw: unaligned arguments`. Это
не паника, а fatal throw — туннель падал без шанса. Дефект внесён SPEC 036,
поэтому §311 был неработоспособен и в rc.3, и в stable `lx.16`; именно так
падало ядро 26.07 (найдено каналом §316). **javap-diff lx.16 → lx.17-rc.1:**
единственное изменение — `getRunningConfig()` сменил возврат
`String` → `RunningConfig`; `PlatformInterface` / `CommandClientHandler` /
`Libbox` без изменений. Клиентская правка — `BoxCommandClient.getRunningConfig()`
зовёт `.content()`. Device-verified 27.07.2026 (CPH2411): 6 вызовов подряд при
живом туннеле → 200, ядро живо, новых крашей нет.

**Предыдущий пин: `v1.14.0-lx.16`** (стабильный) — SPEC 036: `CommandClient.GetRunningConfig`
— канонический снапшот конфига РАБОТАЮЩЕГО ядра (захват один раз на старте в
`newInstance`, post-override, re-marshal; отдача — копия строки). Клиентская
половина — §311 LxBox (`activeModel`, `GET /config/running`): закрывает окно
«пересборка при живом туннеле» и ложный «Not found» на видимую ноду. javap-diff
против lx.15: `+ String getRunningConfig() throws` в `CommandClient`;
`PlatformInterface` / `CommandClientHandler` БЕЗ изменений. Ошибки RPC:
не-STARTED → `FailedPrecondition`, attached-путь/сбой захвата → `Unavailable`,
без `with_lx_command` → `Unimplemented` — обвязка глотает всё в null.

`lx.15` (предыдущий) — SPEC 002: XHTTP больше не ломается за
reverse-proxy. VLESS+XHTTP через nginx/CDN с `mode: packet-up`, trailing-slash
`path` (`/upload/`) и `session_placement: header` раньше падал с `unexpected
download status: 301 Moved Permanently` (клиент безусловно срезал trailing slash
для ВСЕХ mode; nginx `location /upload/ {}` отвечал 301-редиректом на bare-path,
а download-запрос — raw HTTP/2 без follow-redirects — сюрфейсил это как dial
error). Фикс: `path` сохраняется как есть, trailing slash срезается только на
bare-path запросе stream-one. Дефолтные конфиги (session id в path) не
затрагивались. Покрыто url_test-кейсом. + merge upstream `testing` (13 коммитов:
async DNS refactor, WG detour fix сходится с SPEC 029, OpenConnect
auth-challenge, прочие фиксы). База upstream `v1.14.0-alpha.48`. Build-теги AAR
без изменений. **Device-verified** на CPH2411 (2026-07-21): старт без крашей,
Debug API отвечает, VPN поднимается. История версий — в конце файла.

`lx.14` — SPEC 030: остановка туннеля больше не виснет 10+ сек при
многих WG/AWG-эндпоинтах (teardown в `box.Close()` ждал in-flight ping-wake;
фикс — конкурентное закрытие эндпоинтов с прерыванием wake, ни один шаг teardown
не пропущен). Ядровая половина §287.

### AAR до релиза ядра

Пока форк ещё не выпустил официальный релиз (работа на rc-цепочке), AAR берётся
из artifact CI-прогона форка, НЕ из Releases:

```bash
gh run download <run-id> --repo Leadaxe/sing-box-lx --name dist-android
```

Скачанный `libbox.aar` кладётся вручную в `app/android/app/libs/` (маркер
`.libbox.version` — под нужную rc, иначе `fetch-libbox.sh` перекачает). Так
готовился §215 (rc.18) и предрелизные rc.21/rc.22 под v2.9.0 (MASQUE-символы
сверялись `strings libbox.so`).

- ⚠ `app/android/libbox.version` **НЕ коммитить до релиза ядра** — пин на
  несуществующий в Releases тег сломает fetch у всех остальных и в CI.
- ⚠ В проде — **только официальный релизный AAR** (см. ловушку 3).

## Build-теги AAR

Пекутся в `cmd/internal/build_libbox/main.go` (`sharedTags`), НЕ в клиенте:

```
with_gvisor, with_quic, with_wireguard, with_utls, with_naive_outbound,
with_xhttp, with_awg, with_lx_command, with_lx_idle_suspend
```

`with_clash_api` намеренно убран (§122 — CommandClient вместо Clash HTTP).

## ⚠️ Ловушки при бампе версии

### 1. `with_lx_idle_suspend` (rc.19+) — idle-suspend за build-tag

Механика idle-suspend-тика (`route.lx_idle_suspend`, SPEC 020 / §128) компилируется
**только** с тегом `with_lx_idle_suspend`. **Без него `route.lx_idle_suspend` в
конфиге РОНЯЕТ старт ядра** (`rebuild with -tags with_lx_idle_suspend
(mobile-only feature)`).

- Мобильный **AAR** тег содержит (`build_libbox` sharedTags) → официальный
  релизный AAR ОК.
- Desktop/CLI `sing-box` (для `sing-box check`) — тега НЕТ по умолчанию. Валидация
  конфига с `lx_idle_suspend` через desktop-бинарь упадёт без явного
  `-tags with_lx_idle_suspend`.

### 2. Новое поле транспорта/route → «unknown field» роняет ВЕСЬ конфиг

Ядро строго декодит конфиг: если клиент эмитит поле, которого ядро (старая версия)
не знает — падает **весь** конфиг на load, не только одна нода. Классический
рассинхрон «парсер обогнал ядро»:
- §214: rc.15 не знал `sc_max_each_post_bytes` (XHTTP SPEC 002 v2) → бамп rc.16.
- Диагностика: `/device` core_version (§213) — реальная версия ядра в APK.

### 3. gomobile AAR не byte-reproducible

sha локальной сборки ≠ sha релизного AAR (пути/таймстампы в архиве). Функционально
идентичны. `fetch-libbox.sh` сверяет sha скачанного против релизного `SHA256SUMS` —
поэтому в проде **всегда официальный релизный AAR**, не локальный.

### 4. `Libbox.version()` не виден через `strings`

gomobile-бинарь не отдаёт version-строку. Сверять версию ядра — только через
`/device` core_version на устройстве (не выдиранием strings из AAR).

## Клиент ↔ ядро: где чинить баги конфига

Иногда баг «нода роняет конфиг» чинится с двух сторон (defense-in-depth):
- **клиент** — не эмитить невалидное + показать ⚠️ юзеру (видимость). Пример: §217
  (XHTTP `uplink_http_method=GET` вне packet-up → сброс + `XhttpParamResetWarning`).
- **ядро** — soft-fallback вместо fatal. Пример: rc.20 `c0bbb1c5` — тот же GET→POST
  fallback + WARN, чтобы одна кривая нода не валила весь конфиг.

Оба слоя полезны: клиент даёт видимость (⚠️ в подписке), ядро — страховку на
случай, если клиент что-то пропустит.

## История версий (LxBox-релевантное)

| rc | Что добавилось |
|---|---|
| rc.15 → rc.16 (§214) | XHTTP SPEC 002 v2 поля (иначе unknown-field роняет конфиг) |
| rc.18 (§215) | SPEC 020 idle-suspend (`route.lx_idle_suspend`) |
| rc.19 | idle-suspend за `with_lx_idle_suspend` (mobile-only, см. ловушку 1) |
| rc.20 | XHTTP GET→POST soft-fallback (дублирует §217); udpnat2 buffer fix; upstream sync |
| **v1.14.0-lx.1** (стабильный) | Первый стабильный релиз ветки `lx-1.14` (rc.16→rc.22): MASQUE outbound (§130), стабилизация; собран с LxBox v2.9.0 |
| **v1.14.0-lx.11** (стабильный) | Снят guard AWG-over-WireGuard (SPEC 007) — AWG-over-AWG/WG теперь поднимается. Device-verified на CPH2411. (Промежуточные lx.2…lx.10: idle-suspend L3, balancer, Force IPv4, memory-limit, AWG padding/reserved-clear фиксы — см. `docs-lx/lx-changelog.md` в ядре) |
| **v1.14.0-lx.14** (стабильный) | SPEC 030 — Stop не виснет 10+ сек при многих WG/AWG-эндпоинтах (глушение тика + upfront-закрытие UDP-сокетов + abort in-flight wake + конкурентный close). Ядровая половина §287. База upstream `alpha.47`. Build-теги AAR без изменений. (Промежуточные lx.12/lx.13 — см. `docs-lx/lx-changelog.md` в ядре) |
| **v1.14.0-lx.15** (стабильный) | SPEC 002 — XHTTP за reverse-proxy: `path` сохраняется как есть, trailing slash срезается только на bare-path запросе stream-one. + merge upstream `testing` (async DNS refactor, WG detour fix, OpenConnect auth-challenge). База upstream `alpha.48`. Build-теги AAR без изменений. Device-verified на CPH2411 (2026-07-21) |
| **v1.14.0-lx.17-rc.4** (текущий пин, v2.19.0) | SPEC 041 — WG/AWG-эндпоинты самолечатся после сна устройства (rebind со свежим портом по исчерпании handshake-повторов, ~90 с; `listen_port` вручную = самолечение отключено). SPEC 040 — system-стек TCP: accept-цикл пересоздаёт убитый listener вместо молчаливого выхода (sing-tun как fork-сабмодуль); закрывает отказ §047 «браузер мёртв, QUIC жив», errno на устройстве = `EINVAL` (§329). Оба фикса внутри ядра, Java-поверхности не касаются — клиентских правок нет |
| **v1.14.0-lx.17-rc.3** (v2.18.2) | SPEC 039 (rc.2) — ротация архива OOM/crash-отчётов: 32 каталога / 64 МБ, удаление по mtime (на устройстве было 575 каталогов / 427 МБ за 19 дней). + **240 upstream-коммитов** (URLTest требует history storage в контексте). rc.3 — `Endpoint.Close()` снова возвращает ошибку закрытия tun-устройства. **javap-diff rc.1 → rc.3: изменений нет**, клиентских правок не потребовалось |
| **v1.14.0-lx.17-rc.1** | SPEC 038 — фикс fatal throw в `GetRunningConfig` (возврат `RunningConfig` вместо голой строки; см. блок «Текущий пин»). **API-брейк:** сигнатура метода изменилась, клиент обязан звать `.content()` |
| **v1.14.0-lx.16** (стабильный) | SPEC 036 — `GetRunningConfig`: снапшот работающего конфига по CommandClient (клиент — §311 LxBox); SPEC 033/035 — DNS_GROUP и его observability (клиенты — §312/§315). rc.1…rc.3 — промежуточные сборки той же ветки, метод появился в rc.3. `PlatformInterface` без изменений. Подробности — в блоке «Текущий пин» выше |
