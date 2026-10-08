# §616 — `connect_timeout` для direct-out: переменная шаблона, дефолт 15 с

| Поле | Значение |
|------|----------|
| Тип | F (доработка) |
| Статус | A (в работе) |
| Фича | [122-CONFIG_BUILD](../features/122-CONFIG_BUILD/FEATURE.md) (Traffic Processing, переменные шаблона) |
| Дата | 2026-10-08 |
| Связанные | §573/§574 (ручки ядра в пресете), §311 (running config), §031 (Debug API) |

## Problem

Приложение Т‑Инвестиции (`ru.tinkoff.investing`) не входит в аккаунт при
включённом LxBox и входит без него. Правило ведёт его в `vpn-2 → direct-out`,
DNS-ответы с VPN и без совпадают, трафик в tun заходит и уходит прямым
outbound'ом.

Причина — в сочетании сети и таймаута ядра. Из сети Tele2 до диапазона
Т‑Банка (178.130.128.0/23) теряются SYN. Нативно Android дожидается
соединения ретрансмитами (`tcp_syn_retries = 6`, предел ~127 с, OkHttp ждёт
10 с), а sing-box без поля `connect_timeout` обрывает дозвон через константу
`C.TCPConnectTimeout = 5 s` и закрывает соединение приложению:

```
connection: open connection to 178.130.128.21:443 using outbound/selector[vpn-2]:
  dial ccmni1 (15): dial tcp 178.130.128.21:443: i/o timeout   [5.0s]
```

Замер 08.10.2026 на телефоне владельца: из 8 дозвонов до `api.t-bank-app.ru`
через туннель два соединились за 8.6 и 11.7 с. С 5 с оба были бы оборваны,
серия запросов входа не проходит целиком. С `connect_timeout: 20s`
(временная правка через `PUT /config`) все 8 прошли, вход заработал.

## Diagnosis

- Ядро: `common/dialer/default.go` — `dialer.Timeout = options.ConnectTimeout`,
  иначе `C.TCPConnectTimeout` (5 с). Поле входит в общие Dial Fields,
  описано в `app/contract/docs/generated/protocols/_dialer.md`.
- У LxBox outbound `direct-out` эмитится из `app/assets/wizard_template.json`
  (~1128) без Dial Fields. Ручки ядра того же рода (`tun_mtu`, `tun_stack`,
  `tls_record_fragment`, `resolve_strategy`, `urltest_interval`) — переменные
  шаблона, подставляются через `"@имя"` и редактируются в UI:
  Routing → Rules → «Traffic Processing» → вкладка Params.
- Секция `network` шаблона (~583) сейчас содержит одну переменную
  `auto_detect_interface`.

## Solution

**Решение владельца (08.10.2026):** дефолт 15 с, поле ввода с пресетами
`5s / 15s / 20s / 25s / 30s / 45s / 1m / 2m`, значение произвольное
(`options_open`). Только для `direct-out`: у прокси-узлов таймаут дозвона
влияет на urltest и переключение групп, там ничего не менять.

1. В `app/assets/wizard_template.json`, секция `network`, после
   `auto_detect_interface` — переменная по образцу `urltest_interval`:

   ```json
   {
     "name": "direct_connect_timeout",
     "type": "text",
     "options_open": true,
     "wizard_ui": "edit",
     "title": "Direct connect timeout",
     "tooltip": "How long the core waits for a direct TCP connect before giving up. sing-box default is 5s; mobile networks that lose SYN packets need more. Android itself retries for about 2 minutes, apps usually wait 10-30s.",
     "default_value": "15s",
     "required": true,
     "options": ["5s", "15s", "20s", "25s", "30s", "45s", "1m", "2m"]
   }
   ```

2. Outbound в шаблоне:

   ```json
   { "type": "direct", "tag": "direct-out", "connect_timeout": "@direct_connect_timeout" }
   ```

3. Валидация значения — как у других duration-переменных шаблона, если
   такая валидация есть (формат Go `time.Duration`: `15s`, `1m`, `1m30s`).
   Если валидации для `text`-переменных нет — не изобретать, ядро само
   отвергнет мусор на `check-config`; но в тултипе формат назвать.

4. Хранилище: переменные с дефолтом в `vars` не пишутся, миграции нет
   (§291 — форму хранилища не менять). Проверить, что экспорт/импорт бэкапа
   (`lx_backup.dart`, список переменных ~244) подхватывает новую переменную
   тем же механизмом, что и `urltest_interval`; если список ручной — дописать.

5. Debug API и ничего в UI сверх вкладки Params не трогать. Строки UI только
   английские, `§616` в видимых строках не упоминать.

## Risks and edge cases

- Пустая строка или нечитаемый duration → `check-config` падает с ошибкой
  ядра. Тест на нормальный путь обязателен, на мусор — по возможности.
- Корпус контракта `preset_body_declares_all_template_vars`: переменная,
  на которую ссылается тело, должна быть объявлена — она объявлена в секции
  `network`, проверить тестом загрузки шаблона.
- Golden/снапшот-тесты сборки конфига, где есть `direct-out`, получат новое
  поле — обновить ожидания точечно, не перегенерировать всё подряд.
- `urltest` группы и прокси-узлы не затрагиваются: поле только у `direct-out`.

## Verification

- Юнит-тест сборки: при дефолтах `outbounds[tag=direct-out].connect_timeout == "15s"`;
  при переопределении переменной `2m` → `"2m"`.
- Тест загрузки шаблона: переменная `direct_connect_timeout` объявлена в
  секции `network`, дефолт `15s`, список options совпадает с решением.
- Запускать только затронутые файлы тестов, не каталоги (правило репозитория).
- CI — отдельным дежурным; в отчёте: файлы, тесты, упавшие ожидания и как
  обновлены.

## Unresolved / follow-up

- `PUT /config` сохраняет файл, но снапшот `GET /config/running` обновился
  только после `POST /action/reload-vpn` (наблюдение 08.10.2026). Либо reload
  при PUT не срабатывает, либо снапшот ленивый. Отдельная задача по слову
  владельца.
- Пресет Block Ads отбивает `inapps.appsflyersdk.com`, приложение Т‑Банка
  отвечает штормом переподключений (`dropped due to flooding`). Вход это не
  ломает, но шум в логах заметный. Не в этой задаче.

## Implementation notes

_(заполняет исполнитель)_
