# L×Box v2.25.6

**A patch on top of [v2.25.5](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.5).**

The core moves to `v1.14.2-lx.4`: a WireGuard or AmneziaWG node can be turned
off and on without restarting the tunnel. A folder or a subscription can be
replaced with a single group in Directions, rules and the default route.
Manual (`selector`) groups from subscriptions keep their kind and their chosen
server. Imported nodes keep every field the provider sent. Subscription entries
the parser could not read are listed in the subscription summary instead of
staining a working node. Wi-Fi rules read the network name the way Android 12+
expects and say why they cannot. The parser, the node sanitizer and the
template engine follow the protocol contract 1.1.57–1.1.82, so nodes and configs
match the desktop launcher byte for byte.

**Патч поверх [v2.25.5](https://github.com/Leadaxe/LxBox/releases/tag/v2.25.5).**

Ядро обновлено до `v1.14.2-lx.4`: узел WireGuard или AmneziaWG можно выключить
и включить без перезапуска туннеля. Папку или подписку можно заменить одной
группой в Направлениях, правилах и маршруте по умолчанию. Ручные группы
(`selector`) из подписок сохраняют свой род и выбранный сервер. Импортированные
узлы сохраняют все поля, которые прислал провайдер. Записи подписки, которые
парсер не смог прочитать, показываются в сводке подписки, а не на чужом рабочем
узле. Правила Wi-Fi читают имя сети так, как ждёт Android 12+, и объясняют,
почему не могут. Парсер, санитайзер узлов и движок шаблонов следуют контракту
протоколов 1.1.57–1.1.82, поэтому узлы и конфиги совпадают с десктопным
лаунчером байт в байт.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## ✨ Added

- **Turn a WireGuard/AmneziaWG node off without restarting the tunnel.** Core
  `v1.14.2-lx.4`. A node's menu has Turn off / Turn on, the node screen has a
  Node enabled switch. A node that is off drops its connections and refuses new
  ones while the rest of the tunnel keeps running; it stays off through config
  reloads and subscription updates until you turn it on or stop the VPN. In
  the list it shows an orange `off` and a dash instead of a ping.
- **Replace a folder or subscription with a group.** Settings of a folder or a
  subscription have Replace with a group: Manual (you pick the server), Auto
  (picked by latency) or Both (a manual group whose first option and default
  is the auto one, `<name>-auto`). Directions then offer that one group
  instead of every server of the source; rules and the default route can point
  at it. The editor warns when the group name is already taken. The setting
  travels in backups as `replace`; the old launcher form `fold` is reported as
  an unknown field.
- **Manual groups keep their kind.** A `selector` group from a sing-box
  subscription or a backup is no longer turned into a latency group: it stays
  manual, keeps its chosen server and goes to the core as `selector`. The group
  screen has a Manual mode with the member list; on the node screen, tap the
  circle next to a member to pick it, live through the core when the VPN is
  up. The pick survives subscription updates and restarts.
- **Template variables with a list of values.** A `text_list` with options is
  a multi-select of chips, `options_open` lets you type your own value next to
  the list, a `text` with a closed list is a dropdown. After a build with
  template warnings, Home shows "Template: N warnings" with a button that
  opens the codes; saving is never blocked.
- **Rules left without conditions are dropped.** A preset route or DNS rule
  that has no matching condition left after variable substitution (only an
  `action`, or a logical rule with empty sub-rules) is left out with a code
  instead of matching all traffic. The list of condition fields comes from the
  contract.

## 🔄 Changed

- **Dropped subscription entries show in the subscription summary.** An entry
  the parser could not turn into a node used to leave its error on a
  neighbouring node that had nothing wrong with it. Now working nodes stay
  clean; the subscription screen shows `N entries dropped`, tap it to see each
  reason with the entry it belongs to, and the card in the list shows the
  count. The paste dialog says how many entries will be skipped and why.
- **Node names with broken bytes and old-style VMess links match the desktop
  app.** A run of invalid bytes in a node name (cp1251 text in a link label)
  shows as a single `�`, so the node tag is the same on both sides. Old-style
  `vmess://` links with `method:uuid@host:port` under base64 are recognised by
  what is inside the base64. A `vpn://` line inside a subscription list gives
  every WireGuard/AmneziaWG container of the profile.
- **Node sanitizer follows contract 1.1.57–1.1.82.** REALITY without uTLS gets
  uTLS switched on instead of losing REALITY, and a `random` fingerprint under
  REALITY becomes `chrome`, both with a code on the node. MASQUE keeps
  `tls.fragment` on `h2`/`auto` and drops it on `h3`. AmneziaWG `jmin > jmax`
  drops both bounds, Tailscale `advertise_routes` masks host bits and drops
  default routes, an object sent where a string is expected is unwrapped by
  rule. In an Xray chain, TLS fragmentation from a `freedom` dialer goes to the
  hop that dials out. A WireGuard `listen_port` yields to a detour added by the
  build. A node the core cannot run (Tailscale without `with_tailscale`,
  AmneziaWG 3.x fields on an older core) is dropped at build time with a code.
  Backups carry an Auto group's warnings; a node disabled after a core
  rejection stays disabled on import.
- **Chains with a REALITY hop no longer refuse to save when uTLS is
  stripped.** The editor shows a warning instead of locking Save, the strip row
  reads `kept`, and the build keeps uTLS on all hops. Strip options and the
  AmneziaWG level next to the protocol (`awg2`, `awg1.5+`) come from the
  contract.
- **Template language follows contract 1.1.68–1.1.82.** A list-valued `#if`
  branch inside an array splices into the parent, `@runtime.*` drops its key
  instead of leaking into the config, template warnings carry their parameters
  and are deduplicated, a DNS server left without an address is dropped with a
  warning, template DNS servers see every template variable.
- **Internal.** Link schemes, protocol files and the SOCKS version table are
  read from the contract registry only; per-protocol parser wrappers are gone.
  The contract document `CANON.md` is now `PARSING_PRINCIPLES.md`. No
  behaviour change.

## 🩹 Fixes

- **Wi-Fi rules read the network name the way Android 12+ expects.** The name
  and BSSID come from a network callback registered with location info; the old
  call stays as a fallback on Android 11 and older. With Wi-Fi off, Add current
  says "Not connected to Wi-Fi." instead of blaming permissions.
- **Wi-Fi rules say why they cannot read the network name.** Android hides the
  name without an error when location is "Approximate" or the system Location
  toggle is off. Add current now opens the permission dialog with a
  precise-location note or offers the Location settings; Diagnostics reports
  both. The reason is written to logcat under `WifiInfoReader`.
- **Imported nodes keep what the provider sent.** `multiplex`, `udp_over_tcp`,
  dial options, WireGuard `workers` and `listen_port`, QUIC tuning and extra
  transport fields reach the config as written. Xray nodes no longer get a
  `server_name` the provider did not set; a VMess link with `aid=0` no longer
  writes `alter_id: 0`. An Xray `socks` outbound becomes a node, and an Xray
  outbound nobody can read is reported as rejected instead of disappearing.
- **Links to a chain open the chain.** Tapping a chain on a node's screen or in
  the detour-loop sheet used to show "Source not found in your lists". It now
  opens the chain editor; a saved change applies to a running tunnel.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## ✨ Добавлено

- **Выключить узел WireGuard/AmneziaWG без перезапуска туннеля.** Ядро
  `v1.14.2-lx.4`. В меню узла — Turn off / Turn on, на экране узла —
  переключатель Node enabled. Выключенный узел рвёт свои соединения и не
  принимает новые, остальной туннель работает; он остаётся выключенным при
  пересборке конфига и обновлении подписки, пока вы его не включите или не
  остановите VPN. В списке — оранжевый `off` и прочерк вместо пинга.
- **Заменить папку или подписку группой.** В настройках папки и подписки —
  Replace with a group: Manual (сервер выбираете вы), Auto (по задержке) или
  Both (ручная группа, первый пункт и умолчание которой — автогруппа
  `<имя>-auto`). Направления предлагают одну эту группу вместо всех серверов
  источника; правила и маршрут по умолчанию могут указывать на неё. Редактор
  предупреждает, если имя занято. Настройка едет в бэкапе как `replace`;
  старая форма лаунчера `fold` отмечается как неизвестное поле.
- **Ручные группы сохраняют род.** Группа `selector` из sing-box-подписки или
  бэкапа больше не превращается в группу по задержке: остаётся ручной,
  сохраняет выбранный сервер и уходит в ядро как `selector`. На экране группы
  — режим Manual со списком членов; на экране узла кружок рядом с членом
  выбирает его, при поднятом VPN — сразу через ядро. Выбор переживает
  обновления подписки и перезапуск.
- **Переменные шаблона со списком значений.** `text_list` со списком — выбор
  чипами, `options_open` разрешает своё значение рядом со списком, `text` с
  закрытым списком — выпадающий список. После сборки с предупреждениями
  шаблона на главном экране появляется «Template: N warnings» с кнопкой к
  кодам; сохранение не блокируется.
- **Правила без условий выпадают.** Правило route или DNS пресета, у которого
  после подстановки переменных не осталось ни одного условия (только
  `action`, или логическое правило с пустыми подправилами), не попадает в
  конфиг и получает код вместо того, чтобы ловить весь трафик. Список
  полей-условий берётся из контракта.

## 🔄 Изменено

- **Отброшенные записи подписки — в сводке подписки.** Запись, которую парсер
  не смог превратить в узел, раньше оставляла свою ошибку на соседнем
  исправном узле. Теперь рабочие узлы чисты; экран подписки показывает
  `N entries dropped`, по тапу — каждая причина с именем записи, карточка в
  списке — счётчик. Диалог вставки говорит, сколько записей будет пропущено и
  почему.
- **Имена узлов с битыми байтами и старые ссылки VMess совпадают с десктопом.**
  Серия невалидных байтов в имени (cp1251 в подписи ссылки) даёт один `�`, и
  тег узла одинаков на обеих сторонах. Старые `vmess://` с
  `method:uuid@host:port` под base64 распознаются по содержимому base64.
  Строка `vpn://` внутри списка подписки даёт все контейнеры WireGuard/AmneziaWG
  профиля.
- **Санитайзер узлов следует контракту 1.1.57–1.1.82.** REALITY без uTLS
  получает включённый uTLS, а не теряет REALITY; отпечаток `random` под
  REALITY становится `chrome`, оба с кодом на узле. MASQUE сохраняет
  `tls.fragment` на `h2`/`auto` и снимает на `h3`. AmneziaWG с `jmin > jmax`
  теряет обе границы, Tailscale `advertise_routes` маскирует биты хоста и
  снимает маршруты по умолчанию, объект на месте строки разворачивается по
  правилу. В цепочке Xray фрагментация TLS от `freedom` идёт тому звену,
  которое выходит наружу. `listen_port` WireGuard уступает detour, который
  дописала сборка. Узел, который ядро не умеет (Tailscale без `with_tailscale`,
  поля AmneziaWG 3.x на старом ядре), снимается на сборке с кодом. Бэкап несёт
  предупреждения автогруппы; узел, выключенный после отказа ядра, при импорте
  остаётся выключенным.
- **Цепочка со звеном REALITY больше не запрещает сохранение при снятом uTLS.**
  Редактор показывает предупреждение вместо блокировки Save, строка strip
  читается `kept`, сборка оставляет uTLS на всех звеньях. Список strip и
  уровень AmneziaWG рядом с протоколом (`awg2`, `awg1.5+`) берутся из контракта.
- **Язык шаблона следует контракту 1.1.68–1.1.82.** Ветка-список `#if` в
  массиве вливается в родителя, `@runtime.*` снимает ключ, а не утекает в
  конфиг, предупреждения шаблона несут параметры и не дублируются, DNS-сервер
  без адреса снимается с предупреждением, шаблонные DNS-серверы видят все
  переменные шаблона.
- **Внутреннее.** Схемы ссылок, файлы протоколов и таблица версий SOCKS
  читаются только из реестра контракта; обёртки парсеров по протоколам
  удалены. Документ контракта `CANON.md` переименован в
  `PARSING_PRINCIPLES.md`. Поведение не меняется.

## 🩹 Исправления

- **Правила Wi-Fi читают имя сети так, как ждёт Android 12+.** Имя и BSSID
  приходят из сетевого callback с данными о местоположении; старый вызов
  остаётся запасным на Android 11 и старше. При выключенном Wi-Fi Add current
  говорит «Not connected to Wi-Fi.» вместо жалобы на разрешения.
- **Правила Wi-Fi объясняют, почему не могут прочитать имя сети.** Android
  скрывает имя без ошибки, если местоположение «Приблизительное» или системный
  переключатель Location выключен. Add current открывает диалог разрешения с
  подсказкой о точном местоположении или предлагает настройки Location;
  Diagnostics показывает оба состояния. Причина пишется в logcat под тегом
  `WifiInfoReader`.
- **Импортированные узлы сохраняют присланное провайдером.** `multiplex`,
  `udp_over_tcp`, параметры соединения, `workers` и `listen_port` WireGuard,
  тюнинг QUIC и дополнительные поля транспортов доезжают до конфига как есть.
  Узлы Xray больше не получают `server_name`, которого провайдер не задавал;
  ссылка VMess с `aid=0` не пишет `alter_id: 0`. Outbound `socks` у Xray
  становится узлом, а нечитаемый outbound Xray отмечается отброшенным, а не
  исчезает молча.
- **Ссылка на цепочку открывает цепочку.** Тап по цепочке в окне узла или в
  окне зацикленного detour показывал «Source not found in your lists». Теперь
  открывается редактор цепочки; сохранённая правка применяется к работающему
  туннелю.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.25.6-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and subscriptions
are preserved.

---

Previous release / Предыдущий релиз: [v2.25.5](docs/releases/v2.25.5.md).
