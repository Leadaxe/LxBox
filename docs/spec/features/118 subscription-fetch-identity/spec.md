# 118 — Идентичность фетча подписок (custom User-Agent + HWID)

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата старта | 2026-06-13 |
| Дата завершения | — |
| Коммиты | — |
| Связанные spec'ы | tasks/114 (UA brand-token routing), features/026 (parser v2), App Settings (general tab) |

## Зачем

Field-нужда: панели (Remnawave / Marzban-типа) различают и **лимитируют клиентов**
по двум сигналам в HTTP-запросе подписки:

- **User-Agent** — панель маршрутизирует тело ответа по подстроке в UA (см.
  [user_agent.dart](../../../app/lib/services/subscription/user_agent.dart) /
  таск 114). Иногда нужно подменить UA, чтобы получить нужный формат / выдать
  себя за другой клиент.
- **HWID** (hardware id) — Remnawave HWID-device-limit считает устройства по
  заголовку `x-hwid` (+ device-meta). Чтобы подписка работала под лимитом — надо
  слать HWID, а пользователю нужна **возможность переписать** его (привязать к
  «тому же» устройству, сбросить счётчик и т.п.).

Обе настройки — **глобальные**, живут в **App Settings → General → секция
Subscriptions**. Затрагивают только **HTTP-фетч подписки**, не sing-box-конфиг.

## Контракт (что шлём)

Заголовки на каждый GET подписки ([sources.dart](../../../app/lib/services/subscription/sources.dart) `_fetch`):

| Заголовок | Значение | Когда |
|---|---|---|
| `User-Agent` | override **или** дефолт `LxBox-android/<ver>` | всегда |
| `x-hwid` | UUID (дефолт) или override | только при включённом тоггле |
| `x-device-os` | `android` | при включённом HWID |
| `x-ver-os` | Android release (`Build.VERSION.RELEASE`, напр. `14`) | при включённом HWID |
| `x-device-model` | `Build.MODEL` (напр. `Pixel 7`) | при включённом HWID |

`x-hwid` + device-meta — стандарт Remnawave (некоторые панели показывают meta в
списке устройств).

## Решения (locked — согласованы с юзером)

1. **HWID transport — заголовок `x-hwid`** (Remnawave), не в UA, не query-param.
2. **HWID default — сгенерённый UUIDv4**, один раз, персистится; кнопка
   Regenerate. НЕ Android `ANDROID_ID` (приватность / не привязываемся к железу).
3. **HWID send — opt-in тоггл, OFF по умолчанию** (не фингерпринтим все панели
   без нужды). Включаешь, когда панель требует HWID-лимит.
4. **device-meta шлём** вместе с `x-hwid` (полный Remnawave-набор).
5. **UA override — глобальный**, пусто = дефолтный брендированный
   `LxBox-android/<ver>`. Per-source `UrlSource.userAgent` (если задан) имеет
   приоритет над глобальным override (узкое > широкое).
6. **Эти var'ы НЕ config-significant** — не в `_configVarKeys`, не трогают
   config-dirty (влияют на фетч, не на sing-box-конфиг).

## Модель данных

### Storage (generic vars, `SettingsStorage`)

| Var | Тип | Дефолт | Семантика |
|---|---|---|---|
| `subscription_user_agent` | String | `''` | пусто = брендированный UA; иначе override |
| `subscription_send_hwid` | bool (`'true'`/`'false'`) | `false` | слать ли HWID-заголовки |
| `subscription_hwid` | String | `''` → лениво UUIDv4 | значение `x-hwid`; генерится при первом показе/включении |

Лениво: при первом рендере HWID-секции (или включении тоггла), если
`subscription_hwid` пуст → сгенерить UUIDv4 + персистнуть. Так в UI всегда есть
значение, но из коробки в storage ничего нет.

### Runtime-holder `SubscriptionIdentity` (sync-доступ на фетче)

`_fetch` синхронен по чтению идентичности (как `resolveSubscriptionUserAgent`
читает `VersionInfo`). Заводим static-holder, инициализируемый в `main()` до
`runApp` и обновляемый при сохранении настроек:

```dart
class SubscriptionIdentity {
  static String userAgentOverride = '';   // '' = use branded
  static bool   sendHwid = false;
  static String hwid = '';
  static String deviceOs = 'android';
  static String osVersion = '';            // Build.VERSION.RELEASE
  static String deviceModel = '';          // Build.MODEL

  static Future<void> init();               // load vars + device_info_plus
  static void apply({...});                 // settings-screen на save
  static Map<String,String> fetchHeaders(); // x-hwid + meta если sendHwid
}
```

- `init()`: читает 3 var'а + `DeviceInfoPlugin().androidInfo`
  (`.model`, `.version.release`) — пакет уже в зависимостях.
- `osVersion`/`deviceModel` кэшируются (не меняются в рантайме).

### UUIDv4 без пакета

`uuid`-пакета нет → генерим сами через `Random.secure()` (16 байт, version/variant
биты, hex-формат `8-4-4-4-12`). Чистая функция `generateUuidV4()` + unit-тест.

## Поток данных

```
main(): VersionInfo.init() → SubscriptionIdentity.init()  (vars + device info)
                                       │
App Settings (General → Subscriptions) ─ save → SubscriptionIdentity.apply()
                                       │
subscription _fetch:
  User-Agent = SubscriptionIdentity.userAgentOverride.isNotEmpty
               ? override : resolveSubscriptionUserAgent()   (per-source UA > override)
  + SubscriptionIdentity.fetchHeaders()   // {x-hwid, x-device-os, x-ver-os, x-device-model} если sendHwid
```

## UI — App Settings → General → секция «Subscriptions»

- **Custom User-Agent**: text-field (tile→dialog). Hint = текущий дефолт
  `LxBox-android/<ver>`. **Warning-helper**: «Часть панелей отдаёт конфиг по
  подстроке в UA — без токена `LxBox` подписка может вернуть неподдерживаемый
  формат (см. §114). Меняй только если знаешь, что делаешь.»
- **Send HWID** (switch, off по умолчанию). При on:
  - **HWID** text-field (prefill UUID, editable) + **Regenerate** (↻) — новый UUID.
  - read-only info: что уйдёт в meta (`android · <osVersion> · <deviceModel>`).

Пустой UA-override → поле пустое, плейсхолдер = дефолт. Пустой HWID при включённом
тоггле → сгенерить на лету.

## Затронутые файлы

| Файл | Что |
|---|---|
| `services/subscription/subscription_identity.dart` (new) | holder + `init`/`apply`/`fetchHeaders` + `generateUuidV4` |
| `services/subscription/user_agent.dart` | `resolveSubscriptionUserAgent` — учесть override (или оставить, override в holder) |
| `services/subscription/sources.dart` | `_fetch` — UA из holder + merge `fetchHeaders()` |
| `main.dart` | `SubscriptionIdentity.init()` после `VersionInfo` |
| `screens/app_settings_screen.dart` + `widgets/general_tab.dart` | секция Subscriptions (UA + HWID UI), проброс state |
| `services/settings_storage.dart` | (var'ы generic, allow-list не нужен; НЕ в `_configVarKeys`) |

## Риски и edge cases

- **UA-override ломает фетч**: панель без токена `LxBox` отдаёт JSON, который
  парсер v2 не ест → подписка не обновится. Mitigation — warning-helper; не
  блокируем (power-feature).
- **HWID-лимит панели**: смена/Regenerate HWID = новое «устройство» для панели;
  старое может занять слот лимита. Это ожидаемо (юзер сам жмёт). Без UI-варнинга.
- **device_info на не-Android** (десктоп-сборка lib общая): `androidInfo` бросит
  → `init` ловит, meta остаётся пустой; на Android-таргете не воспроизводится.
- **Пустой UA** (override = пробелы) → trim, пусто → дефолт (не шлём пустой UA).

## Верификация

- Unit: `generateUuidV4` — формат `8-4-4-4-12`, version-nibble `4`, variant; два
  вызова разные. `SubscriptionIdentity.fetchHeaders()` — пусто при `sendHwid=false`,
  полный набор при true. UA-резолв: override > дефолт; per-source > override.
- `flutter analyze` чистый, полный `flutter test` зелёный.
- Девайс-смок: включить HWID → фетч подписки шлёт `x-hwid`+meta (проверить
  Debug-логом / панелью); сменить UA → панель отдаёт другой формат.
