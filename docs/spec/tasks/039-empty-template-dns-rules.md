# 039 — Empty template DNS rules: drop catch-all, fall through to dns.final

| Поле | Значение |
|------|----------|
| Статус | Implemented |
| Дата | 2026-05-06 |
| Связанные spec'ы | [`041 dns rules refactor`](../features/041%20dns%20rules%20refactor/spec.md), [`033 preset bundles`](../features/033%20preset%20bundles/spec.md), [`038 ru-direct-dns-defaults`](./038-ru-direct-dns-defaults.md) |
| Файл изменений | `app/assets/wizard_template.json`, `app/lib/screens/dns_settings_screen.dart` |
| Inline-rename | tag `direct_dns_resolver` → `google_udp` (3 места в template: server tag + 2 `domain_resolver` refs от google_doh / google_doh_vpn). Симметрия с `cloudflare_udp` именованием. Existing-юзеры с saved DNS-серверами не затрагиваются (их `_servers` storage independent от template); юзеры с template-defaults на следующем rebuild получат новый tag. Saved sing-box config независим от template — продолжает работать со старым tag'ом до явного rebuild'а. |

## Цель

Убрать template-level catch-all DNS rule. Всё что не матчится preset/inline DNS-правилами должно явно идти через `dns.final` (= переменная `@dns_final`, default `local_dns_resolver`, юзер может override'нуть через wizard).

| Поле | Было | Стало |
|---|---|---|
| `dns_options.rules` (template) | `[{name: "Default → Google DoH", enabled_default: true, server: "google_doh"}]` | `[]` |

**`dns.final` — переменная, не статика.** В template'е line 371: `"final": "@dns_final"`. Сама `dns_final` определена как wizard-var (line 256-263) с `default_value: "local_dns_resolver"`. Юзер через wizard может выбрать любой server tag из `dns_options.servers[]` — `direct_dns_resolver`, `cloudflare_udp`, `google_doh`, и т.д. **Default подобран на стабильность** (system resolver не stale'ит), не на encryption — кому нужно DoH-везде, выберет в wizard'е.

## Root cause

Текущее catch-all правило `{server: google_doh}` без matcher'ов матчит **всё** что не подошло предыдущим правилам. Эффективно — то же что `dns.final`, но статически приколочено к `google_doh` (HTTPS/443 DoH).

В живой эксплуатации (см. предыдущий [task 038](./038-ru-direct-dns-defaults.md) и observation 2026-05-06) всплывают два разных кейса деградации DoH:

1. **Long idle → DoH connection pool stale** — sing-box кеширует TCP/TLS до DoH endpoint'а; после долгого idle (sleep/wake, NAT timeout) re-dial отваливается. `resetNetwork()` вручную через Reload восстанавливает.
2. **DPI на 443 / source-IP filter у DoH-провайдера** — endpoint в природе живой, но через нашу путь через VPN/cellular блокируется (как было с yandex_doh @ 77.88.8.88 в РФ).

Обе ловятся **прицельно** на конкретное DoH-имя. UDP в той же ситуации обычно живёт. `dns.final = local_dns_resolver` — системный resolver Android'а, через PlatformInterface; не имеет stale-state, не зависит от нашего Go-runtime networking.

## Что не делаем (и почему)

| Альтернатива | Почему отвергнуто |
|---|---|
| Сменить catch-all на `cloudflare_udp` (1.1.1.1 UDP/53) | в РФ 1.1.1.1 чаще DPI-режется чем 8.8 / system |
| Сменить на `google_udp` (8.8.8.8 UDP/53) | глобально OK, но через VPN-tunnel может маршрутизироваться неоптимально + некоторые ISP режут |
| Сделать **несколько** template default'ов с приоритетом | sing-box DNS не поддерживает rule-level fallback chain; первый match завершает поиск, дальше не идёт. См. [§043 C-discussion](../features/043%20applog%20per-source%20quotas/spec.md) — сделать через external reactor (§042 watchdog), не через config-only. |
| Auto-fallback DoH→UDP на runtime (`fallback_servers`) | sing-box 1.13 не имеет такого field'а в стандартном build'е |

## Эффект на existing users

Auto-discovery в [`resolveDnsRulesList`](../../../app/lib/services/builder/post_steps.dart) (метод orphan cleanup):

```dart
} else if (kind == 'template') {
  final name = entry['name'] as String?;
  if (name == null || name.isEmpty) continue;
  if (templateNames.contains(name)) {
    seenTemplateNames.add(name);
    result.add(entry);
  }
  // else — silently dropped из storage
}
```

При следующем `rebuild-config`:
1. В storage юзера лежит запись `{enabled, kind: template, name: "Default → Google DoH"}`.
2. `templateNames` (computed из template `dns_options.rules[]`) пустой.
3. `name` not in `templateNames` → entry **silently dropped**.
4. Финальный sing-box config больше не содержит catch-all `{server: google_doh}` rule.
5. Все non-matched queries идут через `dns.final = local_dns_resolver`.

Никакой migration logic не нужно — orphan cleanup в `resolveDnsRulesList` это делает автоматически. Single rebuild = clean state.

**Юзеры с активными preset'ами** (например ru-direct) — preset DNS-правила сохраняются (kind:preset), они работают по своим matcher'ам. Unmatched (всё что не .ru) идёт в `local_dns_resolver`.

**Юзеры с inline custom DNS rules** — kind:inline сохраняются как было. Unmatched — через тот server, который юзер выбрал в `@dns_final` (default `local_dns_resolver`).

## Trade-offs

| Аспект | До | После |
|---|---|---|
| Catch-all transport | DoH (HTTPS/443) | System DNS (UDP/53 via Android resolver) |
| Encryption catch-all | DNS-over-HTTPS encrypted | Cleartext (зависит от того что Android system DNS делает — обычно cleartext UDP) |
| Stale-connection bug | DoH pool stale → Reload required | системный resolver state-less, не подвержен |
| Privacy | Google видит весь fall-through traffic | ISP видит fall-through queries (через cellular/wifi DNS) |
| Failure mode | google_doh dial timeout → query dies | system DNS отвечает почти всегда (Android ретраит сам) |

**Privacy regress** для catch-all — заметный. Mitigation: юзер хочет DoH-encrypted всё подряд → добавляет inline rule `{}` (без matcher'ов = catch-all) с server=`google_doh` через UI. Это явный opt-in вместо template-default'а.

## Verification

1. Удалить app data / fresh install → Subs → activate any → `GET /config` → `dns.rules` содержит только preset/inline-rules (если есть), нет template-catch-all. `dns.final = "local_dns_resolver"`.
2. Existing user upgrade → `POST /action/rebuild-config` → `GET /state/storage` → в `dns_options.rules` нет записи с `name = "Default → Google DoH"`. `GET /config` → no catch-all rule.
3. Long-idle test (раньше воспроизводилось): connect VPN → phone в карман 30+ min → wake → попытка browse. Раньше DoH-pool deg'ил, теперь системный resolver не должен залипать.
4. **UI dropdown'ы на DNS settings screen** (DNS Final / Default Domain Resolver / per-rule server selector) видят теги из preset-expanded servers активных preset'ов (e.g. yandex_udp / yandex_doh от ru-direct). До fix'а dropdown показывал только template + user-saved servers; preset-добавленные не появлялись и юзер не мог выбрать `dns_final = yandex_udp`.

## UI fix details

`app/lib/screens/dns_settings_screen.dart` — `_enabledServerTags` getter:

| Источник | Поле | До fix'а | После fix'а |
|---|---|---|---|
| Template defaults / user-saved | `_servers` | ✅ | ✅ |
| Preset-expanded (active custom_rules.kind:preset) | `_presetServersWithLabel` | ❌ | ✅ |

Реализация — Set с дедупом (tag-collisions resolve'ятся first-wins на build-стороне, см. `dns_options.servers` дедуп в `post_steps.dart`). Все три dropdown'а (DNS Final / Default Domain Resolver / per-rule server) теперь подкачивают полный список доступных в текущей конфигурации DNS-серверов.
