# 450 — `awg://<base64 .conf>` — вторая форма ссылки AmneziaWG

| Поле | Значение |
|------|----------|
| Статус | Реализовано, тесты зелёные (analyze чист, 4778 тестов; корпус контракта проходит без override). Device-verify не проводился |
| Дата | 2026-09-16 |
| Коммиты | `docs(450)` 42a9c11d — таска; `fix(450)` 193203a9 — распознавание формы, тесты, синк контракта |
| Норма | контракт §20.1 (`contract/TASKS_LXBOX.md`, singbox-launcher e6aad5a2); эталон Go `parseWGConfBase64Link` (`core/config/subscription/wgconf_text.go`, лаунчер 1.6.2) |
| Источник | полевой отчёт владельца 16.09.2026 + [issue лаунчера #125](https://github.com/Leadaxe/singbox-launcher/issues/125) |
| Связанные | [§421](421-awg3-header-protection.md) (AWG 3.0/3.1), [§243](243-name-is-tag.md) (`nameHint` → tag), §103 D-023/D-030 (валидация ключей) |

## Проблема

Панели раздают AmneziaWG 3.1 ссылкой, в которой после `awg://` лежит не
`key@host:port?…`, а base64 целого wg-quick: `[Interface]`…`[Peer]` с
AWG3-полями (`HeaderProtectionKey`, `ContentPaddingAddition = 16-64`,
`RekeyAfterTime = 3000-4000`, `RandomTrailers = on`), метка — фрагмент
(`#AmneziaWG-3.1`).

`parseWireguardUri` отдаёт такую строку `Uri.tryParse`, видит в base64 «хост»
без userInfo, не находит private key и возвращает `null`
(`uri_parsers/wireguard_parser.dart:12-23`). Узел исчезает молча: подписка из
одной такой ссылки вырождается в пустой источник.

Проверено на ссылке владельца: `parseUri` → `null`, при этом тот же payload,
декодированный и пропущенный через `parseWireguardIni`, разбирается полностью —
endpoint `91.247.235.94:51821`, MTU-клэмп 1280, весь AWG3-набор, без warnings.
Не хватает только распознавания формы.

## Решение

Ветка в `parseWireguardUri` перед `Uri.tryParse`, эталон — Go
`parseWGConfBase64Link`:

1. Payload — между `://` и `#`. Признак формы: непустой и не содержит ни `@`,
   ни `:`, ни `?` (в base64 этих символов нет, а `key@host:port?…` их несёт).
2. Декодирование — `decodeBase64Safe` (4 варианта: std/url-safe × padded/
   unpadded, как везде в проекте). Ошибка → штатный путь.
3. Текст обязан содержать `[Interface]`, иначе штатный путь и штатная ошибка
   (`parse_error` в конверте контракта).
4. Первый `[Interface]`-блок идёт в тот же конвертер, что вставленный `.conf`
   (`parseWireguardIni`): одна точка валидации ключей, MTU-клэмпа и AWG2/3-
   полей. Один share-link = один узел.
5. Метка = фрагмент (percent-unescape через `decodeFragment`). Без фрагмента —
   хост Endpoint, как у `.conf` в Go (`ConvertWGConfText`), а не общий фолбэк
   `WireGuard`.
6. `rawUri` узла — исходная `awg://`-ссылка, не синтетический `wireguard://`
   из INI-конвертера: иначе поплывут identity-хеш и экспорт источника.

Многоблочные payload'ы (несколько `[Interface]`) не поддерживаются намеренно:
контракт фиксирует «один share-link = один узел», берётся первый блок.

## Корпус

Три кейса контракта (`corpus/uri/wireguard/`), приезжают через
`tool/sync_contract.sh`:

| Кейс | Ожидание |
|------|----------|
| `awg_conf_base64` | полный AWG3-набор, метка `AmneziaWG-3.1` из фрагмента |
| `awg_conf_base64_no_label` | метка `91.247.235.94` — хост Endpoint |
| `awg_conf_base64_not_conf` | base64 без `[Interface]` → `dropped`, `parse_error` |

Плюс локальные тесты в `test/parser/awg_test.dart`: форма распознаётся,
`key@host:port` не перехватывается, `rawUri` остаётся исходной ссылкой.
