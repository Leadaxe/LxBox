# 304 — Persistent keepalive для ручной регистрации WARP

## Проблема

WARP-узлы работают поверх WireGuard/UDP. Ядро sing-box-lx **не подставляет
дефолтный keepalive**: если в конфиге пира нет `persistent_keepalive_interval`,
пир идёт вообще без keepalive (`transport/wireguard/endpoint.go:524` — строка
пишется только при `keepalive > 0`).

Ручная регистрация WARP (`WarpAccount.toWireguardConf` / `toWireguardUri`)
keepalive **не проставляет** вообще — ни в `[Peer]` INI, ни в query URI. Итог:
при длительном простое (нет трафика через узел) —

1. нет исходящих пакетов → NAT-маппинг оператора/роутера закрывается за 30–120с;
2. входящий трафик от WARP не доходит → пинг растёт → `err`;
3. через `RejectAfterTime*3` (=540с) ключи WG обнуляются.

Пользователь наблюдает: пинг WARP-эндпоинтов постепенно деградирует при простое
до `err` на всех, соединение отваливается, лечится только «Rebuild + reconnect»
(пересоздаёт сокет → свежий NAT-маппинг + хендшейк).

`persistent_keepalive_interval=25` (типовое значение WARP) держит NAT-маппинг
открытым и сессию свежей — деградации при простое не будет.

## Решение

Добавить в **Advanced-секцию ручной регистрации WARP** (визард `warp_wizard_screen`)
поле «Persistent keepalive» (секунды), дефолт **25**. Значение прокидывается в
конфиг создаваемого узла — и для plain WG, и для AWG-ветки.

**Границы:**
- Только **ручная регистрация**. Генератор (§284 WARP GENERATOR,
  `scan_node_builder.dart`) **не затрагивается** — он вызывает `toWireguardConf`
  без нового параметра, дефолт параметра `null` → keepalive не добавляется.
- **MASQUE не трогаем** — у него свой QUIC-keepalive (`keep_alive_period`,
  `masque_account.dart`), это другое поле/ключ ядра.
- Инфраструктура keepalive уже сквозная: `WireguardPeer.persistentKeepalive`
  (`node_spec.dart:665`), эмит JSON `persistent_keepalive_interval`
  (`node_spec_emit.dart:564-565`), эмит URI `keepalive` (`node_spec_emit.dart:595-596`),
  парс INI (`ini_parser.dart:68,113`) и URI (`wireguard_parser.dart:46,58`).
  Новую трубу строить не нужно — только пробросить значение из UI в генераторы
  `WarpAccount`.

## Взаимодействие с idle-suspend (§215)

Keepalive **не мешает** idle-suspend усыпить узел ради экономии RAM: решение
«заснуть» принимается по гейтам активных TCP-флоу и порогу дельты трафика 4096б
(`protocol/wireguard/endpoint.go:283,291`), а keepalive-пакеты крохотные и в
порог не попадают. Слои независимы: keepalive держит живым сетевой путь
(NAT + сессия), idle-suspend освобождает память. Конфликта нет.

## Изменения

### 1. `WarpAccount` (`app/lib/services/warp/warp_account.dart`)

Добавить в оба генератора конфига опциональный параметр
`int? persistentKeepalive` (дефолт `null` = не писать keepalive, поведение как
сейчас — важно для генератора):

- `toWireguardConf({bool includeReserved = true, int? persistentKeepalive})` —
  в `[Peer]`-секцию добавить `PersistentKeepalive = <N>` при `N != null && N > 0`.
  Парсер `ini_parser.dart:68` подхватит автоматически.
- `toWireguardUri({bool includeReserved = true, int? persistentKeepalive})` —
  в query-map добавить `'keepalive': '<N>'` при `N != null && N > 0`.

Гейт `> 0`: значение `0`/пусто = keepalive выключен (не пишем строку), это
осознанный способ вернуть старое поведение.

### 2. `SubscriptionController.addWarp` (`subscription_controller.dart:282`)

Добавить параметр `int? persistentKeepalive` (дефолт `null`). Прокинуть в
`_addWarpObfuscated` и `_addWarpPlain`:

- `_addWarpObfuscated(account, tag, includeReserved, {int? persistentKeepalive})`
  → `account.toWireguardConf(includeReserved:, persistentKeepalive:)`.
- `_addWarpPlain(account, tag, includeReserved, {int? persistentKeepalive})`
  → `account.toWireguardUri(includeReserved:, persistentKeepalive:)`.

### 3. UI (`app/lib/screens/warp_wizard_screen.dart`)

- Новый контроллер `_keepalive = TextEditingController(text: '25')`, dispose в
  `dispose()`.
- Поле в Advanced-секции (`ExpansionPanelRadio`, ~строки 622-845) рядом с
  jc/jmin/jmax: `TextField` label «Persistent keepalive (s)», numeric,
  плейсхолдер/дефолт 25. Видимо и для plain, и для AWG (не гейтить по
  `_obfuscate`).
- В `_register()` пробросить `persistentKeepalive: int.tryParse(_keepalive.text.trim())`
  в `addWarp(...)`. Пусто/битое → `null` (keepalive не пишется). Значение `0`
  явно выключает.

## UI-строки

Все английские (`getLocalText.s(...)`). Русский перевод — в `assets/l10n/ui/ru.json`.
Без `§`-ссылок в видимых строках.

- «Persistent keepalive (s)» — label поля.
- Подсказка (helper/хинт), если нужна: «Keeps the tunnel alive during idle
  (default 25). 0 = off.»

## Тесты

- `WarpAccount.toWireguardConf` с `persistentKeepalive: 25` → в INI есть
  `PersistentKeepalive = 25`; без параметра → строки нет.
- `WarpAccount.toWireguardUri` с `persistentKeepalive: 25` → в query `keepalive=25`;
  без параметра → нет.
- Round-trip: `toWireguardConf(persistentKeepalive:25)` → `parseWireguardIni` →
  `WireguardPeer.persistentKeepalive == 25`; `toUri()` сохраняет значение.
- `persistentKeepalive: 0` → строки/query нет (гейт `> 0`).
- Регрессия генератора: `scan_node_builder` по-прежнему зовёт `toWireguardConf`
  без keepalive → в ноде нет `persistent_keepalive_interval`.
