# §312 — DNS-группы: полный UI над kernel DNS_GROUP

**Тип:** фича
**Статус:** спека согласована (решения юзера 26.07.2026), реализация
**Ядро:** sing-box-lx SPEC 033/035, feature DNS_GROUP; в пине `v1.14.0-lx.16-rc.3` (без build-tag; state-RPC за `with_lx_command` — наши сборки с ним)
**Связано:** §294 (typed refs `dns_options.servers`), §117 (редактор DNS-сервера, форс-инклюд пресетных/правильных тегов), §121/§219 (validator dangling refs), §208/§209 (образец pool-RPC и null-контракта), §311 (образец CC-обвязки; `/help`-урок), §254 (циклы → fatal до старта ядра)

---

## 1. Что даёт ядро

Новый тип DNS-сервера:

```json
{ "type": "group", "tag": "public",
  "servers": ["google", "cloudflare", "quad9"],
  "mode": "stable", "error_ttl": "2m", "win_ttl": "5m" }
```

| Ключ | Значения | Дефолт | Смысл |
|---|---|---|---|
| `servers` | теги DNS-серверов, ≥1 | обязателен | члены; порядок НЕ значим |
| `mode` | `stable` · `fastest` · `parallel` | `stable` | липкий выбор / победитель гонки / всегда веером |
| `error_ttl` | duration | `2m` | жизнь записи об ошибке члена |
| `win_ttl` | duration | `5m` | жизнь победы; только `fastest`, иначе warning в лог ядра |

Fatal на старте ядра: пустой `servers`, дубликаты, самовключение, члены типов `fakeip`/`hosts`, циклы групп, unknown mode. Группа принимается всюду, где ждут тег DNS-сервера (`dns.final`, `server_tag` правил, `route.default_domain_resolver`). Вложенные группы разрешены.

Наблюдаемость (`getDNSGroups()`, javap rc.3 подтверждён — `DnsGroupIterator`/`DnsGroup`/`DnsGroupMember`): по группе `mode`/`current`/члены `{tag, serverType, clean, liveErrors, lastErrorAgeMs, liveWins, current, lastRttMs}`.

## 2. Ключевое решение: НЕ новый kind в storage

Группа = **обычный inline-ref** (§294) с `body.type == "group"`:

- storage-схема не меняется → нет миграции, §221 backup-симметрия автоматом,
  Debug `PUT /settings/dns_options/servers` работает как есть;
- эмиссия inline body as-is уже существует;
- инвариант §291 «не мигрировать форму storage».

Весь объём — UI-форма поверх body, эмиссионный фильтр, валидация, live-статус.

## 3. Решения юзера (26.07)

| Вопрос | Решение |
|---|---|
| Форма | 4-й тип в существующем редакторе; переключатель типов → **дропдаун**, если 4 сегмента не влезают |
| Live-статус | pull **на открытии экрана** (+ null-контракт §209); без таймера |
| Недоступный член (disabled/dangling) | **выкидывать при сборке конфига** с warning в `emitWarnings`+AppLog; storage НЕ трогаем — при обратном включении член «встаёт на место». Пустая группа после фильтра → **fatal validator** |
| Debug API | отдельного endpoint'а НЕТ — группы видны в общем списке серверов с деталями (UI) |

## 4. Эмиссия — фильтр членов

[post_steps/dns_servers.dart](../../../../app/lib/services/builder/post_steps/dns_servers.dart)
`resolveDnsServersBodies` — **пост-проход** после сборки `out` (доступность
члена зависит от ПОЛНОГО списка эмитящихся, включая стоящих ниже):

```
emittedTags = out[].tag
для каждого body с type == "group":
  servers → [для каждого m: m ∈ emittedTags && m != self && не дубль]
  каждый выброшенный m → warning "DNS group '<tag>': member '<m>' dropped (…)"
```

Причины дропа различаются в тексте: `disabled` (тег есть в refs, но не
эмитится) / `unknown` (тега нет вовсе) / `self` / `duplicate`. Пустой
`servers` после фильтра эмитится пустым — ловит validator (fatal), молча
чинить нельзя.

Warnings текут существующим каналом `emitWarnings` (сноска-снекбар §105 +
AppLog) — «ворчание в лог» по решению юзера.

## 5. Validator (fatal — до старта ядра, зеркало ядра)

[validator.dart](../../../../app/lib/services/builder/validator.dart), новые issues:

| Issue | Условие |
|---|---|
| `EmptyDnsGroup` | `type==group` и `servers` пуст (в т.ч. после эмиссионного фильтра) |
| `BadDnsGroupMember` | член указывает на сервер типа `fakeip`/`hosts` |
| `DnsGroupCycle` | цикл по рёбрам группа→член (DFS, аналог §254 detour-циклов) |

Dangling-члены validator НЕ проверяет: эмиссия их уже выкинула; путь
`PUT /config` мимо билдера прикрыт валидацией самого ядра.

## 6. CC-обвязка live-статуса (образец §208/§209/§311)

```
CcChannel.getDnsGroups() → 'ccGetDnsGroups' → BoxCommandClient.getDnsGroups()
  Future<List<CcDnsGroup>?>        VpnPlugin, IO       ensurePingClient + runCatching
  null = недоступен (down/старое ядро/Unimplemented); [] = групп нет
```

Модели в [cc_channel.dart](../../../../app/lib/vpn/cc_channel.dart):
`CcDnsGroup{tag, mode, current, members}` /
`CcDnsGroupMember{tag, serverType, clean, liveErrors, lastErrorAgeMs, liveWins, current, lastRttMs}`.
Kotlin сериализует итераторы в `List<Map>` (образец `getPool`).

## 7. UI

### Редактор ([dns_server_edit/](../../../../app/lib/screens/dns_server_edit/))

- `kDnsServerModes` → `['udp','tls','https','group']`; переключатель типов —
  дропдаун при нехватке ширины (решение №1).
- Секция группы (вместо host/port): мультивыбор членов из `dnsServerTags`
  (без самого себя; `fakeip`/`hosts` не предлагаются), mode-селектор с
  пояснением каждого режима, поля `error_ttl`/`win_ttl` (duration-формат
  `NNs|NNm|NNh`, валидация); `win_ttl` видим только при `fastest`.
- Член с `enabled:false` в пикере виден и выбираем, но помечен
  «disabled — will be skipped» (drop-семантика решения №3).
- JSON-вкладка остаётся источником правды: форма парсит/сериализует `body`
  (паттерн `edit_controller`).

### Список ([dns_settings_screen](../../../../app/lib/screens/dns_settings_screen.dart))

Группа — в общем списке серверов (решение №4). Бейдж `GROUP · <mode> · N`.
При живом туннеле — детали из pull'а на открытии экрана:

```
public   GROUP·stable   → current: cloudflare
  google ✓ 12ms   cloudflare ✓ 8ms ●   quad9 ✗2 (34s ago)
```

`clean` → ✓/✗ + liveErrors, `current` → маркер, `lastRttMs` (>0),
`fastest` — ещё liveWins. `null` от RPC → строка не рисуется.

## 8. Вне скоупа

Пресет-/template-группы; Debug-endpoint состояния групп; автообновление
статуса таймером; hedged-режимы ядра (их нет).

## 9. Тесты

1. Эмиссия: дроп disabled / unknown / self / дубля (+ warning-тексты);
   пустая группа НЕ чинится молча; порядок и прочие серверы не задеты.
2. Validator: `EmptyDnsGroup`, `BadDnsGroupMember` (fakeip/hosts),
   `DnsGroupCycle` (A→B→A и самоцикл после ручного JSON).
3. Edit-controller: body↔форма round-trip (mode-дефолт `stable` не пишется?
   — пишется как есть: пишем только заданное юзером, дефолты не
   материализуем), `win_ttl` сохраняется при переключении режимов, но
   эмитится только введённый.
4. CcChannel: null-контракт + маппинг полей.
5. l10n: новые ключи в `assets/l10n/ru/ui.json` (en = ключ), `ui_check`
   зелёный.

## 10. Device-verify

1. Создать группу из 2–3 серверов → плашка → рестарт → резолв жив;
   `GET /config` содержит group-блок.
2. Отключить члена → пересборка: warning в снекбаре/AppLog, конфиг валиден,
   группа без члена; включить обратно → член вернулся.
3. Отключить всех членов → сборка блокирована fatal'ом validator'а.
4. Live-статус на экране при живом туннеле: current/чистота/RTT совпадают
   с логом ядра.
5. `dns.final` → группа: убить upstream текущего члена → резолв переехал
   (лог ядра «смена текущей цели», info).
