# 284 — WARP endpoint scanner (SCAN: рандом-посев → raw-проба через ядро → выбор ноды)

| Поле | Значение |
|------|----------|
| Статус | App-сторона реализована (коммит f45dd1b, develop). Kernel raw-probe — `sing-box-lx SPEC 028` реализован на ветке `lx-spec028-warp-raw-probe` (d769f650: 4 build-комбо exit 0 + byte-exact WG-тесты). Осталось: rebuild `.aar` (`make lib_android`) + re-pin `libbox.version` + device-verify |
| Дата старта | 2026-07-18 |
| Связанные spec'ы | [`025 warp integration`](../025%20warp%20integration/spec.md) (базовый WARP, endpoint-override §135/§138 — снимаем «сканер вне итерации»); [`130 masque-warp-transport`](../130%20masque-warp-transport/spec.md) (MASQUE h3/h2, модель kernel-контракта); [`236 folder-server-testing`](../236%20folder-server-testing/spec.md) (ProbeSession — headless-проба без tun, переиспользуем lifecycle); [`132-warp-endpoint-scanner-research`](../../tasks/132-warp-endpoint-scanner-research.md) (research: liveness-контракт, диапазоны, порты — закрываем его open questions) |
| Затронутые файлы | **app (эта итерация):** `app/assets/warp_endpoints.json`, `app/lib/services/warp/warp_endpoint_picker.dart`, `app/lib/services/warp/scan/*` (новое: candidate-генератор, scan-runner, модели), `app/lib/vpn/cc_channel.dart`, `app/android/.../vpn/ProbeSession.kt`, `app/android/.../vpn/VpnPlugin.kt`, `app/lib/screens/warp_wizard_screen.dart`, `app/lib/screens/warp_wizard/scan_results_sheet.dart` (новое), `app/lib/l10n/app_en.arb` + `app_ru.arb`, `app/test/warp/scan/*`, `docs/spec/features/025 .../spec.md`, `docs/STORAGE.md`, `CHANGELOG.md`, `docs/ARCHITECTURE.md` · **kernel (SPEC 028):** `sing-box-lx/daemon/started_service.proto`, `daemon/started_service_command_lx.go`, `experimental/libbox/command_client_command_lx.go`, `app/android/libbox.version` (re-pin после release) |

## Цель

Кнопка **SCAN** на экране визарда WARP. Один тап: приложение останавливает боевой VPN, поднимает headless-сессию ядра **без tun**, бросает 100 случайных полных конфигураций (IP × порт × протокол × SNI × fingerprint) в **сырые протокольные пробы прямо по IP** (WireGuard-handshake / MASQUE-QUIC / TLS), смотрит **что случайно пробило DPI на текущей сети**, дотестирует лучшие и показывает таблицу: сверху рабочие ноды, снизу — нет. Тап по строке → нода подставляется в конфиг.

Проблема, которую решаем: сейчас endpoint выбирается **слепым рандомом** (`WarpEndpointPicker.randomEndpoint()` — `prefix + rand(1..10) + ':' + pick(ports)`, комментарий прямо «БЕЗ пробы/скана»), режим (WG/MASQUE h3/h2) выбирает человек вручную, живость не проверяется. На DPI-сети, где заблокирован дефолт или целый транспорт, пользователю негде взять рабочий `IP:port` внутри приложения — тащит чужой конфиг.

## Нецели

- **Не** привилегируем ни один протокол в посеве. Посев — Монте-Карло по всему пространству; «что пролезет» решает сеть, а не наше допущение. (Мотивация: DPI режет именно WG-паттерн — завязка посева на WG/AWG ослепила бы скан ровно там, где он нужен.)
- **Не** ведём внешний реестр эндпоинтов и **не** тянем сторонние (иранские/китайские) списки в рантайме. Пул — зашитый, выведен из **Cloudflare-first-party** диапазонов (см. §«Источник пула»).
- **Не** делаем непрерывный фоновый скан / авто-ротацию endpoint. SCAN — ручное действие пользователя.
- **Не** пишем uTLS-fingerprint в итоговую MASQUE-ноду (ядро дропает utls на QUIC — `sing-box-lx SPEC 027`, [[project_281_utls_fingerprint_normalize]] §282). fp — **диагностическое** измерение пробы (какой ClientHello слать), не поле ноды. См. §«uTLS-fingerprint — ограничение».

## Согласованные решения

- **Двухфазный скан.** Фаза 1 — широкий дешёвый посев (100 случайных конфигов, отсев по живости+скорости). Фаза 2 — глубокий дотест топ-3 живых (вариации параметров + повторяемость). Экономит пробы: дорогой полный матрикс гоняется только на 3 победителях.
- **Сырые пробы, DNS-независимо, по IP.** Не HTTP url-test. WG = handshake initiation по UDP на `IP:port`; MASQUE-h3 = QUIC-handshake на `IP:443`; MASQUE-h2 = TLS-handshake на `IP:443` с SNI. Проверяем «endpoint отвечает по протоколу / пролезает через DPI», а не «интернет работает». Никаких доменов и резолва — кандидат уже `IP:port`.
- **Стоп боевого VPN перед сканом.** Пробы уходят напрямую с устройства (вне tun), иначе завернулись бы в туннель. Один CommandServer на процесс (`command.sock` в общем basePath) — headless-проба физически требует, чтобы боевой VPN был опущен. Реализуется композицией `stopVPN()` (блокирующий до `Stopped`) → headless raw-probe сессия. После скана VPN **не** перезапускаем автоматически: пользователь выбирает ноду и подключается заново с ней.
- **Raw-probe примитив — kernel-side** (`sing-box-lx SPEC 028`), по модели §130. app-сторона (ProbeSession lifecycle §236, VPN-stop, эмит-цепочка, showModalBottomSheet-таблица) переиспользуется; net-new — только новый gRPC-метод в ядре + Dart/Kotlin обёртки. До появления нового `.aar` app-мост деградирует gracefully (SCAN сообщает «probe unavailable», не крашит).
- **Источник пула — Cloudflare-first-party.** См. отдельную секцию.
- **Credentials по требованию.** WG-проба не требует полной CF-регистрации (эфемерные ключи + zeroed `reserved`, ретрай с реальным `clientId` — §132). MASQUE-**reachability** (фаза 1) не требует enroll (голый QUIC/TLS на :443). Полный MASQUE-handshake (фаза 2) требует реального `MasqueAccount` (enroll даёт server-pubkey для pinning). Значит: фаза-1 MASQUE = reachability без реги; фаза-2 MASQUE-дотест на топ-3 = один реальный enroll при необходимости.

## Архитектура (поток)

```
warp_wizard_screen ──[tap SCAN]──► WarpScanController
        │                                │
        │ (если VPN up) confirm dialog   │ 1. HomeController.stop() → stopVPN() (блок. до Stopped)
        │                                │ 2. ProbeSession.start(headless tun-less config)  [§236]
        │                                │ 3. Фаза 1: 100 случайных ScanCandidate
        │                                │      генератор: random IP×port×proto×SNI×fp (из пула)
        │                                │      pool(concurrency 6) ► CcChannel.warpProbe(candidate)
        │                                │            └► ProbeSession.warpProbe ► libbox
        │                                │                  └► kernel SPEC 028: raw WG/QUIC/TLS handshake by IP
        │                                │      collect {alive, rttMs}
        │                                │ 4. Фаза 2: top-3 alive by rtt → вариации (SNI×fp×proto, N повторов)
        │                                │ 5. ProbeSession.stop()
        ▼                                ▼
 scan_results_sheet ◄──── List<ScanResult> (successful ▲ / failed ▼)
        │
        └─[tap row]─► ScanChoice{ip,port,protocol,sni} ─► _endpoint.text / _transport / _sni.text
                          └► _register() ─► addWarp(endpoint:) ─► §138/§135 override ─► node
```

## Модель данных (Dart, net-new)

`app/lib/services/warp/scan/scan_models.dart`:

```dart
enum ScanProtocol { awg, masqueH3, masqueH2 }   // AWG=WG+обфускация (голый WG DPI режет вернее)

/// Одна случайная конфигурация для пробы (вход фазы 1).
class ScanCandidate {
  final String ip;                // конкретный IP из CF-блока (полный рандом, не только .1-.10)
  final int port;                 // под протокол: WG-порт | 443
  final ScanProtocol protocol;
  final String sni;               // из sni_pool / masque_sni_pool
  final String utlsFp;            // фаза-1: 'chrome' фикс; фаза-2: варьируется (диагностика)
}

/// Результат пробы (выход, ephemeral — не персистится).
class ScanResult {
  final ScanCandidate candidate;
  final bool alive;
  final int? rttMs;               // null если !alive
  final double? loss;             // фаза-2: доля неотвеченных из N повторов
  final String? error;            // текст ошибки пробы (Variant B)
}

/// Что тап по строке возвращает в визард.
class ScanChoice {
  final String ip; final int port;
  final ScanProtocol protocol; final String sni;
}
```

Генератор `app/lib/services/warp/scan/candidate_generator.dart`: `List<ScanCandidate> seed(int n)` — n независимых рандомов. Каждая ось выбирается из пула (см. ниже). `Random.secure()` (как в пикере). Порт согласован с протоколом (WG-порт для `awg`, `443` для masque). fp фазы-1 = `chrome`.

## Источник пула (Cloudflare-first-party, без сторонних реестров)

Расширяем `app/assets/warp_endpoints.json`. Все диапазоны выводятся из **официально опубликованного Cloudflare** ([cloudflare.com/ips](https://www.cloudflare.com/ips/): `162.158.0.0/15` ⊃ `162.159.192/193/195`; `188.114.96.0/20` ⊃ `188.114.96/97/98/99`) + §132-verified. Ноль зависимости от иранских/китайских списков.

| Ось | Значения | Достоверность |
|---|---|---|
| WG IPv4 CIDR | `162.159.192.0/24`, `162.159.193.0/24`, `162.159.195.0/24`, `188.114.96.0/22` | CF-first-party + §132 core |
| WG IPv6 CIDR | `2606:4700:d0::/64`, `2606:4700:d1::/64` | §132 (сужение из /48) |
| WG порты | `2408, 500, 1701, 4500` — **достоверные**; расширенный список — `empirical:true` | §132: длинный 53-портовый список зарублен голосованием |
| MASQUE IPv4 | `162.159.198.0/24` (+ `.192`) | CF consumer-masque data-plane |
| MASQUE порт | `443` | CF |
| SNI | текущие `sni_pool` / `masque_sni_pool` | без изменений |
| uTLS fp | из `kUtlsFingerprints` ([utls_fingerprint.dart](../../../app/lib/services/parser/utls_fingerprint.dart)) | зеркало словаря ядра |

**Новые ключи JSON** (loader `warp_endpoint_picker.dart:40-58` игнорирует нечитаемые ключи — расширить):
```jsonc
{
  "prefixes": [...],            // legacy, для старого randomEndpoint (оставить)
  "ports": [...],              // legacy WG-порты
  "scan": {                    // net-new, для §284
    "wg_v4_cidr":  ["162.159.192.0/24","162.159.193.0/24","162.159.195.0/24","188.114.96.0/22"],
    "wg_v6_cidr":  ["2606:4700:d0::/64","2606:4700:d1::/64"],
    "wg_ports":    [2408,500,1701,4500],
    "wg_ports_empirical": [854,859,864,...],   // помечены, ниже в приоритете
    "masque_v4_cidr": ["162.159.198.0/24","162.159.192.0/24"],
    "masque_port": 443,
    "utls_fp_pool": ["chrome","firefox","safari","edge","random"]
  }
}
```
Хелпер разворачивает CIDR → случайный IP внутри блока (полный рандом по хостовой части, не только `.1-.10`).

## Двухфазный алгоритм

**Фаза 1 — посев (Монте-Карло):**
1. `seed(100)` — 100 случайных `ScanCandidate` (равновероятно по протоколам; IP полный рандом внутри CIDR; fp=`chrome`).
2. `ProbeSession` поднята (headless, без tun). Pool concurrency 6 (как `FolderProbeRunner._runPool`, §209/§236).
3. Каждый кандидат → `CcChannel.warpProbe(candidate, timeoutMs)` → ядро SPEC 028 делает сырой handshake **по IP** согласно `protocol`. Возврат `{alive, rttMs, error}`.
4. Собираем `List<ScanResult>`, ранжируем живые по `rttMs`.

**Фаза 2 — дотест топ-3:**
1. Топ-3 живых по `rttMs`.
2. Для каждого — матрица вариаций: `{все 3 протокола на этом IP} × {SNI из пула} × {fp из utls_fp_pool}`, ограниченная разумным лимитом (напр. ≤12 проб на IP). Плюс N=3 повтора для `loss`/median `rttMs`.
3. Результат обогащает `ScanResult` (loss, стабильный rtt, какие ещё протоколы/SNI/fp пролезли на этом IP).

**Таблица** (`scan_results_sheet.dart`, `showModalBottomSheet<ScanChoice>` — идиома возврата значения, как `folder_picker`/`detour_target_picker`):
- Секция **Successful** (сверху, сорт по rtt): title `IP:port`, subtitle `protocol · SNI · fp · rtt ms`.
- Секция **Failed** (снизу): живые-по-reachability, но не собравшие рабочую комбинацию, + мёртвые. Для прозрачности.
- Тап по Successful → возвращает `ScanChoice` → визард пишет `_endpoint.text` (+ `_endpointAutoFilled=true`, зеркалит `_fillRandomEndpoint()` [warp_wizard_screen.dart:102]), выставляет `_transport`, `_sni.text`/`_masqueSni.text`. Дальше `_register()` → `addWarp(endpoint:)` → §138-gate ([subscription_controller.dart:281](../../../app/lib/controllers/subscription_controller.dart)) форсит non-default endpoint на аккаунт → §135 override ([warp_client.dart:226](../../../app/lib/services/warp/warp_client.dart)) держит наш endpoint над дефолтным API-хостом.

## uTLS-fingerprint — ограничение (важно)

WARP-нода эмитится либо как WG (Endpoint, TLS нет), либо как MASQUE (Outbound, QUIC — ядро **дропает** utls, §282 / `SPEC 027`: настоящий utls-over-QUIC признан недостижимым kernel-side). Значит **выбранный fp нельзя применить к итоговой ноде**. Поэтому:
- fp — измерение **пробы** (какой ClientHello слать, чтобы проверить, режет ли DPI по fingerprint), не поле ноды.
- Фаза 1 фиксирует `fp=chrome` (сокращает пространство). Фаза 2 варьирует fp как **диагностику** «пролезает ли с маскировкой».
- В таблице fp показывается (информативно), но в `emitMasque` **не** идёт. Если/когда ядро научится utls-over-QUIC — fp станет полем ноды (follow-up).

## Kernel-контракт (`sing-box-lx SPEC 028 — WARP_RAW_ENDPOINT_PROBE`)

Модель — §130 (Dart-does / Ядро-does, byte-exact test-vector согласуется первым).

**Ядро реализует** новый gRPC-метод `WarpProbe` рядом с `URLTestOutbound` (✅ реализовано на ветке `lx-spec028-warp-raw-probe` d769f650: handler `daemon/started_service_warp_probe_lx.go`, utls-путь `..._utls_lx.go`, libbox-обёртка `command_client_command_lx.go`, byte-exact WG handshake-тесты):
- Точка вставки: `daemon/started_service.proto` (+ regen `*.pb.go`), handler `daemon/started_service_command_lx.go` (build-tag `with_lx_command`; stub-twin возвращает `Unimplemented`), client wrapper `experimental/libbox/command_client_command_lx.go`.
- **Error model — Variant B** (как `URLTestOutbound`): исход всегда в payload (`{alive, rtt_ms, error}`), не gRPC-ошибка. `alive==false && error==""` невозможно; `rtt_ms` валиден iff `alive`.
- Вход: `{ip, port, protocol(enum awg|masque_h3|masque_h2), sni, utls_fp, timeout_ms, reserved?(3 bytes), peer_pubkey?(base64)}`. **DNS не используется — dial строго по IP:port.** `peer_pubkey` нужен для сборки WG handshake initiation (MAC1 + DH-seal static); пуст → ядро берёт фиксированный CF WARP серверный pubkey (единый для всех эндпоинтов). App для WARP-скана шлёт пусто.
- Семантика по протоколу:
  - `awg` — сырой WireGuard Handshake Initiation (msg type 1, 148 байт vanilla — к CF-endpoint это plain WG, §132 caveat); alive iff Handshake Response (type 2, 92 байта, LE-uint32==2). `reserved` нули; ретрай с реальным на молчании — на стороне Dart (два вызова). RTT = post-write→response.
  - `masque_h3` — QUIC/HTTP3 handshake на `IP:443` c `sni`+`utls_fp` (переиспользовать `protocol/masque` QUIC/utls path); alive iff QUIC-handshake завершился. Фаза-1 = reachability (без MASQUE-enroll); полный MASQUE-auth не требуется для liveness.
  - `masque_h2` — TLS 1.3 handshake на `IP:443` c `sni`+`utls_fp` (`metacubex/utls`); alive iff TLS-handshake завершился.
- Кирпичи уже в ядре: `metacubex/utls v1.8.4`, `protocol/masque`, `common/urltest` (dialer-паттерн). Новый код — raw-dial без URL/DNS.

**Dart/Kotlin обёртки (эта итерация, до .aar):**
- `cc_channel.dart` — `Future<CcProbeResult> warpProbe(ScanCandidate, int timeoutMs)` рядом с `probeUrlTest` (invoke `'warpProbe'`).
- `VpnPlugin.kt:741` — case `"warpProbe"` рядом с `probeStart/probeUrlTest/probeStop` → `ProbeSession.warpProbe(...)`.
- `ProbeSession.kt:88` — `warpProbe(...)` рядом с `urlTest` → `client.get().warpProbe(...)` (новый libbox-символ). Если символ отсутствует в текущем `.aar` → ловим `NoSuchMethodError`/Unimplemented, возвращаем `{alive:false, error:"probe unavailable"}` (graceful degrade).

## Локализация

Новые UI-строки (только английские в исходнике, + ru-перевод, иначе §279 CI strict-гейты красные): `warpScanButton`, `warpScanConfirmStopVpnTitle/Body`, `warpScanProgress` (с `{done}/{total}`), `warpScanSuccessfulHeader`, `warpScanFailedHeader`, `warpScanEmptyResult`, `warpScanProbeUnavailable`, `warpScanRowSubtitle` (`{protocol} · {sni} · {rtt} ms`). §NNN в строках запрещены ([[feedback_no_spec_refs_in_user_strings]]); терминология — «scan/endpoint», не «group».

## Storage

Пул — asset, не storage. Scan-результаты **ephemeral** (не персистятся). Новых top-level storage-ключей нет → backup allowlist/export не трогаем ([[project_backup_allowlist_export_symmetry]] не применяется). Выбранный endpoint идёт по существующему пути `WarpAccount.endpoint` (уже в backup).

## Тесты

- `candidate_generator_test.dart` — `seed(100)` даёт 100; распределение по протоколам ~равномерное; IP внутри заявленных CIDR; порт согласован с протоколом; fp фазы-1 == chrome.
- `scan_runner_test.dart` — фаза-2 берёт ровно топ-3 по rtt; таблица делит successful/failed; graceful-degrade при `probe unavailable`; отмена (`cancel()` → `probeStop`).
- `warp_endpoint_picker_test.dart` — новые `scan`-ключи парсятся; CIDR→IP хелпер в границах блока; legacy `randomEndpoint()` не сломан.
- Все — в зелёный `flutter analyze` на весь проект ([[feedback_ci_analyze_full_project]]).

## Docs to update

- `docs/spec/features/025 warp integration/spec.md` — строка 23 («мы **не** делаем встроенный сканер») и Future-extensions (сканер) → указать, что §284 доставляет SCAN; снять «вне итерации».
- `docs/STORAGE.md` — только если добавим ключ (сейчас нет) → `none`.
- `docs/ARCHITECTURE.md` — новая подсистема (WARP scan + raw-probe kernel surface): краткий абзац.
- `CHANGELOG.md` — при релизе.
- `RELEASE_NOTES.md` / pubspec version — `[deferred till release]`.
- Kernel: `sing-box-lx/SPECS/028-WARP_RAW_ENDPOINT_PROBE` (новый) — контракт + test-vectors.

## Разбивка на задачи

1. **app (эта итерация):** пул + генератор + модели + scan-runner + Dart/Kotlin мост-shells (graceful degrade) + UI (SCAN + sheet + stop-VPN) + l10n + тесты + правка §025. Всё device-INDEPENDENT тестируемо (генератор/модели/парс), кроме реального скана.
2. **kernel `SPEC 028`:** proto + handler + libbox-wrapper + `make lib_android` + release `.aar` + re-pin `libbox.version`. Byte-exact test-vectors (WG 148/92) согласовать с §132.
3. **device-verify (DEFERRED):** реальный скан на CPH2411 на DPI-сети — успешность посева, корректность топ-3, применение выбранной ноды.

## Открытые вопросы §132 — закрыты здесь

- Q3 «где крутить пробу: Dart Noise-IK vs ядро» → **ядро** (SPEC 028). Решение пользователя.
- Q2 «AWG-формат vs vanilla» → **vanilla к CF-endpoint** (сам endpoint — plain WG; AWG-обфускация на нашей стороне, §132 l.60-61).
- Q1 «источник портов» → достоверные `2408/500/1701/4500` хардкод; расширенные помечены `empirical`.
- Q4 «живость 8.x-блоков» → 8.x **не** включаем (empirical, CF не публикует; ограничиваемся first-party CIDR).
