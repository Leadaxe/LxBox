# §629 — Системный HTTP-прокси VPN-сети (Android 10+)

| Поле | Значение |
|------|----------|
| Тип | Функция |
| Статус | D (done), выпущено в v2.25.13 |
| Дата | 2026-10-12 |
| Источник | GitHub issue #165 (уточнение закрытого #84) |
| Связанные | §119 (VPN mode: tun-in / mixed-in), §049 F17 (Kotlin-связка `setHttpProxy`), §120 (типизированные `@var` и `#if` в шаблоне) |

## Проблема

Android 10+ позволяет VPN-приложению объявить системе HTTP-прокси для
VPN-сети (`VpnService.Builder.setHttpProxy(ProxyInfo)`). Приложения,
уважающие системный прокси (Chrome, Play Store, Play Services, YouTube,
всё на `HttpURLConnection`/Cronet/OkHttp по умолчанию), начинают ходить
через него сами, без ручной настройки: по TCP через `CONNECT host:port`,
без собственного DNS и без QUIC (UDP через HTTP-прокси не проходит,
приложения откатываются на TCP).

Автор issue проверил: в 2.25.11 функции нет. Режим VPN + Proxy ему не
подходит: там прокси видит только то приложение, где он прописан вручную.

Что уже есть в коде:

- Kotlin-связка готова целиком: [BoxVpnService.kt:546-560](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt)
  вызывает `builder.setHttpProxy(ProxyInfo.buildDirectProxy(...))`, если ядро
  передало `options.isHTTPProxyEnabled`; `BoxService.getSystemProxyStatus` /
  `setSystemProxyEnabled` обслуживают статус и перезапуск. Kotlin не трогать.
- Ядро берёт эти опции из tun-инбаунда:
  `"platform": {"http_proxy": {"enabled": true, "server": "...", "server_port": N, "bypass_domain": [...], "match_domain": [...]}}`.
- Билдер декларативный: inbounds описаны в
  [wizard_template.json](../../../app/assets/wizard_template.json) (`tun-in`
  ~1079, `mixed-in` ~1113) через `#if` по `@vpn_mode` / `@proxy_*`;
  переменные выставляются в
  [build_config.dart:308-324](../../../app/lib/services/builder/build_config.dart).

Никто это поле не пишет, в UI переключателя нет.

## Решение

Отдельный скрытый HTTP-инбаунд, **независимый** от настроек «Local proxy»
(`mixed-in`). Причины не вешать на `mixed-in`: у него авторизация включена
по умолчанию (`ProxyInfo` логин/пароль передать не умеет), протокол может
быть `socks` (Android объявляет только HTTP), и функция нужна в обычном
режиме VPN, а не только в VPN + Proxy.

### Хранилище — `vpn_mode.dart`

- Новое поле `VpnModeConfig.systemProxyEnabled: bool`, ключ storage
  `system_proxy_enabled`, **по умолчанию `false`** (решение владельца:
  включённый по умолчанию менял бы путь трафика Chrome/Play у всех после
  обновления). Отсутствие/битое значение → `false`.
- `copyWith`, `toJson`, `==`/`hashCode`, если есть — по образцу соседних полей.
- Порт инбаунда фиксированный, в хранилище и UI не выносится:
  `VpnModeConfig.systemProxyPort = 2081` (константа). Если пользователь
  поставил `proxy_port == 2081` у `mixed-in`, системный прокси берёт
  следующий свободный: правило «2081, при коллизии с `proxy_port` → 2082».
  Реализовать геттером `effectiveSystemProxyPort`.
- Debug API (`app/lib/services/debug/handlers/settings.dart`) читает/пишет
  `vpn_mode` — добавить поле туда же, как остальные поля `vpn_mode`.

### Билдер — `build_config.dart`

Рядом с `vars['proxy_*']`:

```dart
vars['sys_proxy'] = (vpnMode.systemProxyEnabled && vpnMode.mode != 'proxy') ? 'true' : 'false';
vars['sys_proxy_port'] = '${vpnMode.effectiveSystemProxyPort}';
```

В `else`-ветке (`vpnMode == null`) — `vars['sys_proxy'] = 'false'`.

### Шаблон — `wizard_template.json`

1. В `tun-in` (внутри `#value`, рядом с `stack`) — условный блок:

```json
"#if": {
  "#and": ["@sys_proxy"],
  "#value": {
    "platform": {
      "http_proxy": {
        "enabled": true,
        "server": "127.0.0.1",
        "server_port": "@sys_proxy_port"
      }
    }
  }
}
```

Проверить, как в этом движке сочетаются два `#if` внутри одного объекта
(в `tun-in` уже есть `#if` для `route_address`); если один объект допускает
лишь один `#if`, использовать принятую в шаблоне форму (см. §120, §555,
`docs/spec/tasks/555-template-lang-spec143-parity.md`).

2. Новый инбаунд после `mixed-in`:

```json
{
  "#if": {
    "#and": ["@sys_proxy"],
    "#value": {
      "type": "http",
      "tag": "sysproxy-in",
      "listen": "127.0.0.1",
      "listen_port": "@sys_proxy_port"
    }
  }
}
```

Без `users`. Loopback без авторизации — то же, что уже допустимо для
`mixed-in` на `127.0.0.1` с выключенной авторизацией.

3. Убедиться, что `@sys_proxy_port` подставляется числом, а не строкой
(как `@proxy_port` в `mixed-in`), и что гард сборки по реестру не снимает
ключ `platform` у `tun` как неизвестный. Если снимает — добавить ключ в
allowlist tun по образцу остальных ключей tun, без расширения реестра
вне этого.

### UI — `vpn_mode_tab.dart`

Один `SwitchListTile` в блоке **Tunnel options** после «Allow VPN bypass»,
по образцу соседних (та же вёрстка, тот же стиль подзаголовка, без своей
кнопки Save; сохраняется как остальные поля `_cfg`):

- title: `System HTTP proxy`
- subtitle вкл: `Apps that honor the system proxy (Chrome, Play) connect over TCP via the core; no QUIC.`
- subtitle выкл: `Announce a local HTTP proxy to the VPN network (Android 10+).`
- icon: `Icons.http`
- Виден только при `_cfg.mode != 'proxy'` (без TUN объявлять нечего).
- Тексты только на английском в коде, перевод — через существующий механизм
  `getLocalText.s(...)` и файлы l10n по образцу соседних строк (RU + остальные
  языки, где у соседних строк есть перевод).

### Правила маршрутизации

В `edit_controller.dart:161-162` список тегов inbound расширить:
`if (_hasSystemProxy) (tag: 'sysproxy-in', label: 'System proxy interface')`,
условие — по тому же источнику, что `_hasMixedInbound`. Трафик через
системный прокси приходит в ядро как `sysproxy-in`, не `tun-in`; правила
с `inbound: tun-in` на него не действуют. В `custom_rule.dart:148` упомянуть
третий тег в комментарии.

### Реализация (сделано)

- Хранилище: [vpn_mode.dart](../../../app/lib/services/settings_storage/vpn_mode.dart)
  — чтение `system_proxy_enabled` (:49, только `true` → вкл), поле и
  константа `systemProxyPort = 2081` (:98, :159), геттер
  `effectiveSystemProxyPort` (:161), `copyWith`/`toJson` (:188, :209).
  Конструктор принимает поле необязательным (`= false`) — существующие вызовы
  не меняются. `==`/`hashCode` у класса нет — не добавлялись.
- Debug API: `PUT /settings/vpn_mode` принимает `system_proxy_enabled`
  ([settings.dart:257](../../../app/lib/services/debug/handlers/settings.dart)),
  `GET` отдаёт его через `toJson`.
- Билдер: `vars['sys_proxy']`/`vars['sys_proxy_port']`
  ([build_config.dart:323-330](../../../app/lib/services/builder/build_config.dart)).
- Шаблон: переменные `sys_proxy` (bool) и `sys_proxy_port` (int, тип даёт
  число) в секции `vpn-mode` (wizard_template.json:1002-1011); условный
  `platform.http_proxy` у `tun-in` под ключом `"#if sys_proxy"` (движок
  допускает суффикс к `#if`, `if_engine.dart` `isIfKey`) — :1127-1136;
  инбаунд `sysproxy-in` после `mixed-in` — :1180-1186. Гард сборки ключ
  `platform` у tun не снимает (проверено тестом), allowlist не трогался.
  Переводы title/tooltip новых переменных — `assets/l10n/{ru,zh}/template.json`.
- UI: тумблер после «Allow VPN bypass» в Tunnel options
  ([vpn_mode_tab.dart:412-421](../../../app/lib/screens/vpn_mode_tab.dart),
  обработчик :223); блок уже гейтится `_cfg.hasTun`. Строки —
  `assets/l10n/{ru,zh}/ui.json`.
- Правила: `sysproxy-in` в `inboundChoices`
  ([custom_rule_edit/edit_controller.dart:168](../../../app/lib/screens/custom_rule_edit/edit_controller.dart),
  условие :352 — `systemProxyEnabled && hasTun`); комментарий в
  `custom_rule.dart` у `inbounds`.
- Тест: `app/test/builder/system_proxy_test.dart` (настоящий шаблон через
  `buildConfig`), зелёный. Golden хранилища не менялись: `vpn_mode` в
  roundtrip-фикстурах отсутствует, при выключенном тумблере конфиг прежний.
- Эмулятор не проверялся.

## Границы

- Только TCP, только HTTP: UDP (QUIC, DNS, игры, WebRTC) и приложения,
  игнорирующие системный прокси, идут через TUN как раньше. TUN остаётся.
- Исключённые из VPN приложения (per-app) системный прокси не получают —
  норма Android.
- `bypass_domain` / `match_domain` не реализуются; при необходимости —
  отдельная задача.
- Экономия батареи — гипотеза автора issue, не обещается.
- Kotlin не меняется.

## Проверка

- Тест шаблона/билдера (`app/test/builder/`, новый файл
  `system_proxy_test.dart`): при `systemProxyEnabled=true, mode=vpn` в
  результате сборки есть `sysproxy-in` типа `http` на `127.0.0.1:2081` без
  `users` и у `tun-in` есть `platform.http_proxy` с `enabled: true` и числовым
  `server_port: 2081`; при `false` — ни того, ни другого; при `mode=proxy` —
  ни того, ни другого даже при `true`; при `proxy_port=2081` порт системного
  прокси `2082`; `mixed-in` и его `users` не меняются.
- Golden-фикстуры хранилища (`app/test/storage_migration/`,
  `app/test/fixtures/storage/golden/*`) — если `toJson` пишет новое поле
  всегда, обновить golden осознанно и отметить в отчёте.
- Эмулятор (разрешён): с тумблером Chrome в Connections показывает
  соединения через `sysproxy-in` с доменом из `CONNECT`, QUIC/DNS от Chrome
  пропадают; с выключенным — как раньше. На телефон владельца не ставить.
- CI — Sonnet-дежурный, один затронутый тестовый файл локально, не каталог.

### Результат проверки (12.10.2026, эмулятор LxBox_test, 2.25.12-dev.26)

- Хвосты после исполнителя, закрыты в develop: golden roundtrip хранилища
  (`$.vpn_mode.system_proxy_enabled: <absent> → false`, ddd65dd2) и
  объявление `sys_proxy`/`sys_proxy_port` в `SettingsStorage.configVarKeys`
  (9567442d). CI на 9567442d зелёный.
- База: один inbound `tun-in`, `platform: null`, у VPN-сети в
  `dumpsys connectivity` поля HttpProxy нет.
- Включение через Debug API + `reload-vpn`: в running config
  `{"type":"http","tag":"sysproxy-in","listen":"127.0.0.1","listen_port":2081}`
  без `users`, у `tun-in` `platform.http_proxy{enabled:true, server_port:2081}`
  (число); у VPN-сети `HttpProxy: [127.0.0.1] 2081`, глобальный
  `http_proxy` пуст — прокси объявлен на сети, не глобально.
- Chrome (`www.google.com`, `play.google.com`): в логах ядра
  `inbound/http[sysproxy-in]: inbound connection to www.google.com:443`,
  30 строк `sysproxy-in` и ни одной `tun-in`; профайлер — 64 TCP-события
  с доменами, 0 UDP, QUIC нет. Ошибок в logcat нет.
- Выключение: running config побайтно равен базе, HttpProxy у сети пропал.
- UI: тумблер в Tunnel options под «Allow VPN bypass», выключен; в режиме
  Proxy блока нет.
- Наблюдение: у Chrome в профайлере 16 `dnsResolve` (`dns_stream`) — ядро
  резолвит домен из `CONNECT` для `direct-out`, это не DNS Chrome.

## Нерешённое

- Авторизация на системном прокси невозможна по API Android; защита порта —
  только loopback.
- `bypass_domain` / `match_domain` — при запросе пользователей.
