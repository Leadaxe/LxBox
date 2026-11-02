# 709 — Тумблер «QUIC sniff decoy» в VPN Settings (ядро SPEC 151)

| Field | Value |
|-------|-------|
| Status | In progress |
| Start date | 2026-11-02 |
| End date | — |
| Commits | — |
| Related specs | ядро sing-box-lx SPEC 151 (`lx.quic_sniff_decoy`), §542 (образец: тумблер `lx.wg.lazy_build`), §215 (корневой блок `lx`) |

## Problem

Релей со сниффингом UDP (Xray `sniffing` + `destOverride: ["quic"]` без
`routeOnly`) подменяет назначение QUIC-потока именем из SNI: MASQUE h3 попадает
на чужой ключ WARP, Hysteria2 и TUIC уходят на хост из SNI. Ядро
`v1.14.4-lx.30-rc.3` (SPEC 151) лечит это однобайтовой обманкой `0x00` перед
первым Initial; включается ключом `"lx": { "quic_sniff_decoy": true }`, без
ключа выключено. У пользователя включить его негде.

## Solution

- Настройка `quic_sniff_decoy` (bool, по умолчанию `false` — как в ядре) в
  `lxbox_settings.json`; запись помечает конфиг грязным (как §542). Ключ едет в
  LX Backup.
- VPN Settings → System: секция «QUIC connections» с тумблером
  «Anti-sniff decoy», после секции WireGuard. Тумблер не зависит от сна
  туннелей (в отличие от «Lazy tunnel build»).
- Сборка: при `true` пишется `lx.quic_sniff_decoy: true` рядом с `lx.wg`
  (блок `lx` создаётся, если его нет). При `false` ключ не пишется. На ядре
  старше `1.14.4-lx.30-rc.3` ключ не пишется (ядро отвергло бы неизвестное
  поле блока `lx`).

## Files

- `app/lib/services/settings_storage/network.dart`, `settings_storage.dart` — геттер/сеттер, ключ в allowlist
- `app/lib/services/backup_service.dart` — ключ в бэкапе
- `app/lib/services/builder/build_config.dart`, `direction_pool_preview.dart` — поле `BuildSettings.quicSniffDecoy`, эмиссия
- `app/lib/screens/settings_screen.dart` — тумблер
- `app/assets/l10n/{ru,zh}/ui.json` — строки
- `docs/STORAGE.md` — ключ
- `app/test/builder/build_config_test.dart` — тест эмиссии «§709»

## Verification

- Тест: ключ есть при `true` и ядре rc.3, нет при `false`, нет на ядре rc.2;
  сосуществует с `lx.wg`.
- Эмулятор: тумблер включается, в итоговом конфиге `lx.quic_sniff_decoy: true`,
  ядро стартует.
