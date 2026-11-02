# 709 — Острова VPN Settings → Core: WireGuard, MTU, QUIC (ядро SPEC 151, SPEC 120)

| Field | Value |
|-------|-------|
| Status | In progress |
| Start date | 2026-11-02 |
| End date | — |
| Commits | `0a571cd1` (тумблер на System), острова — следующий |
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
