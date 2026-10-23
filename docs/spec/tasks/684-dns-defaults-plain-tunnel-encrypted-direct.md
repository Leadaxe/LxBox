# 684 — Дефолты Направлений DNS-серверов: UDP через туннель, DoT/DoH напрямую

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата начала | 2026-10-24 |
| Связанные спеки | [682](682-dns-catalog-revision-and-copy.md) — vars `outbound` у всех серверов каталога; решение 682 №2 («разнобой не трогать») **отменено** этой задачей |

## Решение владельца (24.10.2026)

Одно правило для всех DNS-серверов шаблона, включая серверы пресетов:

- нешифрованный (UDP) — по умолчанию **через туннель** (`vpn-1`);
- шифрованный (DoT, DoH) — по умолчанию **напрямую** (`direct-out`);
- у каждого сервера, у которого есть путь, — var Направления (выбор).

Рекомендация в подсказках DNS Final и Default Domain Resolver — любой
шифрованный прямой: `google_doh` или `cloudflare_dot`.

Владелец знает и принимает: шаблонные записи берут дефолты из шаблона на
каждой сборке, поэтому у всех, кто var не трогал, конфиг меняется; группа
`dns_shield` (6 шифрованных членов) становится целиком прямой.

## 1. Каталог `dns_options.servers`

| Тег | Тип | Было | Станет |
|---|---|---|---|
| `google_udp` | udp | direct-out | **vpn-1** |
| `cloudflare_udp` | udp | direct-out | **vpn-1** |
| `opendns_udp` | udp | direct-out | **vpn-1** |
| `google_dot` | tls | vpn-1 | **direct-out** |
| `cloudflare_dot` | tls | vpn-1 | **direct-out** |
| `quad9_doh` | https | vpn-1 | **direct-out** |
| `google_doh`, `opendns_doh`, `yandex_dot`, `safe_dns_dot` | | direct-out | без изменений |

Описания, где путь зашит в текст, привести к правде (и в l10n
`assets/l10n/{ru,zh}/template.json`):

- «Google DNS (direct)» → «Google UDP»;
- «OpenDNS UDP (direct)» → «OpenDNS UDP»;
- «Quad9 DoH (via VPN, anti-malware)» → «Quad9 DoH (anti-malware)»;
- «Yandex DoT (direct)» → «Yandex DoT».

Путь в описании больше не пишется — он выбирается var'ом и виден в редакторе.

`safe_dns_dot`: var `dom_resolver` по умолчанию `google_udp` → **`google_doh`**
(шифрованный, прямой, адрес-IP — сам резолва не требует; иначе резолв
AdGuard-хоста шёл бы через туннель).

## 2. Пресет `ru-direct` (`selectable_rules`, «Ru internet segment»)

Сейчас `yandex_udp` берёт `detour` из var пресета `outbound` (Направление
маршрута русского трафика), `yandex_dot` зашит на `vpn-1`, `yandex_doh` —
напрямую без var.

Станет — два новых var пресета (рядом с `dns_ip`, видимы, когда
`dns_enable` включён — по образцу условий видимости соседних var):

| var | Заголовок | Тип | Дефолт | Серверы |
|---|---|---|---|---|
| `dns_plain_outbound` | UDP DNS outbound | outbound | `vpn-1` | `yandex_udp` |
| `dns_encrypted_outbound` | Encrypted DNS outbound | outbound | `direct-out` | `yandex_dot`, `yandex_doh` |

`yandex_udp` перестаёт следовать `outbound` маршрута. Описания:
`yandex_dot` «Yandex Safe DoT (via vpn-1)» → «Yandex Safe DoT»,
`yandex_doh` «Yandex Safe DoH (direct)» → «Yandex Safe DoH», группа
`dns_ru` «RU DNS group (UDP via direction + DoT via vpn-1 + direct DoH)» →
«RU DNS group (UDP + DoT + DoH)». Tooltip `dns_ip` («Applies to UDP only…»)
— без изменений.

## 3. Подсказки DNS Final и Default Domain Resolver

Тексты в `app/lib/screens/dns_settings_tab.dart` (tooltip `ResolverPicker`)
и tooltip var `dns_final` / `dns_default_domain_resolver` в шаблоне — один
смысл:

- `dns_shield` — по умолчанию, гонка шифрованных провайдеров напрямую;
- рекомендуемые: `google_doh`, `cloudflare_dot` — шифрованные, напрямую;
- UDP-серверы ходят через туннель: для DNS Final — допустимо, для Default
  Domain Resolver — нет (недоступны до поднятия туннеля, см. ⚠ §682 п. 3);
- `local_dns_resolver` — как сейчас.

Дефолты `dns_final` / `dns_default_domain_resolver` = `dns_shield` — без
изменений.

## Проверка

- Тест `wizard_template_dns_vars_defaults_test.dart` (§682: «байт в байт
  как раньше») переписать на новую норму: разрешённые тела с дефолтами —
  UDP с `detour: vpn-1`, DoT/DoH без `detour`.
- Golden-конфиг меняется намеренно — обновить эталон и в коммите
  перечислить, какие `detour` изменились (ничего сверх таблиц выше).
- Валидатор шаблона (`template_check`) зелёный.
- Эмулятор: у дефолтного резолвера `dns_shield` значка ⚠ нет; выбор
  `google_udp` в Default Domain Resolver показывает ⚠.
