# 709 — Острова VPN Settings → Core: WireGuard, MTU, QUIC (ядро SPEC 151, SPEC 120)

| Field | Value |
|-------|-------|
| Status | In progress |
| Start date | 2026-11-02 |
| End date | — |
| Commits | `0a571cd1` (тумблер на System), `ed385e8b` (острова), `ce61fd32` (decoy по умолчанию), итер. 2 — следующий |
| Related specs | ядро sing-box-lx SPEC 151 (`lx.quic_sniff_decoy`), §542 (образец: тумблер `lx.wg.lazy_build`), §215 (корневой блок `lx`) |

## Problem

Релей со сниффингом UDP (Xray `sniffing` + `destOverride: ["quic"]` без
`routeOnly`) подменяет назначение QUIC-потока именем из SNI: MASQUE h3 попадает
на чужой ключ WARP, Hysteria2 и TUIC уходят на хост из SNI. Ядро
`v1.14.4-lx.30-rc.3` (SPEC 151) лечит это однобайтовой обманкой `0x00` перед
первым Initial; включается ключом `"lx": { "quic_sniff_decoy": true }`, без
ключа выключено. У пользователя включить его негде.

## Solution

Решения владельца 02.11.2026: настройки блока `lx` — на вкладке Core, все
секции вкладки островами (как карточки экрана Backup), у каждой lx-настройки
значок (i) с короткой подсказкой по нажатию, без перехода; MTU — всеми тремя
режимами.

- Core: острова General / Network / TUN / TLS Fragmentation (секции шаблона,
  `TemplateVarListView(islands: true)`), затем WireGuard и QUIC.
- **WireGuard** — четыре настройки §215/§272/§542 переехали с System без
  изменений логики (ключи хранилища, бэкап, правила неактивности те же).
- **MTU** — последним в острове Network (`sectionTrailing`): «Align MTU to
  the path» — Clamp (default) / Fill / Off, подпись по выбранному режиму.
  Настройка `mtu_align` (string, дефолт `clamp`, чужое значение = дефолт),
  в LX Backup. `clamp` в конфиг не пишется (дефолт ядра, конфиг прежний байт
  в байт), `fill`/`off` → `lx.mtu_align` строкой. Ключ в ядре с lx.14 —
  гейта нет. `except` в UI не выносится.
- **QUIC** — «Anti-sniff decoy», настройка `quic_sniff_decoy` (bool, дефолт
  `true` — решение владельца 02.11.2026, у ядра без ключа выключено; у
  существующих установок без ключа тоже включается), в LX Backup. При `true` и ядре не старше
  `1.14.4-lx.30-rc.3` → `lx.quic_sniff_decoy: true`, иначе ключ не пишется
  (ядро отвергло бы неизвестное поле блока `lx`).
- System: остался остров Optimization (лимит памяти, фоновый режим).
- Не вынесены (сознательно): `lx.wg.idle_teardown`, `lx.wg.build_overflow`
  (дефолт ядра `wait`), `lx.masque.idle_timeout` (у узлов WARP свой),
  `lx.trusttunnel.idle_timeout`, `lx.mtu_align.except`.

## Files

- `app/lib/services/settings_storage/network.dart`, `settings_storage.dart` — геттер/сеттер, ключ в allowlist
- `app/lib/services/backup_service.dart` — ключ в бэкапе
- `app/lib/services/builder/build_config.dart`, `direction_pool_preview.dart` — поле `BuildSettings.quicSniffDecoy`, эмиссия
- `app/lib/screens/settings_screen.dart` — острова, перенос WireGuard, MTU, QUIC
- `app/lib/widgets/template_var_list.dart` — `islands`, `sectionTrailing`, `SettingsIsland`, `LxHintButton`
- `app/assets/l10n/{ru,zh}/ui.json` — строки
- `docs/STORAGE.md` — ключ
- `app/test/builder/build_config_test.dart` — тест эмиссии «§709» (decoy + mtu_align)

## Verification

- Тест: ключ есть при `true` и ядре rc.3, нет при `false`, нет на ядре rc.2;
  сосуществует с `lx.wg`.
- Тест: `mtu_align` clamp не пишется, fill/off пишутся строкой рядом с decoy.
- Эмулятор: острова на Core, (i) показывает подсказку; тумблер и режим MTU
  попадают в итоговый конфиг, ядро стартует.

## Итерация 2 — ключи `lx` на переменных шаблона

Решение владельца 02.11.2026: шесть настроек блока `lx` — переменные
шаблона, как TLS Fragmentation (объявлены в `wizard_template.json`, значение
в `vars`, применяет код сборки). Миграции нет: значения старых ключей
хранилища теряются, переменные начинают с дефолтов шаблона.

| Переменная | Секция | Тип, значения | Дефолт | В конфиг |
|---|---|---|---|---|
| `mtu_align` | Network | enum `clamp` / `fill` / `off` | `clamp` | `lx.mtu_align`, кроме `clamp` |
| `wg_idle_suspend` | WireGuard (новая) | enum `off` / `30s` / `2m` / `5m` | `30s` | `lx.wg.idle_suspend`, кроме `off` |
| `wg_idle_suspend_reachable` | WireGuard | enum `off` / `5m` / `15m` / `30m` / `1h` | `5m` | `lx.wg.idle_suspend_reachable`, только при сне |
| `wg_lazy_build` | WireGuard | bool | `true` | `lx.wg.lazy_build`, только при сне |
| `wg_build_max` | WireGuard | enum `0` / `3` / `5` / `8` / `12` | `5` | `lx.wg.build_max` (int), только при lazy |
| `quic_sniff_decoy` | QUIC (новая) | bool | `true` | `lx.quic_sniff_decoy: true`, ядро ≥ lx.30-rc.3 |

- `off` вместо пустой строки: язык шаблона отбрасывает пустые `options`.
- Зависимости и гейт ядра — в коде сборки (в языке шаблона их нет), как
  было; неуместная комбинация в конфиг не пишется.
- UI: секции WireGuard и QUIC — острова из шаблона после TLS Fragmentation.
  Приложение передаёт `TemplateVarListView` подсказки (i) по имени
  переменной и условия неактивности (reachable и lazy — при сне `off`,
  build_max — при выключенном lazy). Это параметры виджета, не поле языка
  шаблона: контракт с лаунчером не меняется.
- Снимаются ключи хранилища `route_idle_suspend`,
  `route_idle_suspend_reachable`, `wg_build_max`, `wg_lazy_build`,
  `mtu_align`, `quic_sniff_decoy`, их геттеры, поля `BuildSettings` и
  записи в allowlist / бэкапе. Значения едут в бэкапе общим `vars`.
- Реестр контракта (`vars.json`) не трогается: переменные мобильные, в LX
  Backup не переносимы (как раньше ключи хранилища).

## Итерация 3 — `lx` пишет `config` шаблона (контракт 1.1.151, §147)

Решения владельца через лаунчер (TASKS_LXBOX §147): «что можно настроить
шаблоном — настраивается шаблоном».

- Блок `lx` — в `config` шаблона map-spread `#if` по каждой ветке
  (`wg` с вложенными `reachable` / `lazy`, `mtu_align`, `quic_sniff_decoy`,
  `masque_idle_timeout`); ключ только при значении, отличном от дефолта
  ядра. Код сборки `buildLxBlock` снят; пустой `lx` сборка снимает, чтобы
  конфиг без lx-настроек не менялся.
- Гейта версии ядра нет: пин обеих сторон не ниже `1.14.4-lx.30-rc.3`
  (`af989ee9`).
- `wg_build_max` — `int` с `options` (ядро ждёт целое).
- Седьмая переменная `masque_idle_timeout` (секция QUIC): enum `off` / `2m`
  / `5m` / `15m` / `30m`, дефолт `off` → `lx.masque.idle_timeout`; ключ узла
  сильнее.
- Реестр `vars.json` 1.1.151: `mtu_align`, `quic_sniff_decoy`,
  `masque_idle_timeout` — `in: both`; четыре `wg_*` — `in: mobile`; все
  `portable: false`.
- Тест — `app/test/builder/lx_block_template_test.dart` (фрагмент `lx`
  настоящего шаблона и `#enable` объявлений).

## Итерация 4 — режим обманки и стабильное ядро (контракт 1.1.152, §148)

Ядро `v1.14.4-lx.30`: `lx.quic_sniff_decoy` — режим `off` / `detour` /
`direct` / `all` (`true` / `false` из rc.3 — алиасы `all` / `off`). Владелец
ядра: DPI собственного аплинка может среагировать на лишний байт, поэтому
по умолчанию обманка только у соединений поверх другого узла.

- `quic_sniff_decoy` — enum, options `Off` / `Through detour (default)` /
  `Direct` / `All`, дефолт `detour`.
- Эмиссия `"#if quic_sniff_decoy": [{"@quic_sniff_decoy": {"#in": ["detour",
  "direct", "all"]}}, {"quic_sniff_decoy": "@quic_sniff_decoy"}]`: значение
  `true` / `false`, оставшееся в хранилище после сборки с rc.3, ключа не
  даёт (строку `"true"` ядро отвергло бы). Миграции нет.
- Пин `v1.14.4-lx.30` (javap и теги совпадают с rc.3, sha256 в
  `docs/KERNEL.md`). Ядро удалило алиасы `route.lx_idle_*`; LxBox их не
  пишет (поиск по `app/lib`, `app/assets`, `app/test`, натив — пусто).
- Подсказка (i) говорит про DPI своего канала.
- Тест — тот же `lx_block_template_test.dart`: дефолт `detour`, режимы
  строкой, `off` / `true` / `false` без ключа.
