# §324 — Плашка restart по сравнению с работающим ядром (canonical diff)

| | |
|---|---|
| Статус | ✅ Реализовано (DEVICE-PENDING) |
| Дата | 2026-07-31 |
| Связанные | [`323 on-update action`](323-subscription-on-update-action.md), [`311 running config from kernel`](311-running-config-from-kernel.md), [`116 banner mechanism`](116-banner-mechanism-and-config-banner-fix.md), [`030 vpn reload button`](030-vpn-reload-button.md), kernel SPEC 037/038 |

## Проблема

Плашка «restart to apply» отвечает не на тот вопрос, который задаёт.

Сейчас ([config_io.dart:73](../../../app/lib/controllers/home_controller/config_io.dart)):

```dart
changed = _state.configRaw.isEmpty ||
    canonicalJsonForSingbox(canonicalJson) !=
        canonicalJsonForSingbox(_state.configRaw);
```

Это дифф **saved vs saved**: новый собранный конфиг против последнего, который
приложение само записало. Отвечает на «изменился ли файл», тогда как плашка
утверждает «работающее ядро устарело».

`canonicalJsonForSingbox` нормализует только синтаксис (JSON5-комментарии,
хвостовые запятые, отступы). Ни сортировки ключей, ни семантических допущений:
`jsonEncode` пишет в порядке вставки парсера.

§323 добавил гейт «состав не изменился → гасим плашку», но гейт стоит на этом же
диффе и потому не срабатывает, когда конфиг отличается косметически.

### Что делает дифф ложноположительным

| Источник | Файл | В конфиг попадает |
|---|---|---|
| **mixed-case SNI** (§028) | [tls_transforms.dart:13](../../../app/lib/services/builder/post_steps/tls_transforms.dart) | `Random.secure()` на КАЖДОЙ сборке рандомит регистр `server_name` у всех first-hop TLS-нод. Для ядра конфиги эквивалентны (RFC 6066 — SNI case-insensitive), для байтового диффа — всегда разные |
| Порядок `outbounds` | [build_config.dart:264](../../../app/lib/services/builder/build_config.dart) | чистая конкатенация, порядок нод = порядок от провайдера. Провайдер переставил — дифф сработал |
| Суффиксы `allocateTag` | [build_config.dart:530](../../../app/lib/services/builder/build_config.dart) | `X` / `X-1` раздаются first-come-first-served: порядок обработки флипнулся → теги поменялись местами |
| Пути к `.srs` | [custom_rules.dart:326](../../../app/lib/services/builder/post_steps/custom_rules.dart) | абсолютный путь + entry вообще выпадает, если кэш ещё не скачан |

Метки времени в конфиг не попадают (только в storage). WARP/AWG junk — константы
(`jc/jmin/jmax`), сам junk генерит ядро.

**Следствие:** у пользователя с включённым mixed-case SNI `changed` истинен
всегда. Гейт §323 для него мёртв, плашка возвращается раз в час.

## Решение

Спросить ядро, а не угадывать. Ответ команды ядра (запрос от 31.07.2026):

```
stale ⟺ FormatConfig(наш текст + override) != GetRunningConfig().Content()
```

`captureRunningConfig` (`daemon/instance_command_lx.go`) и `FormatConfig`
(`experimental/libbox/config.go:254`) используют **один парсер и один энкодер**
(`json.NewEncoder` + `SetIndent("", "  ")`). Это сделано намеренно — kernel SPEC
037 §3: снапшот использует тот же энкодер, что `FormatConfig`, чтобы форма
совпадала с той, которую клиент уже знает.

Поэтому вся нормализация (порядок полей, `omitempty`, `[] → null`) сворачивается
**внутри ядра**. Список «различий, которые игнорируем» на клиенте не нужен и
разъехаться нечему — правила живут в том же коде, который их применяет.

Заодно это снимает и наши источники нестабильности из таблицы выше: разный
регистр SNI даёт разные канонические формы **честно** (для ядра это разные
строки — но одинаково работающие), а вот порядок полей и omitempty больше не
шумят.

### Почему НЕ через `<base>/configuration.json`

Ядро упомянуло дешёвый пре-фильтр: `StartOrReloadService` пишет сырой текст в
`<base>/configuration.json` до старта, и сравнение «новый текст vs этот файл»
(оба через `FormatConfig`) отвечает, ничего не зная про override — они
одинаковы с обеих сторон и сокращаются.

**Не берём.** Файл отвечает на «совпадает ли с последним ОТПРАВЛЕННЫМ», а не с
работающим. Расходится в реальном сценарии: Apply → сохранили → reload
провалился → файл говорит «применено», ядро крутит старое, плашки нет — а она
нужна. Плюс файл существует для крэш-репортов, спекой не покрыт, `os.WriteFile`
best-effort с проглоченной ошибкой, на первом запуске может отсутствовать.

Ступень 2 отвечает точно и во всех случаях; ступень 1 экономила бы один RPC в
час ценой второго пути в коде и зависимости от негарантированного файла.

### Почему НЕ ручная нормализация на клиенте

Рассматривалась (сортировка ключей + `[]`≡`null` + `outbounds` как множество +
lowercase SNI). Отклонена: любой такой список неизбежно разъедется с ядром.
`FormatConfig` даёт то же бесплатно и точно.

## Зеркалирование `OverrideOptions`

`FormatConfig` override **не применяет**, а снапшот — post-override
(`newInstance` мутирует options до захвата, `daemon/instance.go:122`). Значит
override накладываем сами, иначе получим вечный «stale» — та же плашка раз в час
по новой причине.

Ядро применяет так (`daemon/instance.go:92-101`):

```go
for _, inbound := range options.Inbounds {
    if tunInboundOptions, isTUN := inbound.Options.(*option.TunInboundOptions); isTUN {
        tunInboundOptions.AutoRedirect = overrideOptions.AutoRedirect
        tunInboundOptions.IncludePackage = append(tunInboundOptions.IncludePackage, overrideOptions.IncludePackage...)
        tunInboundOptions.ExcludePackage = append(tunInboundOptions.ExcludePackage, overrideOptions.ExcludePackage...)
        break
    }
}
```

Четыре грабли, названные ядром:

1. **только ПЕРВЫЙ TUN inbound** — в цикле `break`, не все;
2. `AutoRedirect` — **присваивание**, перетирает значение профиля;
3. `IncludePackage`/`ExcludePackage` — **`append`**, не replace: пакеты профиля
   остаются, override дописывается ПОСЛЕ них. Порядок значим для байтового
   сравнения — не мержить и не сортировать;
4. **нет TUN inbound → override не применяется вообще.**

Плюс `Listable[string]` с ОДНИМ элементом сериализуется **голой строкой**, не
массивом из одного (`sing/common/json/badoption/listable.go`); ноль элементов —
ключ опущен. Реплицировать это правило не надо: строим текст с добавленными
пакетами и отдаём в `FormatConfig` — правило применится само с обеих сторон.

### Что мы реально кладём в override

По [BoxService.kt:676](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt)
(`buildOverrideOptions`) — меньше, чем позволяет API:

| Поле | Что кладём |
|---|---|
| `autoRedirect` | `BootReceiver.isAutoRedirect` (persistent-флаг, default false, UI-тоггла нет) |
| `includePackage` | **только** свой пакет, **только** в allow-режиме (определяется наличием `include_package` у первого tun-inbound) |
| `excludePackage` | **не используем никогда** |

Поэтому зеркало на Dart-стороне узкое: в allow-режиме дописать свой пакет в
конец `include_package` первого tun-inbound; выставить `auto_redirect` по флагу.

**Инвариант (по образцу §221).** Список override-полей живёт в ДВУХ местах:
`buildOverrideOptions` (Kotlin) и зеркало (Dart). Добавили четвёртую докрутку в
native — обязаны отразить здесь, иначе компаратор молча начнёт врать. Тест
проверяет соответствие списков.

## OOM killer

Если OOM-killer включён и в `options.Services` ещё нет сервиса типа
`oom-killer`, ядро дописывает его (`daemon/instance.go:102-115`). Проверка по
типу, поэтому **если объявить сервис в профиле самим — ядро ничего не дописывает
и зеркалить нечего.**

Поля `KillerDisabled`/`MemoryLimitOverride` помечены `json:"-"`
(`option/oom_killer.go:13-14`) — в канонический документ не попадают, сервис
рендерится ровно как `{"type":"oom-killer"}`.

### Device-факт 01.08.2026: без этого вердикт ВСЕГДА `stale`

Первая редакция §324 писала «это и делаем», но в билдере сервис не объявлялся —
шаблон вообще не имел секции `services`. На устройстве (Liberty, ручной ⟳) это
дало `staleness=stale` при чисто косметической разнице:

```
running: services: [{"type":"oom-killer"}]      ← дописано ядром, в saved нет
running: address: "172.16.0.1/30"               ← saved: ["172.16.0.1/30"] (Listable)
running: strict_route: null                     ← saved: false (omitempty)
```

Вторые два расхождения `formatConfig` сворачивает сам, а `services` — нет: он
работает с текстом и про SetupOptions не знает. Одна лишняя секция ⇒ вердикт
никогда не `fresh` ⇒ вся задача §324 бесполезна.

Исправлено: `services: [{"type": "oom-killer"}]` объявлен в
`assets/wizard_template.json` рядом с `experimental`. Безопасно безусловно —
`BoxApplication.kt:108` ставит `oomKillerEnabled = true` жёстко, без флага, так
что ядро дописывало бы сервис при любых настройках.

**Не** через `SetupOptions`-зеркало: OOM-killer управляется не конфигом, а
`SetupOptions` (§271), и «вычитать» секцию на стороне клиента — тот самый
клиентский список различий, от которого §324 и уходит.

## Версионный блок ⚠️

`GetRunningConfig` возвращает **объект**, не строку:

```go
func (c *CommandClient) GetRunningConfig() (*RunningConfig, error)
func (c *RunningConfig) Content() string
```

Breaking change: в `v1.14.0-lx.16` возврат голой строкой убивал ядро на
android/arm64 в `bulkBarrierPreWrite` (kernel SPEC 038 — gomobile пакует
cgo-фрейм, слот nstring-результата оказывается 4-байтово выровнен, write barrier
требует 8). `[]byte` не спасает — та же форма фрейма. Нужен
**`v1.14.0-lx.16-rc.3` или новее** и вызов `Content()`.

### `.content()` уже на месте — правка не требуется

Первая редакция этой спеки утверждала, что обвязка не зовёт `.content()` и §311
поэтому мёртв. **Это неверно.** `BoxService.commandClient` — не libbox-класс, а
наша обёртка `BoxCommandClient`; её `getRunningConfig()` возвращает `String?` и
зовёт `.content()` внутри
([BoxCommandClient.kt:532](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxCommandClient.kt)).
Сделано при бампе на lx.17-rc.1, device-verified 27.07.2026 (см. `KERNEL.md`).

Ошибка возникла из javap по libbox-классу (`CommandClient.getRunningConfig()`
действительно возвращает объект `RunningConfig`) без проверки, кого зовёт
`VpnPlugin`. Урок: смотреть тип **вызываемого** объекта, а не одноимённого
метода в .aar.

### Грабля javap-диагностики

Рядом с `libbox.aar` в `app/android/app/libs/` лежит **устаревший**
`classes.jar`, оставшийся от чьей-то распаковки. Сборка его не использует
(`implementation(files("libs/libbox.aar"))`), но javap по нему даёт ложную
картину: `getRunningConfig` и класс `RunningConfig` «отсутствуют». Хеши
`classes.jar` и `libbox.aar!/classes.jar` не совпадают.

**Проверять только вложенный:**

```bash
unzip -p app/android/app/libs/libbox.aar classes.jar > /tmp/c.jar
javap -classpath /tmp/c.jar io.nekohasekai.libbox.CommandClient | grep -i running
```

## Реализация

| Слой | Файл | Что |
|---|---|---|
| Native | `VpnPlugin.kt` | handler `formatConfig` → `Libbox.formatConfig(text).value` (статик, работает без живого сервиса). No-throw обёртка: на любой сбой → null |
| Native | `VpnPlugin.kt` | `ccGetRunningConfig` — при бампе ядра перевести на `RunningConfig.Content()` |
| Dart | `box_vpn_client.dart` | `Future<String?> formatConfig(String)` — null = ядро не смогло (не фатально) |
| Dart | новый `services/config_staleness.dart` | зеркало override + сравнение двух канонических форм. Чистые функции, без I/O — тестируемо |
| Dart | `config_io.dart` | `saveParsedConfig` спрашивает staleness вместо saved-vs-saved диффа |
| Dart | `home_controller.dart` | точки, где сейчас гасится/ставится `configChangedNeedRestart` |

### Контракт деградации

`formatConfig` или `GetRunningConfig` вернули null — ответить не можем.
Деградируем **консервативно**: считаем изменённым, плашку показываем. Ядро
подтвердило, что консервативный дефолт корректен.

Ответы ядра:

| Ответ | Значение | Что делаем |
|---|---|---|
| `FailedPrecondition` | сервис не STARTED | устаревать нечему — плашки нет |
| `Unavailable` | снапшот не захвачен (attached-путь `service/api` не захватывает) | ответить нельзя → консервативно |
| `Unimplemented` | сборка без `with_lx_command` | то же |

### Сила утверждения

Не криптографическое равенство: в принципе два разных исходных текста могут дать
одну каноническую форму. Это **желаемое** поведение — такие тексты поднимают
идентичное ядро и плашки не заслуживают. Схема никогда не скажет «не
изменилось», когда семантика изменилась.

## Тесты

- зеркало override: allow-режим → пакет дописан В КОНЕЦ `include_package`
  первого tun-inbound; deny → не дописан; нет tun-inbound → конфиг не тронут;
  два tun-inbound → тронут только первый;
- `auto_redirect` присваивается, а не мержится;
- список override-полей совпадает с `buildOverrideOptions` (инвариант выше);
- деградация: `formatConfig`/снапшот null → «изменилось» (консервативно);
- регресс §324: mixed-case SNI даёт разные тексты → канонические формы тоже
  разные (документируем: эту эквивалентность `FormatConfig` НЕ сворачивает; если
  надо гасить и её — отдельная задача про детерминизм SNI).

## Device-verify

Kernel SPEC 037 §5: последний критерий приёмки — проверка полей со стороны
LxBox — **не отмечен. Этот RPC ни разу не гонялся на живом устройстве
клиентом.** Ядро просит: если что-то разойдётся — прислать обе канонические
формы.

1. Живой туннель, пересборка с тем же составом нод → канонические формы
   совпали → плашки нет.
2. Реальная правка (сменить ноду) → формы разошлись → плашка есть → Apply
   работает.
3. Allow-режим (per-app whitelist) → формы совпали. Это главная проверка
   зеркала override: без него здесь вечный «stale».
4. Deny-режим → тоже совпали (пакет не дописан).
5. Reload провалился → ядро на старом конфиге → плашка осталась.
6. Туннель down → `FailedPrecondition` → плашки нет.

## Docs to update

- `CHANGELOG.md` — Unreleased.
- `docs/ARCHITECTURE.md` — новый контракт «клиент спрашивает ядро о staleness».
- `docs/KERNEL.md` — минимальная версия ядра + `Content()`-брейк.
- §311 — снять инвариант «снапшот не участвует в diff'ах»: он был верен для
  сравнения с сырым файлом, но не для пары канонических форм.
