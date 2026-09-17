# 458 — JSON-вкладка редактора template/preset DNS-сервера падала (#143)

| Поле | Значение |
|------|----------|
| Статус | Реализовано, тесты зелёные (2 новых + 32 прежних в `test/screens/dns_server_edit/`) |
| Дата старта | 2026-09-17 |
| Источник | [#143](https://github.com/Leadaxe/LxBox/issues/143) (luicyk, zh, v2.24.x) + второй репорт владельцу с русской локалью — та же ошибка |
| Затронуто | v2.24.0 – v2.24.3 (все теги, содержащие `dbeb5c82`) |
| Связанные | §439 (контракт 1.0: `toJson`/`fromJson` у `DnsServerRef` удалены, запись хранения — кодеком `models/codec/dns_record.dart`), §117 задача 4 (сама вкладка) |

## Симптом

Редактор DNS-сервера вида `template` или `preset` → вкладка **JSON** →
экран «This section failed. See Debug → Logs», в логе:

```
Flutter error: Converting object to an encodable object failed:
Instance of 'DnsServerTemplate' @ Instance of 'ErrorDescription'
```

Inline-сервер (`kind: user`) не затронут: у него вкладка — редактируемое
тело, снимок контроллера там не кодируется.

## Причина

`dns_server_edit/tabs/json_tab.dart`, блок «storage shape»: снимок
контроллера (`c.snapshot()`, объект `DnsServerRef`) отдавался в
`JsonEncoder` напрямую. До §439 это работало через неявный `toJson`;
коммит `dbeb5c82` сериализацию у модели удалил, а вкладку не перевёл на
кодек. Парная вкладка правил (`custom_rule_edit/tabs/view_tab.dart`)
переведена тогда же на `ruleToRecord`; DNS-вкладка пропущена.

## Правка

- `json_tab.dart`: `dnsServerToRecord(c.snapshot())` — блок показывает
  запись 1.0 в той форме, в какой она лежит в `lxbox_settings.json`
  (`kind`/`tag`/`vars` у template, `kind`/`ref` у preset).
- `test/screens/dns_server_edit/json_tab_test.dart`: виджет-тест вкладки для
  template и preset — строится без исключения, оба блока содержат ожидаемые
  поля. Без фикса оба теста красные (проверено).

## Что не трогали

Второй блок вкладки (превью отрезолвленного тела) и inline-ветка — без
изменений. Других мест, где модель без `toJson` уходит в `JsonEncoder`,
grep по `lib/screens` не нашёл.
