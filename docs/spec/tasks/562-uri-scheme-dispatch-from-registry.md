# 562 — диспетчер схем ссылки читается из реестра; таблицы схем в Dart сняты

| Поле | Значение |
|------|----------|
| Статус | Выполнено (ветка `task-562`) |
| Дата старта | 2026-09-26 |
| Дата завершения | 2026-09-26 |
| Коммиты | `afa6213c` (п.1 диспетчер), `9ba5fc7c` (п.2 схема конверта socks из `emit.form_from`), `952bbc07` (п.3 таблица версии socks снята), `096826c3` (страж литералов), docs — этот коммит |
| Связанные spec'ы | §472 шаг 6 (socks), §475 (`socks_scheme_is_version`), §480 W4 (движок маппера), §560 (пробелы разбора), кампания «реестр важнее локальных правил» |

## Проблема

Реестр описывает написания схем ссылок и их смысл: `aliases` у протоколов
(`socks.json` → `socks`, `socks5`, `socks4`, `socks4a`; `hy2` → `hysteria2`
и т. п.) и `scheme_sets` секций маппера (схема как дискриминатор версии у
socks — `socks_scheme_is_version`; суффикс TLS у `proxy-https://`). В Dart те
же знания повторены локальными таблицами:

- `app/lib/services/parser/mappers/uri_pipeline.dart` (~:180–230): список
  известных схем и таблица «схема → тип тела» для всех протоколов;
- `app/lib/services/parser/uri_utils.dart` (~:575–594): `kSocksVersionByScheme`
  и `socksSchemeForVersion` (обратное направление для `toUri()`);
- `app/lib/services/parser/uri_parsers.dart` (~:215–225): `switch` по схемам с
  ветками на парсеры.

Это локальная копия правила реестра; по правилу кампании владельца она
снимается, правило остаётся только в данных.

## Решение

1. **Диспетчер схем из реестра.** Общая функция «схема ссылки → схема реестра
   (тип тела)» строится при загрузке реестра из `aliases` протоколов и
   `scheme_sets` секций маппера; она же отвечает «известна ли схема». Таблицы в
   `uri_pipeline.dart` и `switch` в `uri_parsers.dart` заменяются на вызов
   диспетчера; ветки, которые остаются (парсеры вне движка маппера), выбираются
   по схеме реестра, не по написанию.
2. **Версия socks ↔ схема.** Прямое направление уже исполняет маппер
   (`socks_scheme_is_version`, §475); обратное для `toUri()` берётся из той же
   записи реестра (посмотреть, как описано соответствие «версия → написание»
   в `socks.json` `note`/маппере; если реестр даёт только прямое направление —
   вычислять обратное из него, не заводить вторую таблицу). Если данных в
   реестре недостаточно — записать в «Нерешённое» точный запрос лаунчеру, а не
   оставлять таблицу молча.
3. Снять `kSocksVersionByScheme`, `socksSchemeForVersion` (или свести к
   чтению реестра), таблицы схем и их тесты, проверявшие именно таблицы.
   Тесты поведения (ссылка → тело → ссылка) остаются и должны быть зелёными.
4. Неизвестная схема: код из `warnings.json`, как сейчас (`scheme_unknown` или
   аналог — сверить), без новых текстов.
5. Документация: параграф в спеке §472/§480 (где описан диспетчер), `CHANGELOG.md`
   Unreleased (внутреннее изменение, одна строка).

Правило кампании: в Dart не остаётся ни одного имени схемы в диспетчере;
линтер `engine_no_scheme_names_test` должен это подтверждать — расширить его
покрытие на `uri_pipeline.dart`/`uri_parsers.dart`, если он их не проверяет.

## Риски и edge cases

- Идентичность узла (тег) и тело не меняются ни для одной ссылки корпуса —
  главный критерий; проверять identity-снимками.
- Схемы вне реестра, которые Dart принимал «по доброте» (например устаревшие
  написания) — если такие есть, их либо добавляет реестр, либо они перестают
  приниматься с кодом; перечислить в отчёте.
- Порядок разбора: алиас должен резолвиться до выбора секции маппера.

## Верификация

По одному файлу: `test/contract/contract_test.dart` (5 известных красных —
не больше), `body_contract_test`, `test/parser/engine_no_scheme_names_test.dart`,
identity-снимки (`before_480_identity_snapshot_test`, `vless_pipeline_invariants_test`,
`vmess_pipeline_invariants_test`, `xray_pipeline_invariants_test`,
`engine_emit_roundtrip_test`), тесты socks (`grep -l socks test/parser`), тесты
рядом с изменёнными файлами. Полный прогон — CI.

### Итог верификации

Точечно, по файлу: `contract_test` — 5 красных (известные: `anytls/sni_label_falls_back_to_server`,
`socks/socks5_base64_userinfo`, `socks/socks5_base64_userinfo_colon_password`,
`vmess/not_base64_rejected`, `wireguard/amneziawg_scheme_full_name`); `body_contract_test` —
7 известных красных (группы и xray-отбраковка, файлы задачи 561); зелёные:
`engine_no_scheme_names_test` (с новым стражем), `before_480_identity_snapshot_test`,
`vless`/`vmess`/`xray`/`socks`/`wireguard`/`naive`/`http`/`hysteria2_pipeline_invariants_test`,
`engine_emit_roundtrip_test`, `amnezia_link_test`, `task_506_silent_loss_test`,
`task_512_registry_schemes_test`, `task_514_contract_11152_test`,
`mapper_rules_coverage_test`, `round_trip_test`, `emu_input_defects_test`,
`fixtures_parse_test`, `input_helpers_test`. Тег и тело узлов корпуса не изменились
(identity-снимки зелёные).

### Что сделано

1. `mappers/uri_pipeline.dart`: `kPipelineSchemes` и `_kSchemeToType` сняты; маршрут
   `_SchemeRoute` строит карту «написание → тип тела» из `detect.scheme_in` секций
   `mappers.uri` и `aliases` их протоколов (алиас не перекрывает написание секции;
   алиасы протокола без секции `uri` — `autogroup` — ссылкой не становятся).
   `pipelineSchemes()` = ключи карты, `registryUriSchemes()` = только `scheme_in`
   (набор Go `IsDirectLink`), `registrySchemeType()` = карта.
2. `uri_parsers.dart`: `switch` по написаниям, `_kWireguardSchemesFallback`,
   `_kProviderServiceSchemesFallback` и проверка `scheme != 'vpn'` сняты. Порядок:
   тип из реестра → парсер вне движка по форме секции (`forms[].space: ini` →
   `parseWireguardUri`) либо конвейер; иначе контейнер профиля по `detect` вида
   источника `amnezia_link`; иначе служебная строка по `uri_lines.service_schemes`;
   иначе `scheme_unsupported` (коды прежние).
3. Версия socks ↔ схема: обратное направление реестр уже даёт (`emit.form_from` у
   `socks.json`, его исполняет эмиттер движка); таблица `kSocksVersionByScheme` /
   `socksSchemeForVersion` в `uri_utils.dart` была нужна только раннеру корпуса — там
   схема конверта теперь берётся из `toUri()` узла. Запроса лаунчеру не требуется.
4. Страж: `engine_no_scheme_names_test` проверяет строковые литералы в
   `uri_parsers.dart` и `uri_pipeline.dart` (имена протоколов и все написания схем,
   включая `vpn`, `incy`, `happ`); исключение — род узла `awg`/`awg3` в запасном
   потолке mtu (`mapping.kinds.contains`).

Схемы, которые перестали приниматься: нет. Набор написаний до и после совпадает
(`wg` теперь приходит из `aliases` протокола wireguard, а не из литерала).
Поведенческое отличие только без загруженного реестра: ни одна ссылка не опознаётся,
`vpn://` и служебные строки `incy`/`happ` тоже (раньше — запасные литералы; разбора без
реестра не было и тогда, движок без секций не работает).

## Нерешённое / follow-up

- **Закрыто задачей 570 (`711e09c0`):** движок исполняет форму `space: ini`
  у ссылки; `_kOutOfEngineLinkForms`, `parseWireguardUri` и каталог
  `uri_parsers/` сняты. Было: форма `conf_b64` секции wireguard (`space: ini`) объявлена реестром, но движок
  ссылок пространство `ini` не исполняет — её читает `parseWireguardUri`. Когда движок
  научится `ini`-форме ссылки, `_kOutOfEngineLinkForms` в `uri_parsers.dart` снимается.
- `wg://` объявлен только в `aliases` (Go `IsDirectLink` его не принимает) — разрыв
  прежний, решение владельца. Задача 570: LxBox принимает по реестру
  (`aliases`); разрыв с Go — строка для лаунчера в отчёте 570.
- Вне диспетчера литералы схем остаются: `input_helpers.dart` (`isAmneziaVpnLink`
  запасной `vpn://`, `isSubscriptionUrl`), `_kProtocolFiles` в `registry.dart`,
  публичные обёртки `uri_parsers/<схема>_parser.dart` (передают написание в конвейер).
  Кандидаты в следующую волну кампании.
