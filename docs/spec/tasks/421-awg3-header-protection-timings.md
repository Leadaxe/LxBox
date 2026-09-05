# 421 — AmneziaWG 3.0/3.1: защита заголовка, паддинг, хвосты, тайминги

| Field | Value |
|------|----------|
| Status | Implemented, device-verified (AVD, 05.09.2026: экспорт владельца AWG 3.1 → `WG·awg3.1` → handshake → `1.1.1.1/cdn-cgi/trace` ip=77.239.123.44; MTU 1200 через `last_config.mtu`/`[Interface]`) |
| Started | 2026-09-05 |
| Trigger | Amnezia экспортирует AWG 3.x серверы контейнером `amnezia-awg2` с `awg.protocol_version: "3.1"`. В `.conf` кроме AWG2-набора стоят `HeaderProtectionKey`, `ContentPaddingAddition`, `RekeyAfterTime`, `RekeyTimeout`, `RejectAfterTime`, `KeepaliveTimeout`, `MaxHandshakeAttempts`, `RandomTrailers`, `DisableCookies`, а `[Peer] PersistentKeepalive` — диапазон `25-35`. Сегодня `_iniToUri` их выбрасывает молча, `int.tryParse('25-35')` роняет keepalive, MTU клампится до 1280 — узел выглядит настроенным, а хендшейк с сервером, шифрующим заголовок, не пройдёт никогда. |
| Related | [§097](../features/097%20awg2-amneziawg2/spec.md) (модель `Awg`, эмит/парс); [§112](112-awg-ranged-magic-headers.md) (ranged h1–h4); [§148](148-awg-version-labels.md) (лейблы уровня); контракт лаунчера `contract/` — SPEC 123 лаунчера (`SPECS/123-F-N-AWG3/SPEC.md`), корпус `contract/corpus/uri/wireguard/{awg3_full_params,amnezia_vpn_awg3,awg3_header_key_short_dropped}.*` |
| Core | sing-box-lx `v1.14.0-lx.33`: `libbox-1.14.0-lx.33.aar` (lx.32 — первое ядро с полями AWG3, lx.33 чинит приём data-пакетов при `random_trailers`). Ядро ≤ lx.31 отвергает конфиг с любым AWG3-ключом целиком. Справочник полей: `sing-box-lx/docs-lx/lx-protocols-transports.ru.md` §2.1, §2.7, §2.9, §2.10 |

## Контракт (источник истины — репозиторий лаунчера, `contract/`)

Синхронизировать копию: `bash app/tool/sync_contract.sh`. Реестр
`registry/containers.json` (wireguard-ini, optional-ключи) и
`registry/warnings.json` (`awg3_field_invalid`, `awg3_header_key_invalid`,
`awg3_padding_too_short`, `awg3_random_trailers_wide_headers`,
`awg3_core_unsupported`) уже обновлены лаунчером; `registry_sync_test.dart`
покажет, чего не хватает в Dart.

### Имена и формы (обе стороны)

URI-параметр = ключ `.conf` в нижнем регистре (как `jc`, `presharedkey`).
JSON-ключ = опция ядра на **корне** endpoint `wireguard`, рядом с `jc`/`s1`/`h1`.

| `.conf` / URI-параметр | JSON | Форма |
|---|---|---|
| `HeaderProtectionKey` / `headerprotectionkey` | `header_protection_key` | base64 32 байта, дословно |
| `ContentPaddingAddition` / `contentpaddingaddition` | `content_padding_addition` | `N` → число, `N-M` → строка `"N-M"` |
| `RekeyAfterTime` / `rekeyaftertime` | `rekey_after_time` | то же |
| `RekeyTimeout` / `rekeytimeout` | `rekey_timeout` | то же |
| `RejectAfterTime` / `rejectaftertime` | `reject_after_time` | то же |
| `KeepaliveTimeout` / `keepalivetimeout` | `keepalive_timeout` | то же |
| `MaxHandshakeAttempts` / `maxhandshakeattempts` | `max_handshake_attempts` | то же |
| `RandomTrailers` / `randomtrailers` | `random_trailers` | `on`/`true`/`1` → `true`; `off`/пусто → ключа нет (никогда `false`) |
| `DisableCookies` / `disablecookies` | `disable_cookies` | то же |
| `[Peer] PersistentKeepalive` / `keepalive` | `peers[0].persistent_keepalive_interval` | `N` → число, `N-M` → строка `"N-M"` |
| `MTU` (в экспорте AWG3 лежит **не** в `[Interface]`, а рядом в JSON `last_config.mtu`, строкой `"1376"`) | `mtu` | число; кламп `awgClampMtu` до 1280 действует и для AWG3 (решение владельца 2026-09-05: на 1376 данные не шли) |

`H1–H4 = 1..4` в экспортах AWG3 нормальны (при защите заголовка слово типа
замаскировано) — не «чинить». Остальные ключи — как AWG2.

### Политика ошибок (эталон Go, SPEC 123 §2)

- диапазон/булево с мусором или `N > M` → **поле снято**, узел живёт, код
  `awg3_field_invalid` (params `field`, `value`). Границы **не** свопать (в
  отличие от h1–h4): тайминги клиентские, а перевёрнутый диапазон — опечатка,
  которую человек должен увидеть.
- `header_protection_key` не base64 / не 32 байта / все нули → **узел
  выброшен**, код `awg3_header_key_invalid` (без ключа хендшейк невозможен,
  ядро отвергает конфиг целиком).
- `header_protection_key` задан и хоть один из `s1`–`s4` < 12 (или не задан)
  → узел выброшен, код `awg3_padding_too_short` (params `field`, `min`=12).
- `random_trailers: true` при диапазонном `h1`–`h4` с шириной ≥ 65536 →
  info-код `awg3_random_trailers_wide_headers`, ничего не снимать.
- Кламп MTU (`awgClampMtu`) действует и для AWG3-узлов — как для AWG2.
  AWG3-маркер (любой AWG3-ключ на корне или диапазонный keepalive у пира)
  сам по себе делает узел AmneziaWG, даже без AWG2-полей.

### Лейбл (§148, структурно, без хранения версии)

`awg3.1` — есть `random_trailers` или `disable_cookies`; `awg3` — любой другой
AWG3-ключ или диапазонный keepalive; оба **старше** `awg2` в приоритете;
суффикс `+` при masquerade как сейчас. `_variantOrder`/`_variantRank` —
добавить `awg3`, `awg3.1` после `awg2`.

## Что менять (ловушки файл:строка)

1. **Пин ядра** — `app/android/libbox.version`: `v1.14.0-lx.30` → `v1.14.0-lx.33`;
   `scripts/fetch-libbox.sh` подтянет AAR и проверит SHA256SUMS. Гейт
   «обновите ядро» LxBox не нужен: ядро едет в APK.
2. **`lib/models/node_spec.dart` `class Awg` (:646)** — таблицы `numKeys`/
   `strKeys` знают только AWG2. Добавить `awg3RangeKeys` (6 таймингов/паддинг:
   `int | String`), `awg3BoolKeys` (2: `bool`), `headerKey`
   (`header_protection_key`: `String`). Обновить `fromQuery` (:~700; ловушка —
   `+` в base64 ключа защиты: query-декодер не должен превращать его в пробел,
   см. как читаются `publickey`/`presharedkey` в `wireguard_parser.dart`),
   `fromJson`/`writeInto`/`writeQuery` (эмиттер и парсер ходят парой — схема
   без emit-ветки молча урезается). Булевы в query — `on`; в JSON — `true`
   только при включении.
3. **`lib/services/parser/ini_parser.dart` `_iniToUri` (:34)** — прокинуть
   AWG3-ключи `[Interface]` в params по тем же именам; `persistentkeepalive`
   (:74) принимать `N-M` строкой, а не `int.tryParse`; `mtu` (:63) — как
   сейчас.
4. **`lib/services/parser/uri_parsers/wireguard_parser.dart`** — `keepalive`
   (:70) `N-M` → строка в `persistentKeepalive` (тип поля пира расширить до
   `Object?`/`int | String`; эмиттер `node_spec_emit.dart:615,646` пишет
   как есть); кламп (:98) применять и при AWG3-маркерах (узел без AWG2-полей, но с AWG3 — тоже AWG).
5. **`lib/services/parser/amnezia_link.dart`** — `_extractIni` (:168)
   возвращает только `config`; нужен и `last_config.mtu`: если в
   `[Interface]` нет `MTU`, дописать строку `MTU = N` в INI до `_iniToUri`
   (текст, не params — одна точка конвертации). `_substituteDns` (:188) уже
   есть — не трогать.
6. **`lib/models/config_node.dart` `_deriveSecurity` (:115)** и
   `screens/home/node_list_presenter.dart` (`_variantOrder`/`_variantRank`)
   — по разделу «Лейбл».
7. **Warnings** — классы для пяти кодов в `lib/models/node_warning.dart`
   по образцу `AwgHeaderInvalidWarning`; `registry_sync_test.dart` покажет
   ожидаемые имена/params. `awg3_core_unsupported` в Dart — только запись
   реестра (ядро в AAR, деградации нет) — `dart: null` допустим, проверить,
   как sync-тест трактует такие коды.
8. **Обратный экспорт** — `writeQuery` (share-URI) и любой экспорт в
   `.conf`, если он есть (`grep -rn "\[Interface\]" lib/`): `true` → `on`.
9. **`docs/PROTOCOLS.md`** — таблица параметров wireguard:// и лейблы.

## Тесты

Корпус контракта — источник истины: после `sync_contract.sh` `contract_test.dart`
обязан пройти на `awg3_full_params`, `amnezia_vpn_awg3` (ожидаемо: `mtu: 1280` — 1376 из `last_config` клампится,
keepalive `"25-35"`, диапазоны строками, булевы `true`, DNS-плейсхолдеров
нет) и `awg3_header_key_short_dropped` (узел выброшен). Старые AWG2-expected
(`amnezia_vpn_awg`, `awg_mtu_clamped_1280`, `awg_full_params`) — без
изменений. Дополнительно: один end-to-end в `test/parser/amnezia_link_test.dart`
(фикстура по структуре экспорта: контейнер `amnezia-awg2`,
`awg.protocol_version "3.1"`, `last_config` с `mtu`, `DNS = $PRIMARY_DNS, $SECONDARY_DNS`)
и таблица негативов + round-trip `writeQuery → fromQuery` в
`test/parser/awg_test.dart`; лейблы — в `test/models/config_node_test.dart`.
Ключи в фикстурах синтетические (32 байта, не нули).

## Приёмка

- Импорт экспорта владельца (`amnezia_config_seliv.vpn`, AWG 3.1) → нода
  с лейблом `awg3.1` → соединение → `api.ipify.org` показывает
  `77.239.123.44`, `example.com` открывается. Google через этот сервер не
  отвечает — сторона сервера, не критерий.
- AWG2-профиль и обычный WireGuard работают как раньше.
- `flutter analyze` без новых issues, `flutter test` зелёный целиком.
