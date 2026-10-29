# 694 — условие правила «тип сети» и «лимитная сеть»

| Поле | Значение |
|------|----------|
| Статус | Done (эмулятор проверен; телефон не проверен) |
| Дата начала | 2026-10-29 |
| Источник | issue #178 (@usgrnk): условие «сейчас мобильная сеть», чтобы экономить трафик, без разрешения на геолокацию, которое нужно для Wi-Fi SSID; решение владельца — тип сети и лимитность одним заходом, с полной проверкой, ядро не трогать, пока эмулятор не докажет, что ловушку фолбэка у нас не закрыть |
| Связанные | §051/§053 (wifi-условия и секция WI-FI NETWORK), §087 (сброс соединений на смену интерфейса), §692 (`dnsLayerEligible`) |

## Проблема

Ядро умеет `network_type` (wifi / cellular / ethernet / other) и
`network_is_expensive` в правилах роутинга, DNS-правилах и headless
rule_set (`option/rule.go:170`, `option/rule_dns.go:165`,
`option/rule_set.go:269`); allowlist контракта их пропускает. Но в
редакторе правила их нет — работают только через сырой JSON правила.
Условие по SSID требует разрешения на точную/фоновую геолокацию, а
пользователю нужно только «мобильная сеть или нет».

Матчер ядра (`route/rule/rule_item_network_type.go`,
`rule_item_network_is_expensive.go`) берёт
`NetworkManager.DefaultNetworkInterface()` — интерфейс по умолчанию,
найденный по индексу в списке, который отдал `getInterfaces` Kotlin-стороны
(`PlatformInterfaceWrapper.buildInterfaces`). `Expensive` в этом списке =
`metered` (`!NET_CAPABILITY_NOT_METERED`, уже передаётся) **или**
`isExpensive` из `updateDefaultInterface` (у нас всегда `false`; в
обёртке libbox `w.isExpensive` к тому же не присваивается — мёртвое поле,
рабочий путь один: `metered`).

Ловушка: если интерфейс по умолчанию не нашёлся в списке
(`route/network.go`, `DefaultNetworkInterface`), ядро возвращает голый
`NetworkInterface{Interface: *iif}`: `Type` = 0 = `wifi`, `Expensive` =
false. В такой момент сотовая сеть читается как Wi-Fi. Список
перечитывается при каждом `updateDefaultInterface`
(`monitor.go: m.networkManager.UpdateInterfaces()`), а
`DefaultNetworkListener` шлёт обновление и на `onCapabilitiesChanged`,
поэтому окно — только гонка: сеть уже по умолчанию, но
`getLinkProperties`/`getNetworkCapabilities` для неё ещё `null` или
`NetworkInterface.getByName` её ещё не видит. Проверяется на эмуляторе.

## Решение

### Модель и запись

- В `CustomRuleInline` и `CustomRuleSrs` два поля: `networkTypes`
  (`List<String>`, значения ядра `wifi`/`cellular`/`ethernet`/`other`;
  пусто = условия нет) и `networkIsExpensive` (`bool`).
- Тело записи (`rule_record.dart`): ключи ядра `network_type` (список) и
  `network_is_expensive: true` рядом с `wifi_ssid`, оба в
  `kRuleBodyKeys`. Пустой список / `false` не пишутся — правило без
  условия читается и пишется байт в байт как раньше, миграции нет.
  Правило-запись inline, у которой эти ключи раньше были незнакомыми (и
  делали её дословным JSON), теперь читается типизированной.
- Debug API правил: `network_type` (список) и `network_is_expensive`
  в сериализаторе и в PATCH/POST — для проверки и автоматизации.

### Сборка

- inline: оба поля в headless-наборе правила, рядом с `wifi_ssid`
  (ядро принимает в `DefaultHeadlessRule`).
- srs: на routing-rule рядом с `wifi_ssid`, и в DNS-зеркале (`srsMatch`)
  — DNS-правило ядра принимает оба поля.

### DNS-слой (§692)

`network_type` и `network_is_expensive` — состояние устройства, известное
в момент DNS-запроса (как `wifi_ssid`). Ядро считает headless-подправило
с ними «не чисто IP» (`isNonIPCIDRHeadlessRule`: всё, кроме
`ip_cidr`/`ip_set`/`invert`), значит DNS-ссылка на такой набор не
отвергается. Решение: оба поля входят в `dnsLayerEligible` и
`dnsSectionVisible` наравне с wifi. Правило «только Cellular» (без
домена) с DNS-опцией матчит все DNS-запросы, пока сеть сотовая, — это и
есть смысл условия.

### Редактор

Секция «WI-FI NETWORK» → «NETWORK»:

- сверху выбор `Any / Wi-Fi / Cellular / Ethernet` (Any = поля нет);
- список SSID/BSSID с кнопками — только при Wi-Fi (Cellular + SSID —
  противоречие); подсказка о разрешениях — тоже только при Wi-Fi;
- переключатель «Metered networks only» → `network_is_expensive: true`;
- подсказка в стиле соседей: «AND with match. Active only on the
  selected network type.»

Правила выбора и сохранения:

- Загрузка: `network_type: [wifi]` → Wi-Fi; пусто и есть SSID/BSSID →
  Wi-Fi (SSID и так означает Wi-Fi); пусто → Any; `cellular` / `ethernet`
  → соответствующий сегмент. Значение, которое выбор не выражает
  (`other`, несколько типов из сырого JSON), — ни один сегмент не
  выделен, значение сохраняется как было, пока его не поменяли.
- Сохранение: Any → `network_type` нет и SSID/BSSID сняты; Wi-Fi со
  списком SSID → `network_type` как был загружен (пусто или `[wifi]`,
  байт в байт), Wi-Fi без списка → `[wifi]`; Cellular / Ethernet →
  `[cellular]` / `[ethernet]`, SSID/BSSID сняты. Пока экран открыт,
  список SSID при переключении сегментов не теряется — снимается только
  при сохранении.

### Kotlin

- `DefaultNetworkMonitor`: в `updateDefaultInterface` идёт настоящий
  `isExpensive = !caps.hasCapability(NET_CAPABILITY_NOT_METERED)` (и в
  `notifySync`, и в `checkUpdate`). На матчер это не влияет (рабочий путь —
  `metered` списка), но аргумент перестаёт лгать.
- Повторная нотификация на смену capabilities уже есть
  (`DefaultNetworkListener.onCapabilitiesChanged` → `checkUpdate` →
  `updateDefaultInterface` → ядро перечитывает список).

## Риски и граничные случаи

- Открытые соединения: правило проверяется при открытии соединения.
  При смене интерфейса (Wi-Fi ↔ сотовая) §087 сбрасывает соединения,
  новые идут уже по новому типу (на эмуляторе подтверждено). Смена
  лимитности: если Android переподключает сеть (на эмуляторе так при
  «нелимитный → лимитный»), соединения сбрасываются так же; если только
  меняет флаг («лимитный → нелимитный»), открытые соединения живут со
  старым решением до переподключения.
- DNS-кэш: ответ, полученный на одной сети, может отдаваться из кэша на
  другой.
- Фолбэк ядра «неизвестный интерфейс = wifi» — см. «Проверка».

## Проверка

Тесты: кодек (круг без условия байт в байт; круг с условием), сборка
(inline headless, srs routing + DNS-зеркало), `dnsLayerEligible`,
контроллер редактора (загрузка/сохранение по правилам выше).

Эмулятор: правило «домен + Cellular → Reject», переключение Wi-Fi ↔
сотовая (`svc wifi`, `svc data`), матч по логу/Debug API; metered через
`cmd netpolicy`; поведение открытых соединений; ловушка фолбэка.

## Итог

Сделано по «Решению». Секция в редакторе называется «NETWORK», прямо над
ней — «NETWORK & PROTOCOL» (L4/L7); имена различимы по подсказке, но
соседство может путать — если путает, переименовать в «NETWORK TYPE».

Тесты (точечно, 155 — зелёные): `record_codec_test`, `custom_rules_test`,
`rule_dns_mirror_test`, новый `screens/custom_rule_edit/network_choice_test`.
`flutter analyze` по затронутым файлам — чисто. APK собран на CI
(run 40950756505, ветка `build/694-network-type`; хост был под нагрузкой).

Эмулятор (AVD LxBox_test, Android 14; Wi-Fi = `wlan0` AndroidWifi,
сотовая = `eth0` T-Mobile, лимитная), узлов нет, всё прочее — direct.
Правила через Debug API: `1.1.1.1/32 + network_type [cellular] → reject`,
`1.0.0.1/32 + network_is_expensive → reject`; контроль `104.16.132.229`.
Проба — HTTP-запрос из `adb shell` через `toybox nc` (просто TCP-connect
не годится: под TUN рукопожатие завершает само ядро, «открыто» даже без
сети).

| Сеть по умолчанию | 1.1.1.1 (cellular) | 1.0.0.1 (metered) | контроль |
|---|---|---|---|
| сотовая (лимитная) | отказ | отказ | ответ |
| Wi-Fi нелимитный | ответ | ответ | ответ |
| Wi-Fi лимитный (`cmd netpolicy set metered-network`) | ответ | отказ | ответ |
| Wi-Fi снова нелимитный | ответ | ответ | ответ |

- Сборка: headless-наборы `{"ip_cidr":[…],"network_type":["cellular"]}` и
  `{…,"network_is_expensive":true}`, routing — `rule_set` + `reject`.
- Ловушка фолбэка (интерфейс по умолчанию не в списке → «wifi»): не
  воспроизвелась. 3 цикла `svc wifi disable/enable`, проба сразу после
  того, как `LxBoxNet` сообщил новый интерфейс: на сотовой 3/3 отказ, на
  Wi-Fi 3/3 ответ. По коду окно закрыто и так: `checkUpdate` зовёт
  `updateDefaultInterface` только когда интерфейс уже виден в
  `NetworkInterface.getByName`, а ядро внутри этого вызова перечитывает
  список (`UpdateInterfaces`). Ядро не трогали.
- Открытое соединение (HTTP keep-alive, второй запрос через 10 с):
  без переключения — 2 ответа; сотовая → Wi-Fi и Wi-Fi → сотовая
  посреди соединения — 1 (сброшено); Wi-Fi «нелимитный → лимитный» — 1
  (Android переподключил Wi-Fi, сеть по умолчанию ~5 с была сотовой);
  «лимитный → нелимитный» — 2 (только смена флага, соединение живёт).
- DNS-зеркало правила «только `network_type`» (сервер google_udp): ядро
  принимает (`check-config` ok, туннель поднимается).
- Редактор: сегменты Any / Wi-Fi / Cellular / Ethernet, при Wi-Fi —
  список SSID и кнопки, флажок «Metered networks only»; открыть правило
  и выйти без правок — диалога «Unsaved changes» нет.

Не проверено: телефон; Ethernet; ловушка фолбэка на реальном железе с
медленным появлением интерфейса.
