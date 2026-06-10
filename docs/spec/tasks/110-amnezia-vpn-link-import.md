# 110 — Импорт Amnezia `vpn://`-ссылок (WG/AWG контейнеры)

| Поле | Значение |
|------|----------|
| Статус | Done — реальная awg2-выгрузка вскрыла ranged headers (→ §112); INI-путь проверен live-smoke §112 (handshake ядром lx.6 с реальным сервером); коммиты `d8043de` (feat), вошло в v2.0.3 |
| Дата старта | 2026-06-10 |
| Дата завершения | — |
| Коммиты | — |
| Связанные spec'ы | features/026 (Parser v2: body_decoder/parse_all), features/097 (AWG2), tasks/106 (WG INI edge cases) |

## Проблема

AmneziaWG-клиенты (awg2 и сам Amnezia) экспортируют конфиг двумя способами:
`.conf` (WireGuard INI — уже едим, §097/§106) и `.vpn`-файл / строка
`vpn://<base64>` — родной контейнерный формат Amnezia. Вторую юзеры
вставляют в приложение чаще (это «share connection» по умолчанию), но
LxBox её не распознаёт: paste → `Unknown format`. Field report: юзер с
awg2-конфигом не смог понять, как скормить выгрузку (вариант «открой
.conf и скопируй текст» неочевиден, а `.vpn` вообще не содержит INI).

## Формат `vpn://`

Открытый, эталон — [amnezia-vpn/config-decoder](https://github.com/amnezia-vpn/config-decoder)
(`mainwindow.cpp`), боевой код — `client/ui/controllers/exportController.cpp`
(генерация) / `importController.cpp` (парс) в amnezia-client:

```
vpn://  +  base64url( qCompress( JSON, 8 ) )      ← основной вариант
vpn://  +  base64url( JSON )                      ← несжатый fallback (importController пробует оба)
```

- base64url: алфавит `-_`, **без** padding (`Base64UrlEncoding | OmitTrailingEquals`).
- `qCompress` = 4 байта big-endian (claimed длина распакованного) + стандартный zlib-поток.
- JSON (усечённо, интересующая часть):

```json
{
  "containers": [
    {
      "container": "amnezia-awg",
      "awg": {
        "last_config": "{\"config\": \"[Interface]\\n…\\n[Peer]\\n…\", \"mtu\": \"1280\", …}",
        "port": "43210", "transport_proto": "udp"
      }
    }
  ],
  "defaultContainer": "amnezia-awg",
  "description": "…", "hostName": "1.2.3.4",
  "dns1": "1.1.1.1", "dns2": "1.0.0.1"
}
```

- Протокольный под-объект контейнера: ключ `awg` (AmneziaWG) или
  `wireguard` (plain WG). Остальные (`openvpn`, `xray`, `cloak`, …) —
  вне scope, LxBox их не поддерживает.
- `last_config` — **JSON-строка** (escaped); защитно принимаем и Map
  (встречается в пересохранённых конфигах).
- `last_config.config` — готовый WG/AWG INI-текст (`[Interface]`/`[Peer]`,
  AWG-поля `Jc`/`Jmin`/…/`I1`–`I5` в `[Interface]`). Может содержать
  плейсхолдеры `$PRIMARY_DNS`/`$SECONDARY_DNS` — значения лежат рядом в
  корне (`dns1`/`dns2`).

## Решение

Декод врезается в `body_decoder.decode()` нулевым шагом — тогда
**персист-путь не требует изменений**: `UserServer.fromJson` ре-парсит
ноды через `parseAll(decode(rawBody))`, а `rawBody` хранит оригинальную
`vpn://`-строку (контракт «оригинал paste'а» соблюдён).

1. **`services/parser/amnezia_link.dart`** (новый) —
   `DecodedBody decodeAmneziaLink(String link)`:
   - cap длины ссылки `maxURILength` (65536, как у URI) + cap claimed
     uncompressed size 4 MiB — защита от zlib-бомб;
   - base64url → `decodeBase64Safe` (уже умеет все 4 варианта
     padded/unpadded × std/url);
   - `skip(4)` + zlib inflate (`dart:io zlib`); не взлетело → пробуем
     payload как несжатый UTF-8 JSON (паритет с importController);
   - `containers[]` → для каждого контейнера ключи `awg`, `wireguard` →
     `last_config` (String → jsonDecode | Map) → `config` (должен
     содержать `[Interface]` и `[Peer]`);
   - подстановка `$PRIMARY_DNS`/`$SECONDARY_DNS` ← `dns1`/`dns2`
     (для fidelity `rawIni`; сам INI-парсер DNS-строки игнорирует);
   - результат: `AmneziaConfig(iniTexts)`; пусто/битое → `DecodeFailure`
     с конкретной причиной (не throws).
2. **`body_decoder.dart`**: новый подтип `AmneziaConfig extends
   DecodedBody` (sealed → обязан жить в этом файле) + шаг 0 в `decode()`:
   `startsWith('vpn://')` → `decodeAmneziaLink`. Существующим веткам не
   мешает: `vpn://…` не проходит `_looksLikeBase64` (`:` вне алфавита).
3. **`parse_all.dart`**: case `AmneziaConfig` → каждый INI через
   существующий `parseWireguardIni` (null-skip, как у `UriLines`).
   Exhaustive switch — компилятор сам потребовал ветку.
4. **`input_helpers.dart`**: `isAmneziaVpnLink()` (= trim +
   `startsWith('vpn://')`). В `isDirectLink` **не** добавляем — это не
   одноузловой URI для `parseUri`.
5. **`clipboard_analysis.dart`**: ветка перед `isDirectLink` — декод и,
   если `AmneziaConfig`, карточка `type: 'amnezia_vpn'`, title
   `Amnezia VPN config`, subtitle = Endpoint первого INI (+ `× N` при
   нескольких контейнерах). Битая ссылка → `unknown` (юзер увидит
   стандартный unknown-format диалог с текстом).
6. **`subscription_controller.addFromInput`**: ветка после
   `isWireGuardConfig` — `parseAll(decode(trimmed))`; пусто →
   `_lastError = 'No WireGuard/AmneziaWG config in vpn:// link'`; иначе
   `UserServer(origin: paste, rawBody: <vpn://-строка>, nodes: …)` — по
   образцу WG-INI ветки, но один entry на всю ссылку (узлов может быть
   несколько).

## Locked decisions

1. Импортируем **все** WG/AWG-контейнеры ссылки (не только
   `defaultContainer`) — каждый парсящийся `config` → нода; один
   `UserServer` на ссылку.
2. Не-WG контейнеры (openvpn/xray/…) молча скипаются; если WG/AWG нет
   вообще — явная ошибка, не пустой entry.
3. `description`/`hostName` из JSON в имя ноды **не** прокидываем —
   label остаётся `WireGuard` (как у `.conf`-вставки; единообразие).
   Можно вернуться отдельной таской, если попросят.
4. `.vpn`-файл как файл не импортируем (FilePicker-потока для подписок
   нет) — только paste строки. Содержимое `.vpn` = та же строка.
5. dart:io в parser-слое допустим (Android-only приложение, тесты на VM).

## Риски и edge cases

- zlib-бомба: caps по входу (64 KiB ссылка) и claimed size (4 MiB).
- `last_config` бывает строкой и объектом — принимаем оба.
- Несжатый payload (старые/сторонние генераторы) — fallback-ветка.
- base64 с padding (некоторые боты дописывают `=`) — `decodeBase64Safe`
  уже терпит.
- Amnezia Premium / api-key конфиги (`api_key` без `containers` c WG) →
  честный `DecodeFailure('vpn://: no WireGuard/AmneziaWG containers')`.
- Битые числа/поля внутри INI — обрабатывает существующий
  `parseWireguardIni` (§097/§106), новых путей отказа не добавляем.

## Верификация

- Unit `test/parser/amnezia_link_test.dart`: encode-helper строит ссылку
  программно (4-байт BE header + `zlib.encode`); кейсы — AWG-контейнер
  end-to-end (`Awg.fields` доехали), plain-WG, `last_config` строкой и
  объектом, DNS-подстановка, несжатый payload, padded base64, мусор
  после `vpn://`, контейнеры без WG/AWG, мульти-контейнер → 2 ноды,
  персист round-trip `UserServer.toJson/fromJson` (ноды восстановлены из
  rawBody), `analyzeClipboard` (карточка + unknown на битой). ✅
- Unit `test/subscription/input_helpers_test.dart`: `isAmneziaVpnLink`
  + `isDirectLink('vpn://…') == false`. ✅
- `flutter analyze` чистый, полный `flutter test` — 946 passed. ✅
- Smoke на устройстве: вставить реальную awg2-выгрузку → нода появляется,
  коннект поднимается. Pending (нужна реальная ссылка).

## Нерешённое / follow-up

- QR-скан (в UI заглушка «coming soon») — когда появится, Amnezia-QR
  декодится этим же путём (их QR = тот же `vpn://`-payload, но
  чанкованный — потребует склейки чанков).
- Имя ноды из `description`/`hostName` — locked decision 3.
