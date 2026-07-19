# Ядро — sing-box-lx (fork)

Всё про VPN-ядро L×Box: откуда берём, как пинится, какие build-теги, ловушки при
бампе версии. ARCHITECTURE.md ссылается сюда.

## Что это

Ядро — наш форк [`Leadaxe/sing-box-lx`](https://github.com/Leadaxe/sing-box-lx)
(ветка `lx-1.14`, база upstream `v1.14.0-alpha.33`): upstream sing-box +
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

**Текущий пин: `v1.14.0-lx.14`** — SPEC 030: остановка туннеля больше не виснет
10+ сек при многих WG/AWG-эндпоинтах (особенно сразу после health-check-пинга,
разбудившего их из idle-suspend). Корень — порядок в `box.Close()`: teardown
эндпоинтов ждал завершения in-flight ping-wake (полный rebuild+handshake, до
нескольких секунд на каждый, серийно). Фикс: тик глушится, все WG-UDP-сокеты
закрываются заранее, in-flight wake прерывается при старте close эндпоинта,
эндпоинты закрываются конкурентно. Ни один шаг teardown не пропущен (сессии
закрыты, ключи обнулены, netstack освобождён) — убрано только пустое ожидание.
Это ядровая половина §287 (app-side порог force-stop 3с был паллиативом).
База upstream `v1.14.0-alpha.47`. Build-теги AAR без изменений. История версий
`lx.1…lx.14` — в конце файла.

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
