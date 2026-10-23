# 683 — Редактор правила: секция «DNS & Resolve», «Resolve only» в Action, ответ фиксированным IP

| Поле | Значение |
|------|----------|
| Статус | In progress — макет согласован владельцем 23.10.2026 |
| Дата начала | 2026-10-23 |
| Связанные спеки | [247](247-custom-rule-resolve-action.md) — resolve-опция правила, окно «Action & Resolve»; [256](256-rule-force-ipv4-dns.md) — Force IPv4; [117F](117F-dns-rework/spec.md) — DNS-зеркало правила (задача 3); [682](682-dns-catalog-revision-and-copy.md) |

## Проблема

1. Пользователи часто спрашивают про hosts: «этот домен → этот IP». Сейчас так
   можно только Custom rule (JSON) на вкладке DNS.
2. Настройки резолва правила разбросаны: DNS-сервер и Force IPv4 — в секции
   DNS редактора, Resolve first / Resolve only, стратегия, свой сервер и
   advanced-поля — в окне «Action & Resolve» за шестерёнкой ⚙ у Action.
   Окно неочевидно, два выбора DNS-сервера в одном правиле путают.

## Решение (владелец, 23.10.2026)

Окно «Action & Resolve» и шестерёнка ⚙ **убираются**. Всё про резолв —
в одной секции «DNS & Resolve» внизу редактора (на месте секции DNS).
Action наверху остаётся на месте и отвечает только за то, куда идёт трафик.

### 1. Action (наверху, без ⚙)

```
┌ Action ─────────────────────── ▾ ┐
│ direct                            │
└───────────────────────────────────┘
   direct / vpn-1 / … / Reject / Resolve only
```

- В список Action (`OutboundPicker`, `params_tab.dart`) добавляется пункт
  **Resolve only** — после Reject. Только у правил с `resolveEligible`
  (inline с доменами / srs), как сейчас ⚙.
- Выбор Resolve only = `resolve.only = true`; выбранное до этого
  направление в модели сохраняется (как сейчас, §247), при выборе
  направления обратно `only = false`.
- В поле Action при `only` показывается «Resolve only».
- Inline-статус под Action (`✳ Resolve only …`) снимается: состояние видно
  в самом поле и в секции DNS & Resolve.

### 2. Секция «DNS & Resolve»

```
DNS & RESOLVE
How domains matched by this rule are resolved.

Answer
 ◉ Default — queries go to DNS Final
 ○ Dedicated server   [google_doh ▾]
 ○ Fixed IP
     ┌ IP address ──────────────────┐
     │ 192.168.1.10                  │  +
     └───────────────────────────────┘

☐ Force IPv4 (drop AAAA)
    Answer AAAA (IPv6) queries locally so matched traffic uses IPv4.
☐ Resolve before routing
    Look up the address before routing, so IP rules and the address
    family apply.
    [Strategy ▾]

▸ Advanced
```

**Answer** — радио, один из трёх:

| Вариант | Модель | Эмиссия |
|---|---|---|
| Default | `dns.enabled = false`, `fixedIps` пуст | DNS-зеркала нет (как сейчас без галки) |
| Dedicated server | `dns.enabled = true`, `serverTag` | как сейчас «Send DNS to dedicated server» |
| Fixed IP | `dns.fixed = true`, `fixedIps` непуст | п. 3 |

Переход между вариантами не теряет значения других (serverTag хранится и
при `enabled: false`, как сейчас; `fixedIps` хранится, но эмитится только
при выбранном Fixed IP — см. модель ниже).

**Поле Fixed IP** (решение владельца: «+ делает из однострочного поля
многострочное»):
- по умолчанию однострочное поле «IP address» с кнопкой `+` справа;
- `+` превращает его в многострочное «IP addresses» (одна строка — один
  адрес) и ставит курсор на новую пустую строку; подсказка под полем
  «One address per line, IPv4 or IPv6.»;
- вставка текста с несколькими строками сразу делает поле многострочным;
- при открытии правила с одним адресом — снова однострочное с `+`;
- пустые строки игнорируются; строка, не разбираемая как IPv4/IPv6
  (`InternetAddress.tryParse`), подсвечивает поле ошибкой с номером строки,
  Save блокируется — по образцу поля «Port range» того же экрана.

**Force IPv4** — как сейчас (§256). При Fixed IP неактивен (ответы даёт
само правило).

**Resolve before routing** — бывший «Resolve first» (§247, `resolve != null
&& !only`). Под ним Strategy (бывший Strategy окна, `(inherit DNS strategy)`
по умолчанию). Если Action = Resolve only — галка показана включённой и
неактивной, подпись «Action is Resolve only».

**Advanced** — свёрнут по умолчанию. Переезжают как есть все поля окна:
DNS server для резолва (`(auto — route DNS)` по умолчанию), Disable cache,
Disable optimistic cache, Rewrite TTL, Query timeout, Client subnet.
Активны, только когда резолв включён (Resolve before routing или Resolve
only); иначе неактивны с подписью «Used when the rule resolves before
routing.»

**Гейт портов/протоколов** — как сейчас: Answer и Force IPv4 неактивны с
текущей подписью «Unavailable with port/protocol filters…». Resolve before
routing и Advanced от гейта не зависят (как сейчас в окне).

**Подсказка для srs** («Works only if the rule-set contains domains…») —
при Dedicated server и при Fixed IP.

### 3. Эмиссия Fixed IP

DNS-зеркало правила (тот же матч, что у server-mirror: `srsMatch` /
`mirrorBody` в `post_steps/custom_rules.dart`), serverless, на месте
server-mirror. Ядро (`rule_action.go`, `rewriteRecords`) подставляет имя
запроса в запись с именем, начинающимся на `*`, если имя запроса
оканчивается остатком; `*.` подходит любому имени.

- есть IPv4: `{…match, "query_type": ["A"], "action": "predefined",
  "rcode": "NOERROR", "answer": ["*. IN A <ip>", …]}`;
- есть IPv6: то же с `"AAAA"` и `"*. IN AAAA <ip>"`;
- адресов одного семейства нет — для этого типа запроса
  `predefined` + `NOERROR` без `answer` (приложение берёт другое
  семейство);
- остальные типы запросов правило не трогает.

TTL записей — 300 с (`*. 300 IN A <ip>`). Исполнитель проверяет, что ядро
lx.23 разбирает такие записи (`option` → `dns.NewRR`), прогоном
`check`-валидации конфига или юнит-тестом корпуса.

Направление трафика к подставленному адресу — Action правила как обычно.

### 4. Модель и хранение

- `RuleDns` (`models/custom_rule.dart`) — два новых поля:
  `fixedIps: List<String>` (ключ `fixedIps`, пишется только непустым) и
  `fixed: bool` (ключ `fixed`, пишется только `true`). Режим Answer:
  `fixed && fixedIps.isNotEmpty` → Fixed IP; иначе `enabled` → Dedicated
  server; иначе Default. Выбор Fixed IP ставит `fixed = true,
  enabled = false`; выбор Dedicated — `enabled = true, fixed = false`;
  Default — оба `false`. Адреса и serverTag при переключении хранятся.
  Имена ключей — camelCase, как у соседних (`serverTag`, `forceIpv4`).
- `dnsMirrorActive` / гейт / `_toggleRuleForceIpv4` на вкладке DNS —
  учесть новый режим: карточка правила в блоке «From routing rules»
  вкладки DNS показывает строку `action: predefined · answer: <ip>, …`
  с ✕ (снять = Answer → Default).
- `RuleResolve` не меняется.
- Бэкап: `rule.dns` уже `additionalProperties: true`. Новые ключи пишутся
  в файл; поддержка — LxBox. **Контракт:** запрос лаунчеру объявить
  `dns.fixedIps` и `dns.fixed` в `backup.schema.json` (поддержка: LxBox,
  лаунчер игнорирует молча) — оформляет координатор после реализации,
  синк контракта отдельным коммитом.

### 5. Что убирается

- `custom_rule_edit/action_resolve_sheet.dart` и его вызов
  (`onOpenActionResolve`), шестерёнка ⚙ в `params_tab.dart`.
- Отдельная секция DNS (`sections/dns_section.dart`) заменяется секцией
  DNS & Resolve (файл можно переименовать или переписать).
- Строки l10n окна, которые больше не используются, удалить из словарей
  ru/zh; новые — добавить.

## Проверка

- Юнит: эмиссия Fixed IP (только v4, только v6, оба; inline и srs; рядом
  с Force IPv4 — неактивен), режимы Answer в модели, round-trip хранения
  (`fixedIps` + `fixed`), старые записи без новых ключей читаются как
  раньше.
- Golden-конфиг без новых полей не меняется байт в байт.
- Эмулятор: правило `nas.home` → Fixed IP 192.168.1.10, Action direct;
  в превью View и в карточке вкладки DNS виден predefined; Resolve only
  выбирается в Action; Resolve before routing + Strategy + Advanced
  сохраняются и эмитят тот же `resolve`, что раньше давало окно.
