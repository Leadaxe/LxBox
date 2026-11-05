# 720 — Настройка AWG masquerade на вкладке Core (ядро SPEC 153)

| Field | Value |
|-------|-------|
| Status | In progress |
| Start date | 2026-11-05 |
| Source | решение владельца 05.11.2026: настройка — в секции WireGuard вкладки Core; в описание `quic_sniff_decoy` дописать AWG (ip=quic) |
| Related specs | ядро sing-box-lx SPEC 153 (issue sing-box-lx#64), §709 (острова Core, переменные корневого `lx`), контракт 1.1.151 (ключи `lx` — переменные шаблона) |

## Problem

Ядро `v1.14.4-lx.31` получило корневой ключ `lx.awg_masquerade`: `direct`
(дефолт, отсутствие ключа) — маскировочная пачка AWG (`ip=quic`, `i1`…) уходит
только когда endpoint звонит с сокета устройства, через `detour` идёт одна
инициация рукопожатия; `all` — пачка на любом пути, как было до lx.31.
LxBox ключ не пишет, включить `all` можно только руками через Mixins.

Вторая часть: `lx.quic_sniff_decoy` с lx.31 действует и на пачку AWG с
`ip=quic`, а тексты настройки «Anti-sniff decoy» и секции QUIC называют только
MASQUE, Hysteria2 и TUIC.

## Solution

- Переменная шаблона `awg_masquerade` в секции `wireguard` (глава `core`),
  последней после `wg_build_max`: enum, дефолт `direct`, варианты
  «Direct only (default)» = `direct`, «All paths» = `all`. Условия `#enable`
  нет: ключ не зависит от сна WireGuard.
- Эмиссия — через `config.lx` шаблона (норма 1.1.151, не кодом сборки):
  `"#if awg_masquerade": [{"@awg_masquerade": "all"}, {"awg_masquerade": "all"}]`.
  При `direct` и при любом чужом значении ключа нет — конфиг по умолчанию
  прежний байт в байт, блок `lx` у ядра строгий.
- Гейта по версии ядра нет: пин `v1.14.4-lx.31`, ключ в нём есть.
- На узел настройка не выносится: ключ ядра глобальный.
- Подсказка (i) в `_lxVarHints`; ключ `awg_masquerade` в `_configVarKeys`
  хранилища (значение живёт там же, где остальные переменные шаблона).
- Тексты decoy: тултип переменной `quic_sniff_decoy`, подсказка (i) и описание
  секции QUIC дополнены словами про AWG с маскировкой под QUIC (`ip=quic`).
- Контракт: запись `awg_masquerade` в `registry/vars.json` (`enum`,
  `portable: false`) — запрос лаунчеру, `contract/TASKS_LXBOX.md` §159.

## Files

- `app/assets/wizard_template.json` — переменная, ветка `#if` в `config.lx`, тексты decoy и секции QUIC
- `app/lib/screens/settings_screen.dart` — подсказки (i)
- `app/lib/services/settings_storage.dart` — ключ в `_configVarKeys`
- `app/assets/l10n/{ru,zh}/{template,ui}.json` — строки
- `app/test/builder/lx_block_template_test.dart` — тест эмиссии
- `docs/KERNEL.md`, `CHANGELOG.md`

## Verification

- Тест `lx_block_template_test.dart` «720»: при дефолте и `direct` ключа нет,
  при `all` — `lx.awg_masquerade: "all"`, чужое значение ключа не даёт.
- Не проверено: вид настройки на эмуляторе; поведение ядра с `all` через
  detour на живом AWG-узле.
