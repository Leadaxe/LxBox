# §354 — ru-DNS через группу: три независимых пути вместо одного канала

**Тип:** таска
**Статус:** реализовано, DEVICE-PENDING (см. §7 п.5)
**Связано:** §312 (DNS-группы, kernel SPEC 033), §319 (у группы нет `detour`), §033 (expansion пресетов), §117 (нормализация detour), SPEC 046 (мёртвый DNS-detour морозит пересылку)

---

## 1. Проблема

Пресет `ru-direct` резолвит все ru-домены через **один** DNS-сервер, и по
умолчанию это `yandex_udp` с `detour: @outbound` — тем же каналом, которым
пресет гоняет трафик.

Полевой случай: в `@outbound` выбран `vpn-2`, в канале — нода с пингом −1.
Итог — каждый ru-запрос висит до таймаута, а какое-то приложение долбит этот
путь раз в 5 секунд. Отдельная опасность: по SPEC 046 мёртвый DNS-detour
способен подвесить пакетный цикл целиком, а не только DNS.

Корень — **единственная точка отказа**: все три объявленных в пресете сервера
завязаны на один и тот же `@outbound` (кроме `yandex_dot`, у которого `vpn-1`
захардкожен), и в конфиг едет ровно один из них.

## 2. Решение

Три члена по **непересекающимся** путям отказа + группа `fastest` над ними:

```
                  ru-домены (.ru/.su/IDN + ru-services)
                                │
                    ┌───────────▼───────────┐
                    │  dns_ru  (type=group) │
                    │  mode: fastest        │
                    │  error_ttl 5m / win 5m│
                    └───────────┬───────────┘
                ┌───────────────┼───────────────┐
                ▼               ▼               ▼
         yandex_udp        yandex_dot       yandex_doh
         udp :53           tls :853         https :443
         @dns_ip           77.88.8.88       77.88.8.88
         detour @outbound  detour direct    detour @dns_tunnel
         (канал)           (НАПРЯМУЮ)       (vpn-1 по умолчанию)
                │               │               │
          путь отказа 1   путь отказа 2   путь отказа 3
          мёртвая нода    DPI режет 853   мёртвый vpn-1
          в канале        у провайдера
```

Мёртвая нода в канале убивает только первый член — два других отвечают,
ru-сегмент жив. `fastest` отсекает мёртвого по гонке, `error_ttl: 5m` держит
запись об ошибке.

**Почему DoH, а не второй DoT:** 443 маскируется под обычный HTTPS, 853 у ряда
провайдеров режется. Два DoT дали бы общий путь отказа — ровно то, от чего
уходим.

**Почему не «поле запасного DNS»** (исходная формулировка задачи): пикер
`dns_servers` строит список только из `preset.dnsServers`
([preset_params_tab.dart:305](../../../app/lib/screens/custom_rule_edit/tabs/preset_params_tab.dart)),
поэтому `dns_shield` (глобальный список шаблона) и `local` в дропдауне
ru-direct недоступны. Группа решает ту же задачу лучше: fallback не статичный
и покрывает все члены сразу.

## 3. Блокер, найденный в коде

[preset_expand.dart:413](../../../app/lib/services/builder/preset_expand.dart)
фильтрует `dns_servers` **до одного** — с `tag == vars['dns_server']`.
Группа приехала бы в конфиг без членов → эмиссионный фильтр §312 выбросил бы
все три тега как unknown → `EmptyDnsGroup` (fatal, сборка заблокирована).

Правка — при выборе группы эмитить её вместе с членами:

```
selected = varsMap['dns_server']
emit = {selected}
если body(selected).type == 'group':
    emit ∪= body.servers            // одноуровнево
для s in preset.dnsServers где s.tag ∈ emit:
    substitute → normalizeDnsDetour → add
```

Порядок: группа первой, члены следом. Дедуп по тегу уже делает
`mergeFragments`. Вложенные группы внутри пресета не разворачиваются —
в шаблоне их нет, а ядро вложенность поддерживает само.

## 4. Изменения в шаблоне

`dns_servers` пресета `ru-direct`:

| тег | было | стало |
|---|---|---|
| `yandex_udp` | `detour: @outbound` | без изменений |
| `yandex_dot` | `detour: vpn-1` (хардкод) | `detour: direct-out` — прямой путь |
| `yandex_doh` | `detour: @outbound` | `detour: @dns_tunnel` |
| `dns_ru` | — | новый: `group`, `fastest`, три члена |

Тег `yandex_dot` **сохранён** — переименование орфанило бы ссылки у тех, кто
выбрал его вручную.

Новая var:

```jsonc
{"name": "dns_tunnel", "type": "outbound", "default_value": "vpn-1",
 "title": "DoH channel",
 "tooltip": "Channel that carries encrypted DoH queries. Keep it different from the main outbound so one dead node cannot stall Russian DNS."}
```

`dns_server`: `default_value` `yandex_udp` → `dns_ru`.

`rules` / `dns_rules` / `rule_set` не трогаются — они ссылаются на
`@dns_server`, а группа принимается везде, где ждут тег сервера (§312 §1).
Force IPv4 и `action: resolve` продолжают работать через тот же `@dns_server`.

## 5. Миграция — не делаем (решение юзера)

По [preset_expand.dart:118](../../../app/lib/services/builder/preset_expand.dart)
`default_value` применяется, только если ключа в `varsValues` нет. Кто дропдаун
не трогал — получит `dns_ru` автоматом. У кого лежит explicit
`"dns_server": "yandex_udp"` — останется старое поведение до ручного
переключения в UI. Осознанный компромисс: миграция ради одного значения не
оправдана.

## 6. Риски

| Риск | Митигация |
|---|---|
| `direct-out` у DoT нормализуется в vpn_mode → два пути схлопываются в один | **проверено:** `vpn_mode` правит inbounds/route, DNS-detour не трогает; единственная нормализация — `knownOutbounds` в [dns_servers.dart:366](../../../app/lib/services/builder/post_steps/dns_servers.dart), снимает detour у пропавшего канала. Отсутствие ключа = «напрямую» во всех режимах |
| Группа приезжает пустой при отключённых членах | эмиссионный фильтр §312 + `EmptyDnsGroup` ловит до старта ядра |
| `detour` у группы → ядро падает на лишнем ключе | §319 уже чистит в `normalizeDnsDetour` |

## 7. Критерии проверки

Тесты — [preset_expand_test.dart](../../../app/test/services/builder/preset_expand_test.dart),
группы «§354 dns_server == группа» и «§246 e2e» (на реальном шаблоне):

1. ✅ `expandPreset` при `dns_server: dns_ru` → 4 сервера: группа + три члена.
2. ✅ При `dns_server: yandex_udp` — по-прежнему ровно один (регрессия §033).
3. ✅ У группы нет `detour` (§319); у `yandex_dot` detour снят (direct-out);
   три пути: `vpn-2` / без detour / `vpn-1`.
4. ✅ Сквозь эмиссионный фильтр §312: группа доезжает с тремя членами, дропов
   и warning'ов нет (главный риск — пустая группа → `EmptyDnsGroup` fatal).
5. ✅ `default_value` применяется, когда юзер не трогал дропдаун.
6. ⏳ **Device:** ru-домен резолвится при мёртвой ноде в `@outbound`; в
   `getDNSGroups()` видно переключение `current` на живого члена.

Пре-флайт: `flutter test` 2729 ✅, `flutter analyze` чисто, 4 l10n-чекера
(`template_check` / `ui_check` / `hardcoded_check` / `kotlin_check`) — 0.
