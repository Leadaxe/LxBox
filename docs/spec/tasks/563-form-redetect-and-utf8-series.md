# 563 — detect формы судится по раскрытому тексту; серия битых байтов даёт один U+FFFD

| Поле | Значение |
|------|----------|
| Статус | Реализовано (ветка `task-563`) |
| Дата старта | 2026-09-26 |
| Дата завершения | 2026-09-26 |
| Коммиты | `dd1f605c` (серия байтов), `66ff3825` (redetect + юнит-тесты), `0be1a38c` (merge develop, контракт 1.1.75), docs — этот коммит |
| Связанные spec'ы | §480 (движок маппера), §562 (диспетчер схем), контракт 1.1.74 §70, MAPPER_ENGINE §1 и схема этапов (unwrap → redetect) |

## Проблема

После бампа 1.1.74 три кейса корпуса ссылок красные:

1. **`uri/vmess/legacy_cleartext_userinfo`** — у нас `form_unrecognized`.
   Реестр снял у формы `legacy` признак `default` и дал ей
   `detect: {regex: "^[^#]*@"}`, который по норме MAPPER_ENGINE адресует
   **раскрытый** текст (`method:uuid@host:port` после base64): «форма
   `space: url` после `base64` читает то, в чём есть структура, которую объявил
   её `detect`». Dart (`interpreter.dart` `_selectForm` ~:224 →
   `formMatchesText` ~:634) сверяет `regex`/`text` с **сырым** пэйлоадом до
   `decode`, и у base64-строки `@` нет.
2. **`uri/vless/label_invalid_utf8_byte`, `uri/vmess/ps_invalid_utf8_byte`** —
   метка с серией из шести байт cp1251: корпус ждёт `Node-�-1` (один U+FFFD на
   серию, как Go `strings.ToValidUTF8`), Dart даёт `Node-������-1` (по одному
   на байт, `Utf8Decoder(allowMalformed)`). Метка входит в тег узла, значит
   расходится identity между сторонами — это не косметика.

## Решение

1. **Redetect после раскрытия.** Выбор формы в `_selectForm`: если у формы есть
   цепочка `decode`, текстовые предикаты `detect` (`regex`, `text.*`) судятся
   по тексту **после** применения цепочки до первого структурного шага
   (`json`/`ini`/`reparse`), а не по сырому пэйлоаду; `scheme_in` — по-прежнему
   по сырому тексту; `json`-предикат — по разобранному JSON, как сейчас. Форма
   без `decode` — как сейчас. Никаких имён схем и форм в коде. Проверить, что
   выбор формы у остальных секций (`vless`, `trojan`, `ss` base64-формы,
   `wireguard` ini) не изменился — корпус это и покажет.
2. **Серия битых байтов → один U+FFFD.** Общий шаг после
   `Utf8Decoder(allowMalformed)` в обоих местах (`engine/decoders.dart`
   `_utf8OrRaw`, `interpreter.dart` `base64`): подряд идущие U+FFFD, возникшие
   из невалидных байтов, схлопываются в один. Реализовать не пост-заменой
   строки (легитимные U+FFFD источника трогать нельзя), а декодированием по
   максимальным невалидным подпоследовательностям: `Utf8Decoder` даёт по
   символу на каждую такую подпоследовательность — свести серию соседних
   подпоследовательностей к одной, если между ними нет валидных символов.
   Норму серии лаунчер фиксирует в MAPPER_ENGINE (запрошено 26.09).
3. Документация: параграф в спеке движка §480 (redetect), `CHANGELOG.md`
   Unreleased (метка с битыми байтами теперь совпадает с desktop).

## Итог

1. Redetect сделан по семантике лаунчера (`UnwrapURI`, `linkmap/parse.go`),
   а не строго «только по раскрытому»: предикат формы с `decode` сходится на
   сыром пэйлоаде **или** на раскрытом тексте (`_applyFormDecode` +
   `_applyScopedDecodeToPayload`). Строгое «только раскрытый» сломало бы
   формы, чей `detect` описывает саму оболочку: hysteria2 `wrapped` и
   wireguard `conf_b64` (`not contains "@"` + алфавит base64 — на раскрытом
   тексте ложны по построению). Форма без `decode` — как раньше;
   раскрытие считается только если сырой текст не сошёлся.
2. `decodeUtf8Lenient` (`engine/decoders.dart`): быстрый путь — строгий
   `Utf8Decoder`; на битом входе — побайтовая проверка UTF-8 (обрыв, overlong,
   суррогаты, > U+10FFFF невалидны), подряд идущие невалидные байты дают один
   U+FFFD. Используется percent-декодом (`_utf8OrRaw`) и base64 формы
   (`_RunDecode.base64`). Норма закреплена контрактом 1.1.75 (§71).

## Верификация

По одному файлу: `test/contract/contract_test.dart` — 0 красных;
`test/contract/body_contract_test.dart` — только 2 известных (род группы);
`engine_emit_roundtrip_test`, `vmess_pipeline_invariants_test`,
`vless_pipeline_invariants_test`, `before_480_identity_snapshot_test`
(идентичность прежних кейсов не меняется — битых байтов в них нет), тесты
рядом с `decoders.dart`; один новый юнит-тест на серию байтов и на выбор формы
по раскрытому тексту.

## Результат верификации

Контракт 1.1.75 (после merge develop): `contract_test` — 378 зелёных, 0
красных; `body_contract_test` — только 2 известных (`singbox/group_member_missing`,
`xray/balancer_group`); `engine_xray_pilot_test`, `engine_emit_roundtrip_test`,
`vmess_pipeline_invariants_test`, `vless_pipeline_invariants_test`,
`before_480_identity_snapshot_test`, `body_decoder_test`, `engine_lexer_test` —
зелёные без правок снимков; новый `engine_form_redetect_utf8_test` (7 кейсов) —
зелёный; `flutter analyze` по затронутым файлам — 0.

## Нерешённое / follow-up

- **Закрыто задачей 570 (`74f74681`):** `utf8Lossy` и title подписки
  декодируют через `decodeUtf8Lenient`. Было: `uri_utils.dart` (`utf8.decode(allowMalformed)` ~:172) и
  `sources.dart` ~:302 декодируют вне движка по-старому (замена на каждую
  подпоследовательность). На identity узла ссылки не влияют (метку ведёт
  движок); свести к `decodeUtf8Lenient` — отдельной задачей, если корпус
  этого потребует.
- **Закрыто задачей 570 (`74f74681`):** `formsInTrialOrder` — форма с
  `detect.default` пробуется последней независимо от позиции. Было: порядок форм: у лаунчера форма `default` пробуется последней независимо от
  места в списке, у нас — по порядку объявления. В реестре `default` всегда
  последняя, расхождения нет; держится на порядке данных.
