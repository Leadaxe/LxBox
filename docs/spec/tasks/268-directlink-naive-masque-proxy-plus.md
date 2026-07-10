# §268 — isDirectLink: naive+https / masque / proxy+https / proxy+http

## Проблема

`parseUri` (диспетчер по схеме) умеет разбирать `naive+https://` и `masque://`
в валидный `NodeSpec`, но `isDirectLink` (входной классификатор UI-импорта,
`services/subscription/input_helpers.dart`) их не перечисляет. В результате
штатный импорт (paste / clipboard / «Add server» wizard / QR → `addFromInput`)
падает на `naive+https://`- и `masque://`-ссылках:

```
addFromInput rejected: Input is not a subscription URL, proxy link, or outbound JSON
```

Диагностика на живом сервере (naive, `getall.servebeer.com:26646`):

- `parseUri('naive+https://…')` → валидный `NaiveSpec` ✅ (парсер знает схему)
- `POST /subs {"input":"naive+https://…"}` → 400, `isDirectLink` вернул `false`
  до вызова парсера ❌

Рассинхрон списков схем между `parseUri` и `isDirectLink`:

| Схема          | parseUri | isDirectLink | статус до фикса |
|----------------|:--------:|:------------:|-----------------|
| `naive+https`  |    ✅    |      ❌      | не импортируется |
| `masque`       |    ✅    |      ❌      | не импортируется |
| `proxy-https`  |    ✅    |      ✅      | ок              |
| `proxy-http`   |    ✅    |      ✅      | ок              |

## Решение

1. Добавить в `isDirectLink` пропуск схем `naive+https://` и `masque://`.
2. Ввести плюс-алиасы `proxy+https://` / `proxy+http://` к дефисным
   `proxy-https://` / `proxy-http://` — для единообразия с `naive+https://`
   (одна и та же «плюс»-конвенция). Обе формы эквивалентны.

### Затрагиваемые файлы

| Файл | Изменение |
|------|-----------|
| `services/subscription/input_helpers.dart` | `isDirectLink` += `naive+https://`, `masque://`, `proxy+https://`, `proxy+http://` |
| `services/parser/uri_parsers.dart` | `parseUri` switch += `case 'proxy+https'` / `case 'proxy+http'` → `parseHttpProxy` |
| `services/parser/uri_parsers/http_parser.dart` | `secure` детект: `proxy-https` **или** `proxy+https` |

`clipboard_analysis.dart` правки не требует — оно построено поверх
`isDirectLink` + `text.split('://').first`, подхватит новые схемы само
(`NAIVE+HTTPS`, `MASQUE`, `PROXY+HTTPS` в превью).

`toUriNaive` уже эмитит `naive+https://`, round-trip замыкается.

### Инвариант

Множество схем, которые `isDirectLink` признаёт прямым линком, должно быть
подмножеством схем, которые `parseUri` умеет разобрать (кроме голых
`http(s)://`, что заняты `isSubscriptionUrl`). Т.е. «если импорт-классификатор
пропустил ссылку как direct link — парсер обязан её разобрать».

## Тесты

- `test/subscription/input_helpers_test.dart` — дополнить список схем
  `isDirectLink` до актуального (был неполный: не было `awg`, `proxy-http`,
  `proxy-https`) + новые `naive+https`, `masque`, `proxy+https`, `proxy+http`.
- `test/parser/http_proxy_test.dart` — `proxy+https` / `proxy+http` дают тот же
  `HttpSpec` с корректным TLS-флагом, что и дефисные формы.

## Проверка на устройстве

Импорт `naive+https://…`-ссылки через `POST /subs` → нода в конфиге →
переключение `route.final` на неё → живой трафик (сервер в Москве, выход
direct → московский выходной IP).
