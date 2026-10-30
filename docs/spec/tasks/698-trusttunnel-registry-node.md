# 698 — Контракт 1.1.141/1.1.142: узел `trusttunnel` из реестра, DNS-серверы бэкапа по тегу

| Поле | Значение |
|------|----------|
| Статус | Done (корпус: backup 37/37, body 207/207; эмулятор не нужен — UI не менялся) |
| Дата начала | 2026-10-31 |
| Источник | лаунчер, `contract/TASKS_LXBOX.md` §137 (1.1.141, `trusttunnel`) и ответ на наш §138 (1.1.142, слияние DNS-серверов по тегу) |
| Связанные | §585/§586 (узел типа без модели), §477 (снятие записи при разборе), §695 (override DNS-серверов, повод §138) |

## Проблема

Синк контракта на `bd832097` (1.1.142) тянет и 1.1.141: запись реестра
`registry/protocols/trusttunnel.json` (AdGuard TrustTunnel, `kind: outbound`,
источник только sing-box JSON, формы нет) и три кейса `body/singbox/trusttunnel_*`.

Узел `trusttunnel` у нас уже шёл путём «известный тип без своей модели»
(`UnknownTypeSpec`, §586): тело судит санитайзер по реестру. Кейс
`trusttunnel_missing_password_dropped` падал: лаунчер снимает узел без
`password` при разборе (`dropped[]`, `field_missing`, `required` с
`core_rejects`), мы такой узел оставляли в списке. Причина — политика §477:
отсутствие обязательного поля снимает узел только на сборке, потому что
типы с моделью «приложение веками показывало». Снятие при разборе было
только у явного `drop_node` и у авторского тела.

## Решение

1. `annotateFromRawBody` (`parse_warnings.dart`): у `UnknownTypeSpec` со
   схемой в реестре тело без обязательного поля, чей код жёсткий
   (`ruleIsHard`: `core_rejects`), снимает узел при разборе из любого
   источника — как Go. Типы с моделью — без изменений (§477).
   Своей модели у `openconnect` / `openvpn-client` / `trusttunnel` нет, так
   что «показать и снять на сборке» им нечем.
2. Больше в коде ничего: `trusttunnel` попадает в `outbounds[]` по `kind`
   реестра, `unknown_key` без wildcard — как у naive/vless. На ядре без
   `with_trusttunnel` (Android AAR lx.21+ его не несёт, KERNEL.md) конфиг
   отвергается целиком и узел выключает страховка core-rejected по имени —
   тот же путь, что у любого неизвестного ядру типа (§137 п. 4).
3. 1.1.142 — норма BACKUP.md §9 п. 5 приведена к нашей реализации §695
   (ключ слияния template/user — только тег, локальная сильнее; снятие по
   `template_catalog` учитывает `user`-записи файла; посев каталога не
   дописывает шаблонную запись под тег, занятый `user`). Кода не требует,
   кейс `backup/v10_dns_template_override` проходит.

## Файлы

- `app/lib/services/contract/parse_warnings.dart` — п. 1.
- `app/contract/`, `app/assets/contract/`, `docs/contract/`, `app/contract.lock` — синк на `bd832097`.

## Проверка

- `test/contract/backup_corpus_test.dart` — 37/37, `v10_dns_template_override` проходит.
- `test/contract/body_contract_test.dart` — до правки 1 падение (`trusttunnel_missing_password_dropped`: получен узел, ожидалось `[]`); после — см. «Итог».

## Итог

31.10.2026: после правки `body_contract_test` 207 пройдено / 0 упало (до — 206 + 1), `trusttunnel_missing_password_dropped` проходит, кейсы openconnect без изменений; `backup_corpus_test` 37/37. CI на коммите не смотрели.
