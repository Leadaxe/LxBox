# Параметры REALITY

| Поле | Значение |
|------|----------|
| Фича | [016-DPI_HARDENING](../FEATURE.md) |
| Обещания | P9 (P6, P8 — смежные) |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Строит блок `tls.reality` узла из ссылки (`security=reality`, `pbk`,
`sid`, `key_share`), Xray-JSON (`realitySettings`) или sing-box JSON и
следит, чтобы битое значение одного узла подписки не превратилось в
отказ ядра на весь конфиг. Ядро декодирует `public_key` как X25519, а
`short_id` — как hex в 8 байт, и падает на старте при любом отклонении.

## Параметры

| Параметр ссылки | Ключ ядра | Норма |
|---|---|---|
| `pbk` | `tls.reality.public_key` | base64/base64url, с паддингом или без, ровно 32 байта; в конфиг — форма ядра (RawURL) |
| `sid` | `tls.reality.short_id` | hex, чётная длина, ≤ 16 символов; пустой законен |
| `key_share` | `tls.reality.key_share` | `""` (как несёт отпечаток) · `hybrid` · `classical`; ядро ≥ `v1.14.1-lx.4` |

## Входы / Выходы

**Входы:** ссылки VLESS и AnyTLS (REALITY по ссылке у trojan/http не
разбирается), Xray `realitySettings`, sing-box `tls.reality`.
**Выходы:** `tls.reality{enabled, public_key, short_id?, key_share?}`
(пустые `short_id`/`key_share` не пишутся); коды на узле; строки сборки
«REALITY short_id cleared: outbound "…" had invalid hex "…" — kernel would
reject the whole config.» и «REALITY removed: outbound "…" had invalid
public_key "…" — node degraded to plain TLS.»

## Правила и инварианты

- REALITY строится по валидному ключу, а не по «`pbk` непустой»: мусор
  (`enabled`, `true`, пусто, не 32 байта) → блока нет, узел идёт обычным
  TLS (кейс кривых публичных подписок с `pbk` на `security=tls`).
- `short_id` на разборе: регистр понижается, символы вне hex
  вычищаются; итог нечётной длины или длиннее 16 → пустой, узел жив.
  Обрезка до 16 не делается: получился бы чужой идентификатор.
- `key_share`: регистр и пробелы нормализуются; вне enum → поле снято
  молча, узел жив; без валидного `pbk` параметр игнорируется;
  круг «ссылка → узел → ссылка» его сохраняет.
- Перед ядром — страховка для путей мимо разбора (JSON, правила импорта,
  подстановки): невалидный `public_key` → блок `reality` снят целиком;
  `short_id` нечётный/не-hex/>16/не строка → `""`. Проверка строгая,
  без подгонки. Выключенный блок (`enabled: false`) не проверяется.
- REALITY и `tls.ech.enabled`, REALITY и `tls.spoof` — конфликт, одно
  из полей снимается реестром.
- REALITY на QUIC (hysteria2/tuic) не бывает: блок снимается.
- SNI REALITY-узла не рандомизируется (см. [mixed-case-sni.md](mixed-case-sni.md));
  отпечаток и гибридный key share — [utls-fingerprint.md](utls-fingerprint.md).
- Фрагментация действует на REALITY с ядра `v1.14.1-lx.4`.

## Границы

- Установление REALITY-рукопожатия, версия клиента для `minClientVer`,
  сам гибридный key share — ядро (ядро: FEATURE 017-REALITY).
- Отдельного выбора `key_share` в настройках приложения нет: значение
  приходит из ссылки/JSON или правится в JSON узла.
- Деградация до обычного TLS означает, что узел, скорее всего, не
  поднимется (сервер ждёт REALITY), но остальной конфиг работает.

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [169](../../../tasks/169-reality-pbk-validation.md) | Реализовано (device-verified) | REALITY только по валидному X25519-ключу |
| 2 | [343](../../../tasks/343-reality-short-id-validation.md) | Released v2.19.2 | Битый `short_id` отбрасывается целиком, страховка перед ядром |
| 3 | [457](../../../tasks/457-kernel-lx4-reality-key-share.md) | Выпущено v2.24.3 | `tls.reality.key_share` (hybrid · classical) |
| 4 | [459](../../../tasks/459-guards-contract-24-2.md) | Released v2.25.0 | Регистр `key_share` нормализуется |
| 5 | [556](../../../tasks/556-registry-debt-1157-1170.md) | Частично сделано | REALITY без uTLS чинит правило реестра |
