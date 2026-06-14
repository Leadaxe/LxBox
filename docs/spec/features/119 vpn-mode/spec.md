# 119 — Режим работы VPN: Proxy / VPN / VPN+Proxy

| Поле | Значение |
|------|----------|
| Статус | Реализовано (targeting v2.2.0) |
| Дата старта | 2026-06-14 |
| Связанные spec'ы | [`046 tunnel apps split-tunneling`](../046%20tunnel%20apps%20split-tunneling/spec.md) — тоже config-transform tun-inbound, тот же full-restart-механизм, тот же storage-паттерн; [`012 native vpn service`](../012%20native%20vpn%20service/spec.md) — BoxVpnService/BoxService lifecycle; [`tasks/124`](../../tasks/124-allow-list-per-app.md) — self-package/protect/allowBypass на native-стороне |
| Затронутые файлы | `app/lib/services/settings_storage.dart`, `app/lib/services/settings_storage/vpn_mode.dart` (новый), `app/lib/services/subscription/subscription_identity.dart`, `app/lib/services/builder/post_steps.dart`, `app/lib/services/builder/post_steps/vpn_mode.dart` (новый), `app/lib/services/builder/build_config.dart`, `app/lib/services/subscription_controller.dart`, `app/lib/screens/settings_screen.dart`, `app/lib/screens/vpn_mode_tab.dart` (новый), `docs/STORAGE.md`, `docs/TEMPLATE.md`, `docs/ARCHITECTURE.md`, тесты |

## Цель

Дать юзеру выбор **как ядро ловит трафик** (inbound-трактовка). Сейчас LxBox работает в единственном режиме: один `tun`-inbound с `auto_route`, весь системный трафик заворачивается через Android `VpnService.establish()`. HTTP/SOCKS inbound'ов нет — приложение нельзя использовать как локальный прокси для других приложений на том же устройстве (паттерн «прокси как на десктопе»).

| Режим | inbound'ы в config | `VpnService.establish()` | Что получает юзер |
|---|---|---|---|
| **VPN** (default, текущее) | `tun` (auto_route) | да | весь трафик системы заворачивается — как сейчас |
| **Proxy** | `mixed` на `127.0.0.1`/`0.0.0.0` | **нет** (libbox не зовёт `openTun`) | локальный HTTP+SOCKS-порт; приложения настраиваются вручную; нет иконки ключа VPN, нет системного перехвата |
| **VPN+Proxy** | `tun` + `mixed` | да | системный перехват И локальный порт одновременно |

Локальный inbound — sing-box прокси на одном порту (default **2080**), тип выбирается: **HTTP+SOCKS5** (`mixed`, default), **HTTP** (`http`), **SOCKS5** (`socks`).

### Согласованные решения

- Тип inbound — выбор протокола: `mixed` (HTTP+SOCKS5, default) / `http` / `socks`, **один порт**, смена `type`.
- Auth на `127.0.0.1` — **рекомендуется, но можно снять** (предзаполнен `user` + автогенерированный пароль).
- Auth на `0.0.0.0` (LAN) — **обязателен, снять нельзя** (тумблер залочен on): порт виден другим устройствам в сети.
- Пароль при первом включении — **автогенерация** (`Random.secure`, 32-hex, образец `clash_secret`).
- Галку «регистрировать как системный прокси» (`setHttpProxy` / `Settings.Global`) — **НЕ делаем** (отклонено: на Android без root глобального системного прокси нет; `setHttpProxy` работает только при поднятом TUN; за пределами этой итерации).
- UI — **3-я вкладка в `SettingsScreen`**.
- Дефолтный порт — **2080**.

## Архитектура — config-only

Ключевая находка: native-сторона (foreground service, `protect`, override-options, command server) **tun-agnostic**. Proxy-режим достигается **чисто конфигом** (убрать `tun`-inbound), **изменений в Kotlin не требуется**.

```
┌──────────────────────────────────────────────────────────────┐
│ VpnModeConfig (storage key "vpn_mode")                        │
│   mode: vpn | proxy | vpn_proxy                              │
│   proxyPort / proxyListen / proxyAuthEnabled                 │
│   proxyUsername / proxyPassword                              │
└──────────────────────────────────────────────────────────────┘
        ↓ build_config: applyVpnMode(config, cfg, sniffEnabled:)
┌──────────────────────────────────────────────────────────────┐
│ Sing-box config inbounds[]                                    │
│   vpn        → [tun-in]                  (как сейчас)        │
│   proxy      → [mixed-in]                (tun удалён)        │
│   vpn_proxy  → [tun-in, mixed-in]                            │
│   mixed-in: {type:mixed, listen, listen_port, users?}       │
└──────────────────────────────────────────────────────────────┘
        ↓ libbox: openTun() зовётся ТОЛЬКО при наличии tun-inbound
┌──────────────────────────────────────────────────────────────┐
│ proxy      → нет openTun → нет establish → нет VPN-туннеля   │
│ vpn / vpn_proxy → openTun → establish как сейчас             │
│ foreground/protect/override — работают во всех режимах       │
└──────────────────────────────────────────────────────────────┘
```

## Storage

**Один структурированный ключ `vpn_mode`** + типизированная модель `VpnModeConfig` (по образцу `TunAppsConfig` в `settings_storage/backup_tun.dart`).

**Почему НЕ `@vars`:** `_substituteVars`/`_resolveVar` (`build_config.dart`) делают type-coercion — пароль из одних цифр станет `int`, `"true"`/`"false"` → `bool`, что испортит auth. А `users` — массив объектов, не плоская строка. Значения строятся **императивно** в post-step, минуя подстановку (как `applyTunPackages`).

Новый part-файл `app/lib/services/settings_storage/vpn_mode.dart`:

```dart
class VpnModeConfig {
  const VpnModeConfig({
    required this.mode,             // "vpn" | "proxy" | "vpn_proxy"
    required this.proxyPort,        // int, default 2080
    required this.proxyListen,      // "127.0.0.1" | "0.0.0.0"
    required this.proxyAuthEnabled, // bool
    required this.proxyUsername,    // "user" default
    required this.proxyPassword,    // autogen при первом enable
  });
  // ... поля ...
  bool get isVpn          => mode == 'vpn';
  bool get isProxy        => mode == 'proxy';
  bool get isVpnProxy     => mode == 'vpn_proxy';
  bool get hasTun         => mode != 'proxy';
  bool get hasMixed       => mode != 'vpn';
  bool get isPublicListen => proxyListen == '0.0.0.0';
  bool get effectiveAuth  => isPublicListen ? true : proxyAuthEnabled; // 0.0.0.0 форсит auth
  VpnModeConfig copyWith({...});
  Map<String, Object?> toJson() => {...};
}
```

Storage shape (`lxbox_settings.json`):

```jsonc
{
  "vpn_mode": {
    "mode": "vpn" | "proxy" | "vpn_proxy",
    "proxy_protocol": "mixed" | "http" | "socks",
    "proxy_port": 2080,
    "proxy_listen": "127.0.0.1" | "0.0.0.0",
    "proxy_auth_enabled": true,
    "proxy_username": "user",
    "proxy_password": "<32-hex или пусто>"
  }
}
```

`proxy_protocol` — sing-box inbound `type`: `mixed` (HTTP+SOCKS5 на одном порту, default), `http` (только HTTP, без UDP), `socks` (только SOCKS5). Одинаковая auth-структура у всех трёх; tag всегда `mixed-in` (от протокола не зависит).

- Mode-константы — статики на `SettingsStorage` (`_vpnModeVpn`/`_vpnModeProxy`/`_vpnModeVpnProxy`), как `_tunAppsModeOff/Allow/Deny`.
- Фасады `getVpnMode()` / `setVpnMode(cfg, {flush})`; сеттер `_setVpnMode` зовёт `markConfigDirty()` безусловно (как `_setTunApps`, §113).
- **Default для existing юзеров (backward-compat):** ключ отсутствует → `VpnModeConfig(mode:'vpn', proxyPort:2080, proxyListen:'127.0.0.1', proxyAuthEnabled:true, proxyUsername:'user', proxyPassword:'')`. mode=`vpn` = текущее поведение (post-step no-op). **Миграция не нужна** — отсутствие ключа эквивалентно дефолту.
- **Генерация пароля** — в UI-слое в момент включения auth с пустым паролем (по образцу `_hwid = generateUuidV4()`). Хелпер `generateProxyPassword()` в `subscription_identity.dart` рядом с `generateUuidV4` (16 байт `Random.secure` → 32-hex, образец `clash_secret`).

## Builder

Новый post-step `applyVpnMode` — файл `app/lib/services/builder/post_steps/vpn_mode.dart`, `part 'post_steps/vpn_mode.dart';` в `post_steps.dart`, импорт `VpnModeConfig`.

`BuildSettings` получает поле `VpnModeConfig? vpnMode` (default null → vpn, no-op). Контроллер добавляет `vpnMode: await SettingsStorage.getVpnMode()`.

**Точка вставки:** сразу **ПЕРЕД `applyTunPackages`** (после `applyCustomDns`). Порядок обязателен:
- `applyTunPackages` ищет первый `tun`-inbound. В proxy `applyVpnMode` уже удалил tun → `applyTunPackages` корректно no-op (покрыто `tun_packages_test.dart`). В vpn_proxy tun остаётся первым → находится.
- Должно быть после flush `route['rules']`, т.к. переназначает inbound-привязки.
- Прокинуть флаг `sniffEnabled: vars['sniff_enabled'] != 'false'` (блок удаления sniff-rules исполняется ДО applyVpnMode).

```dart
void applyVpnMode(Map<String, dynamic> config, VpnModeConfig cfg, {required bool sniffEnabled}) {
  if (cfg.isVpn) return; // tun остаётся, mixed нет, rules как есть

  final inbounds = config['inbounds'];
  if (inbounds is! List) return;
  final route = config['route'];
  final rules = (route is Map<String, dynamic>) ? route['rules'] : null;

  // proxy: удалить tun + переназначить tun-in rules → mixed-in
  if (cfg.isProxy) {
    inbounds.removeWhere((i) => i is Map && i['type'] == 'tun');
    if (rules is List) {
      for (final r in rules) {
        if (r is Map && r['inbound'] == 'tun-in') r['inbound'] = 'mixed-in';
      }
      // hijack-dns (без inbound) оставляем — работает для всех inbound
    }
  }

  // локальный inbound (proxy + vpn_proxy); type = выбранный протокол,
  // tag всегда mixed-in (внутренний id, route.rules re-tag на него завязан)
  final mixed = <String, dynamic>{
    'type': cfg.proxyProtocol, 'tag': 'mixed-in',
    'listen': cfg.proxyListen, 'listen_port': cfg.proxyPort, // int
  };
  if (cfg.effectiveAuth && cfg.proxyPassword.isNotEmpty) {
    mixed['users'] = [{'username': cfg.proxyUsername, 'password': cfg.proxyPassword}];
  }
  inbounds.add(mixed);

  // vpn_proxy: tun-in rules не трогаем, добавляем resolve+sniff для mixed-in
  if (cfg.isVpnProxy && rules is List) {
    rules.insert(0, {'action': 'resolve', 'inbound': 'mixed-in'});
    if (sniffEnabled) {
      rules.insert(1, {'action': 'sniff', 'inbound': 'mixed-in', 'timeout': '1s'});
    }
  }
}
```

- `route.final="vpn-1"` (outbound-цель, нода) остаётся во всех режимах — не зависит от inbound.
- `auto_route` — поле tun-inbound; в proxy tun удалён → поля нет (Android routing table не трогается, что и нужно).
- `hijack-dns` — оставляем во всех режимах (перехватывает DNS из mixed на sing-box DNS-движок; нет inbound-фильтра → работает для всех).
- **Пароль** строится прямо из `VpnModeConfig`, минуя `@var`-substitution.

### Sniff/resolve взаимодействие

В шаблоне `route.rules` жёстко привязаны к `inbound:"tun-in"` (`resolve` + `sniff`). При добавлении `mixed-in` трафик из него **не попадёт** под эти правила без re-tag/добавления.

- **proxy:** re-tag существующих `tun-in` resolve/sniff на `mixed-in` (не дублировать).
- **vpn_proxy:** `tun-in` правила остаются + добавить `mixed-in` resolve (всегда) и sniff (только если `sniffEnabled`).
- **sniff_enabled=false:** для proxy — tun-in sniff уже удалён до applyVpnMode, re-tag его не встретит ✅; для vpn_proxy — флаг `sniffEnabled` гейтит добавление mixed-sniff. resolve добавляется всегда (не управляется sniff_enabled).
- `validateConfig` inbound'ы не проверяет → новый mixed-inbound валидатор не сломает.

## Native

**Изменений в Kotlin НЕ требуется** — proxy-режим = config-only. Подтверждено разведкой:

| Аспект | Поведение без tun | Риск |
|---|---|---|
| BoxService без openTun | стартует; libbox без tun-inbound не зовёт `openTun` | нет |
| Foreground notification | `startForeground(FOREGROUND_SERVICE_TYPE_SPECIAL_USE)` до `startSingbox` | нет |
| `buildOverrideOptions` | `isAllowMode=false`, пустой OverrideOptions | нет |
| `protect(fd)` egress нод | через `autoDetectInterfaceControl`→`protect`, tun-agnostic | нет |
| Loopback | нет tun → нет auto_route → системные пакеты не заворачиваются; mixed слушает только явный трафик; egress protect'нут | нет |

**Verification-item (не блокер дизайна):** эмпирически подтвердить на устройстве через DIAGNOSTICS playbook, что в proxy-режиме `protect(fd)` работает у foreground-сервиса без `establish()` (egress ноды реально уходит наружу). Это единственный теоретический OEM-edge.

## UI

**3-я вкладка в `SettingsScreen`**: `TabController length: 2 → 3`, новый `Tab(text: 'Mode')`. Содержимое — отдельный stateful-виджет `VpnModeTab` с `LazyPersistMixin` (по образцу `tun_apps_tab.dart`).

```
SegmentedButton<String> mode: [VPN | Proxy | VPN+Proxy]        // всегда
─── если mode != vpn: ───
  SegmentedButton<String> protocol: [HTTP+SOCKS5 | HTTP | SOCKS5]
  SegmentedButton<String> listen: [127.0.0.1 (local) | 0.0.0.0 (LAN)]
  TextField port (number, валидация 1024–65535, default 2080)
  SwitchListTile "Require authentication"
      value: cfg.effectiveAuth
      onChanged: listen==0.0.0.0 ? null/*залочен on*/ : _toggleAuth
      subtitle@0.0.0.0: "Required for LAN-exposed proxy"
  ─── если effectiveAuth: ───
    TextField username (default "user")
    TextField password (obscureText + [показать] + [regenerate])
─── если mode == vpn: прокси-поля скрыты ───
```

Логика зависимостей:
- `listen → 0.0.0.0`: форс `proxyAuthEnabled=true`, switch disabled; если `proxyPassword.isEmpty` → `generateProxyPassword()`.
- `listen → 127.0.0.1`: switch снова enabled (значение сохраняется).
- Включение auth / смена mode на proxy|vpn_proxy при пустом пароле → генерация.
- Regenerate → новый пароль.
- Валидация порта: int ∈ [1024, 65535], иначе error-text, не сохранять.

**Persist:** `LazyPersistMixin` — `setVpnMode(_cfg, flush:false)` в `stageChanges()`, `markDirty()` синхронно ставит `configDirty`. **Reload:** смена inbounds = full restart; наследуется от существующей config-dirty машинерии (rebuild banner → restart banner). Новый путь не нужен.

## Edge cases

| Сценарий | Поведение |
|---|---|
| existing юзер без `vpn_mode` | default mode=vpn → post-step no-op → конфиг идентичен сегодняшнему |
| mode=proxy, auth снят (127.0.0.1) | `users` не пишется; порт открыт без пароля только на localhost |
| mode=proxy → переключение на 0.0.0.0 без пароля | UI форсит auth on + генерит пароль до сохранения |
| mode=vpn_proxy + tun_apps allow | `include_package` попадает в `tun-in` (первый), не в `mixed-in` |
| mode=proxy + tun_apps allow | `applyTunPackages` no-op (tun удалён) |
| sniff_enabled=false + vpn_proxy | mixed-in sniff НЕ добавляется, resolve добавляется |
| пустой пароль при auth (defensive) | post-step `users` не пишет |

## Порядок имплементации

1. spec.md (этот файл).
2. Storage: part `settings_storage/vpn_mode.dart` (`VpnModeConfig` + `_getVpnMode`/`_setVpnMode`); `part` + фасады + mode-константы в `settings_storage.dart`; `markConfigDirty()` в сеттере.
3. Helper `generateProxyPassword()` в `subscription_identity.dart`.
4. Builder: `post_steps/vpn_mode.dart` (`applyVpnMode`); `part` в `post_steps.dart`; поле `vpnMode` в `BuildSettings`; вызов перед `applyTunPackages` с `sniffEnabled`.
5. Wiring: `subscription_controller.dart` — `vpnMode: await SettingsStorage.getVpnMode()`.
6. UI: `VpnModeTab` (LazyPersistMixin) + 3-я вкладка в `SettingsScreen`.
7. Native: изменений нет; device-verification (egress+protect в proxy).
8. Docs: `STORAGE.md` секция `vpn_mode`; `TEMPLATE.md` — mixed строится императивно; `ARCHITECTURE.md` — proxy = config-only.
9. Тесты.

## Tests

**Unit** — `app/test/builder/vpn_mode_test.dart` (образец `tun_packages_test.dart`):
- vpn → config не изменён.
- proxy → tun удалён; mixed добавлен (type/tag/listen/listen_port int); tun-in resolve/sniff re-tag'нуты на mixed-in (нет dangling `inbound:tun-in`); hijack-dns нетронут.
- vpn_proxy → оба inbound (tun первый); mixed-in resolve+sniff добавлены, tun-in rules сохранены.
- vpn_proxy + sniffEnabled=false → mixed sniff НЕ добавлен, resolve добавлен.
- auth: непустой пароль → `users` есть; auth off (127.0.0.1) → `users` нет; 0.0.0.0 → `effectiveAuth==true`; пустой пароль при auth → `users` нет (defensive).
- interaction: proxy + tun_apps allow → `applyTunPackages` no-op; vpn_proxy + tun_apps allow → `include_package` в tun-in, не в mixed-in.
- Модель: предикаты, `copyWith`, `toJson`.

**Device-smoke** (через DIAGNOSTICS, `./scripts/lxbox-diag.sh`):
- Proxy: `curl -x http://user:PASS@127.0.0.1:2080 https://ifconfig.me` → IP ноды; нет иконки ключа VPN; egress ноды уходит наружу (protect работает).
- VPN+Proxy: системный трафик через tun И `curl -x` через mixed одновременно.
- 0.0.0.0: доступ с другого устройства в LAN с auth; без auth — отказ.

## Acceptance criteria

- [ ] mode=vpn даёт байт-в-байт тот же конфиг, что и до фичи (для existing юзеров).
- [ ] mode=proxy поднимает локальный mixed-порт, VpnService не активен (нет иконки ключа).
- [ ] mode=vpn_proxy: TUN + локальный порт работают одновременно.
- [ ] auth на 0.0.0.0 нельзя снять; пароль автогенерится; regenerate работает.
- [ ] смена режима триггерит rebuild+restart баннеры.
- [ ] unit-тесты зелёные.
- [ ] device-smoke пройден.

## Future extensions (вне этой итерации)

- Галка «регистрировать как системный прокси» (`setHttpProxy` на TUN для vpn_proxy; `Settings.Global` через root для чистого proxy).
- Раздельные `http` + `socks` на **двух разных портах** одновременно (сейчас выбор одного `type` на одном порту: `mixed`/`http`/`socks`).
- Per-app правило «через локальный прокси».
