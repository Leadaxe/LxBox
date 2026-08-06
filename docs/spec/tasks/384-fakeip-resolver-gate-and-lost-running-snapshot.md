# §384 — FakeIP под resolver-ссылками + неснимаемая плашка «Config changed»

| Поле | Значение |
|------|----------|
| Статус | Done, DEVICE-VERIFIED (эмулятор `LxBox_test`, Android 14) |
| Дата старта | 2026-08-06 |
| Дата завершения | 2026-08-06 |
| Связанные spec'ы | [§312](../features/312%20dns%20groups/spec.md) — тот же запрет ядра для членов DNS-групп; [§324](324-staleness-verdict.md) — вердикт свежести, теряющий собеседника; [§311](311-running-config-from-kernel.md) — снапшот running config |

## Проблема

Два репорта пользователя (Telegram, 06.08.2026), оказавшиеся связанными.

> Не пропадает плашка об изменении конфига. Версия актуальная

> Плюс, к этому — позволяет выбрать fakeip, как днс, но не запустить с ним

Гипотеза пользователя о причине первого репорта:

> Пустые поля финального днс и резолвера по дефолту, когда ничего не выбрано

Гипотеза **не подтвердилась**: `DnsController.load` подменяет пустое значение
template-дефолтом ([`dns_controller.dart:227`](../../../app/lib/services/dns/dns_controller.dart)),
в конфиг «ничего не выбрано» не утекает. Реальная причина — другая, см. ниже.

## Баг A — fakeip/hosts под `dns.final` / `route.default_domain_resolver`

### Диагностика

Ядро запрещает fakeip как default-сервер. Device-факт, `/state`:

```
last_start_error = 'Stopped: Failed to start service: start or reload service:
                    initialize DNS server[15]: default server cannot be fakeip'
```

Запрет тот же, что §312 держит для членов DNS-групп (`BadDnsGroupMember`), но
для resolver-ссылок его не проверял никто:

| Слой | Что проверял | Дыра |
|---|---|---|
| UI-пикеры | `enabledServerTags(displayed)` — фильтр только по `enabled` | тип сервера не смотрит → fakeip в списке |
| Валидатор | `DanglingDnsServerRef` — существует ли тег | тип не проверяет вовсе |
| Ядро | тип проверяет | fatal уже **после** старта |

Итог ровно как в репорте: выбрать можно, конфиг соберётся, ядро не стартует.

### Фикс

1. **Валидатор** — новый fatal-issue `BadResolverServerType`
   ([`validation.dart`](../../../app/lib/models/validation.dart),
   [`validator.dart`](../../../app/lib/services/builder/validator.dart)).
   Считается там, где `dnsTypeByTag` уже построена. Валидатор — главный слой:
   UI-фильтр не покрывает импортированные и правленные вручную конфиги.
2. **UI** — отдельный список `resolverTags` для двух `ResolverPicker`
   ([`dns_settings_screen.dart`](../../../app/lib/screens/dns_settings_screen.dart)).
   `enabledServerTags` НЕ трогаем: его потребляют и per-rule пикеры, где
   fakeip законен (`{"query_type": ["A","AAAA"], "server": "fakeip"}` — штатный
   способ включить FakeIP из preset'а).

### Verify

```
POST /action/rebuild-config →
{"error":{"code":"upstream_error","message":"generate failed: Config invalid:
 dns.final cannot use \"fakeip\": a \"fakeip\" server is not allowed as a resolver."}}
```

Отказ до старта, с внятной причиной, вместо падения ядра.

## Баг B — вечная плашка: потерянный снапшот running config

### Диагностика

Плашку гасит §324: сравнить сохранённый конфиг с каноническим снапшотом
работающего. Снапшот берётся из `HomeState.runningConfigRaw`; нет снапшота →
вердикт `unknown` → **плашка остаётся** (консервативный дефолт §324).

Снапшот теряется в `_captureRunningConfig`
([`home_controller.dart`](../../../app/lib/controllers/home_controller.dart)).
После reload'а захват ждёт ответ, **отличный** от прежнего снапшота — защита
§311 от ещё-не-подменённого box'а (device-факт 26.07). Но если reload прошёл
на **байт-в-байт идентичный** конфиг, отличного ответа не будет никогда:

```
[cc] running config unavailable after 12 attempts
running_config_length = None   ← до конца сессии
```

Дальше каждое сохранение получает `unknown`, и плашка неснимаема:

```
[vpn] §324 staleness=unknown → need_restart=true
[vpn] §324 staleness=unknown → need_restart=true
```

Типовой путь пользователя: подписка отдаёт тот же список нод → пересборка →
reload → снапшот потерян → любое следующее изменение вешает вечную плашку.
Ровно этот сценарий §323 уже чинил на уровне текстового диффа, но §324-ветка
осталась незакрытой.

### Фикс

Попытки исчерпаны, а ядро всё это время стабильно отвечало одним и тем же
документом → через ~5с после успешного reload'а это уже не «box ещё не
подменён», а «новый box крутит идентичный конфиг» — законный ответ. Коммитим
его (`echoedRaw`) вместо потери снапшота. Epoch-гейт §311 сохранён.

### Verify (эмулятор, оба состояния)

| Шаг | До фикса | После |
|---|---|---|
| reload без изменений | `running config unavailable after 12 attempts`, `running_len=None` | `running config unchanged after reload (271697 bytes)`, снапшот жив |
| затем: изменение → откат | `staleness=unknown` → `need=true` (вечно) | `staleness=stale` → `fresh`, `need=false` |
| штатный reload с изменением | `captured` | `captured` — без регрессии |

## Связь двух багов

Баг A — самостоятельный (ядро не стартует). Баг B — самостоятельный
(теряется снапшот). Связка в репорте объясняется тем, что неудачный старт
из-за A тоже оставляет `runningConfigRaw = null`: `_checkStaleness` возвращает
`unknown` уже на раннем `running == null || running.isEmpty`. То есть пока
конфиг не стартует по причине A, плашка не гаснет в принципе — пользователь
видел оба симптома как один.

## Тесты

[`test/builder/dns_group_test.dart`](../../../app/test/builder/dns_group_test.dart) —
группа `§384 resolver type gate`, 5 кейсов: fakeip под `dns.final`, hosts под
`default_domain_resolver`, чистый случай, пустые/отсутствующие ссылки,
разграничение с `DanglingDnsServerRef`.

Полный прогон: 2952 теста, `flutter analyze` чист.
