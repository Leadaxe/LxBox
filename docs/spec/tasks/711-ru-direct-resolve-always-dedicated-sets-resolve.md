# 711 — Resolve через dns_ru у ru-direct не зависит от Force IPv4; Dedicated server ставит «Resolve before routing»

| Field | Value |
|-------|-------|
| Status | Done |
| Start date | 2026-11-04 |
| End date | 2026-11-04 |
| Commits | — |
| Related specs | §684 (ru-direct, dns_ru), §683 (секция DNS & Resolve), §247 (resolve-правило), §246/§253 (`#if` в массивах правил) |

## Problem

Сообщение paratroop3r 04.11.2026 (Telegram, со скриншотами Diagnostics):
с включённым FakeIP пресет «Ru internet segment» не резолвит ру-домены через
dns_ru, когда галка Force IPv4 снята — `dial direct → lookup gosuslugi.ru →
dns group dns_shield`.

Диагностика. В `wizard_template.json` у пресета `ru-direct` route-правило
`{rule_set: [ru-domains, ru-services], action: resolve, server: dns_ru,
strategy: ipv4_only}` целиком обёрнуто в `#if @force_ipv4`. При снятой галке
выпадает всё правило, а не только `strategy`. Дальше:

- DNS-правило пресета «ru → dns_ru» на вкладке DNS обрабатывает только
  запросы приложений. Если FakeIP стоит выше (пользователь переставил), он
  отвечает фейковым адресом первым, до правила пресета очередь не доходит.
- Соединение приходит в маршрутизацию с доменом (восстановлен из FakeIP),
  матчится `ru-domains → direct-out`, и direct-out резолвит домен сам —
  через Default Domain Resolver (dns_shield). Выбранный пользователем
  Yandex DNS не участвует.

Трафик при этом идёт верно (direct). Теряется только выбор DNS-сервера
для ру-зоны: профиль Yandex Base/Safe/Family, ру-GeoDNS.

Галка Force IPv4 обещает только IPv4 (подсказка: «Resolve Russian domains
to IPv4 only»), а фактически выключает и сервер резолва.

`ru-inside` не затронут: его resolve без `server`, при снятой галке правило
ничего не добавляет к поведению outbound'а.

Та же развилка у пользовательского правила: «Answer: Dedicated server → X»
эмитит только DNS-правило (mirror), а route-resolve эмитится отдельной
галкой «Resolve before routing» с собственным сервером в Advanced
(`custom_rules.dart`, `_resolveToRoute` / `dnsMirrors`). Пользователь,
выбравший Dedicated под FakeIP, получает тот же эффект: сервер не
используется, dial идёт через Default Domain Resolver.

## Solution

Решение владельца 04.11.2026.

### 1. Шаблон: ru-direct

`app/assets/wizard_template.json`, пресет `ru-direct`, `rules[0]`:
resolve-правило эмитится всегда, под галкой только поле `strategy`
(map-spread `#if` внутри правила, как `"#if wg"` у tunnel-ingress):

```json
{
  "rule_set": ["ru-domains", "ru-services"],
  "action": "resolve",
  "server": "dns_ru",
  "#if": {"#and": ["@force_ipv4"], "#value": {"strategy": "ipv4_only"}}
}
```

- Галка on: правило как раньше, байт в байт.
- Галка off: `{rule_set, action: resolve, server: dns_ru}` — стратегия общая
  (`dns.strategy`). AAAA-правило `predefined NOERROR` в `dns_rules` остаётся
  под `#if @force_ipv4` как есть.
- Подсказка var `force_ipv4` не меняется: она и так обещает только IPv4.
- `ru-inside` не трогать.

### 2. Редактор правила: Dedicated server ставит «Resolve before routing»

`app/lib/screens/custom_rule_edit/edit_controller.dart`:

- `setDnsAnswerMode(DnsAnswerMode.dedicated)` и `setDnsServerTag(tag)`
  (выбор сервера в Answer) **всегда** включают резолв (`_resolve` как в
  `setResolveFirst(true)`) и ставят `resolve.serverTag` = сервер из Answer.
  Без условий «что было раньше»: одно действие — один результат (слово
  владельца). Strategy и остальные Advanced-поля не трогаются.
- При `resolveOnly` (Action = Resolve only) резолв уже включён — только
  подставить сервер.
- Галку «Resolve before routing» пользователь после этого может снять
  руками (`setResolveFirst(false)` работает как прежде).
- Переход Answer на Default / Fixed IP резолв не выключает и сервер не
  сбрасывает.
- Существующие правила в хранилище не меняются, миграции нет.
  Гидрация правила с Dedicated без resolve оставляет всё как есть.

UI `dns_resolve_section.dart` не меняется: галка и Advanced сами отразят
состояние контроллера.

### Не делаем

- Автоэмиссию route-resolve в сборке по `dns.serverTag` — связка живёт
  только в редакторе.
- Миграции, контракт с лаунчером (identity пресета и поля не меняются).

## Verification

- `app/test/services/builder/preset_expand_test.dart`: тесты
  «force_ipv4=false → resolve-элемент выпадает» и «ru-direct: force_ipv4=false
  → route без resolve» переписать под новое поведение: при off —
  `routingRules.length == 2`, `[0] == {rule_set: …, action: resolve, server:
  'ru-direct:dns_ru'}` без ключа `strategy`; `dnsRules` без AAAA-гейта как
  раньше. Фикстура `_ruDirectForceIpv4()` — та же форма, что в шаблоне.
  Тест с дефолтом (on) — без изменений.
- `app/test/screens/custom_rule_edit/dns_resolve_section_test.dart` (или
  новый `edit_controller_dns_dedicated_test.dart`): выбор Dedicated →
  `resolve != null`, `resolve.serverTag == выбранный`; смена сервера в Answer
  меняет `resolve.serverTag`; снятие галки после — `resolve == null`;
  Dedicated при уже включённом resolve с другим сервером → сервер
  перезаписан, strategy сохранена; snapshot правила содержит `resolve`.
- Гоняются только затронутые файлы тестов.
- Телефон владельца: ru-direct с Force IPv4 off и FakeIP выше → Diagnostics
  `lookup gosuslugi.ru` через `dns_ru`, не `dns_shield`.

## Documentation

- `docs/USER_GUIDE.md`: у Force IPv4 пресета — одна фраза, что галка меняет
  только семейство адресов, резолв через Yandex DNS идёт всегда; у
  «Dedicated server» — что выбор включает «Resolve before routing».
- CHANGELOG Unreleased (EN+RU).
