# 720 — Настройка AWG masquerade на вкладке Core (ядро SPEC 153)

| Field | Value |
|-------|-------|
| Status | Released (v2.25.20) |
| Start date | 2026-11-05 |
| Source | решение владельца 05.11.2026: настройка — в секции WireGuard вкладки Core; в описание `quic_sniff_decoy` дописать AWG (ip=quic) |
| Related specs | ядро sing-box-lx SPEC 153 (issue sing-box-lx#64), §709 (острова Core, переменные корневого `lx`), контракт 1.1.151 (ключи `lx` — переменные шаблона) |

## Problem

Ядро `v1.14.4-lx.31` получило корневой ключ `lx.awg_masquerade`: `direct`
(дефолт, отсутствие ключа) — маскировочная пачка AWG (`ip=quic`, `i1`…) уходит
только когда endpoint звонит с сокета устройства, через `detour` идёт одна
инициация рукопожатия; `all` — пачка на любом пути, как было до lx.31.
LxBox ключ не пишет, включить `all` можно только руками через Mixins.

Ядро `v1.14.4-lx.32` (решение владельца 05.11.2026) перевернуло дефолт: нет
ключа = `all`. Значения прежние. Настройка и пин ядра едут вместе.

Вторая часть: `lx.quic_sniff_decoy` с lx.31 действует и на пачку AWG с
`ip=quic`, а тексты настройки «Anti-sniff decoy» и секции QUIC называют только
MASQUE, Hysteria2 и TUIC.

## Solution

- Переменная шаблона `awg_masquerade` в секции `wireguard` (глава `core`),
  последней после `wg_build_max`: enum, дефолт `all` (дефолт ядра lx.32),
  варианты «All paths (default)» = `all`, «Direct only» = `direct`. Условия `#enable`
  нет: ключ не зависит от сна WireGuard.
- Эмиссия — через `config.lx` шаблона (норма 1.1.151, не кодом сборки):
  `"#if awg_masquerade": [{"@awg_masquerade": "direct"}, {"awg_masquerade": "direct"}]`.
  При `all` и при любом чужом значении ключа нет — конфиг по умолчанию
  прежний байт в байт, блок `lx` у ядра строгий.
- Гейта по версии ядра нет: пин поднят до `v1.14.4-lx.32` тем же коммитом
  (`libbox.version`, `kCoreBuildTagsPin`); на lx.31 схема дала бы обратное
  поведение.
- Поведение относительно 2.25.19 (ядро lx.31, ключа нет = `direct`) меняется:
  AWG через detour снова шлёт пачку; от подмены по SNI её прикрывает
  `quic_sniff_decoy` (дефолт `detour`).
- На узел настройка не выносится: ключ ядра глобальный.
- Подсказка (i) в `_lxVarHints`; ключ `awg_masquerade` в `_configVarKeys`
  хранилища (значение живёт там же, где остальные переменные шаблона).
- Тексты decoy: тултип переменной `quic_sniff_decoy`, подсказка (i) и описание
  секции QUIC дополнены словами про AWG с маскировкой под QUIC (`ip=quic`).
- Контракт 1.1.162 (лаунчер `8d13b511`, синк `3144f21e`, `TASKS_LXBOX` §159 →
  §160): `awg_masquerade` в `registry/vars.json` — `enum`, options `all` /
  `direct`, дефолт `all`, `portable: false`, `in: mobile` (пин лаунчера lx.30,
  переменную он не берёт).

## Files

- `app/assets/wizard_template.json` — переменная, ветка `#if` в `config.lx`, тексты decoy и секции QUIC
- `app/lib/screens/settings_screen.dart` — подсказки (i)
- `app/lib/services/settings_storage.dart` — ключ в `_configVarKeys`
- `app/assets/l10n/{ru,zh}/{template,ui}.json` — строки
- `app/test/builder/lx_block_template_test.dart` — тест эмиссии
- `app/android/libbox.version`, `app/lib/services/builder/core_chain_capability.dart` — пин ядра lx.32
- `docs/KERNEL.md`, `CHANGELOG.md`

## Verification

- Тест `lx_block_template_test.dart` «720»: при дефолте и `all` ключа нет,
  при `direct` — `lx.awg_masquerade: "direct"`, чужое значение ключа не даёт.
- Не проверено: вид настройки на эмуляторе; поведение ядра с `all` через
  detour на живом AWG-узле.
