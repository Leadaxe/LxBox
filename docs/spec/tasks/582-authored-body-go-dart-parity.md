# 582 — Авторское тело: расхождения Go и Dart из корпуса 1.1.91

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-09-27 |
| Дата завершения | 2026-09-27 |
| Коммиты | см. `git log --grep=582` |
| Связанные spec'ы | [577](577-authored-json-registry-reports-only.md), [580](580-dns-cache-settings.md); контракт 1.1.94–1.1.96, TASKS_LXBOX §89, §91–§93 |

## Проблема

Контракт 1.1.92 снял из корпуса `authored` девять кейсов 1.1.91: LxBox вёл
себя иначе, чем лаунчер.

1. Авторский узел с негодным `tuic.uuid` или `peers[].allowed_ips`: лаунчер
   снимает узел (`type_invalid`), LxBox оставляет.
2. Мусорный `tls.reality.public_key`: лаунчер снимает одно поле, LxBox —
   весь объект `reality` с лишним `field_missing`.
3. `tls.reality.short_id` длиннее 16 символов: лаунчер снимает, LxBox нет.
4. sing-box JSON `hysteria` (v1) и `masque` без ключей: лаунчер читает, LxBox
   отвечает `protocol_unsupported`.

Правило пароля shadowsocks 2022 из задачи снято владельцем: такой узел
выключает автоснятие при запуске, новых жёстких правил не заводим.

## Диагностика

- п.1: точка правки (`settleSanitized`) давала `null` тело, но разбор
  (`annotateFromRawBody`) снимал узел только по явному `drop_node`. У
  `peers[]` санитайзер снимал негодный пир как элемент, а Go доносит отметку
  обязательного поля элемента до корня и снимает узел (`nodeflow.arrayField`).
- п.2: ядро (`common/tls/reality_client.go`) отвергает `reality` без
  `public_key` («invalid public_key»). Тело лаунчера (блок без ключа) ядро не
  примет; норма `tls.json` — снять весь блок, как на обычном теле. Прав
  LxBox по телу, кейс оставлен снятым, правка у Go.
- п.3: `_checkConstraints` мерил длину строки только у полей без `format`,
  а у `short_id` формат `hex`. Go меряет всегда.
- п.4: `parseSingboxEntry` требовал у masque оба ключа и адрес. hysteria v1 —
  расширение лаунчера (`protocols/hysteria.json` `extension: desktop`),
  парсера у LxBox нет по контракту.

## Решение

- п.1, авторское тело: `parse_warnings.dart` снимает узел при разборе, если
  точка правки не оставила тела (а она оставляет `null` только по жёсткому
  правилу). Тело подписки — как прежде, только явный `drop_node`.
- п.1, оба тела: `body_sanitizer.dart` `_sanitizeArray` — у элемента-объекта
  со схемой не прошло обязательное поле (нет или снято как негодное) → узел
  снимается, код снятия — код поля.
- п.3: границы `min`/`max` длины строки действуют и при `format`
  (из реестра это `reality.short_id` и `wireguard.id`).
- п.4, masque: ключи и адреса не обязательны при разборе; пустой ключ не
  пишется в тело (`emitMasque`). Негодное тело судит реестр.
- п.4, hysteria v1: контракт 1.1.96 пометил оба кейса `extension: desktop`;
  раннер корпуса `authored` пропускает кейс с чужим `extension`, как раннер
  корпуса body.
- Синк контракта 1.1.96 (граница `dns_cache_capacity` 65535 и значение по
  умолчанию 4000 в спеке 580).

## Риски и edge cases

- Авторский узел с жёстко снятым обязательным полем больше не виден в списке
  до сборки: он снимается при разборе с кодом в `dropped[]`.
- Пир WireGuard с негодным `allowed_ips` снимает весь узел и у подписки, если
  код жёсткий; прежде пир снимался молча, и узел без пира ядро тоже отвергало.

## Верификация

`test/contract/node_edit_corpus_test.dart` (корпус `authored`: все кейсы,
пропущены два hysteria v1 по `extension`), `body_contract_test.dart`,
`body_sanitizer_test.dart`, `test/builder/registry_gate_test.dart`,
`template_contract_test.dart`, `masque_pipeline_invariants_test.dart`,
`awg_test.dart`, `reality_key_share_test.dart`.

## Нерешённое / follow-up

- `hard_reality_pbk_invalid_removed` снят: у Go `patchFromClean` снимает одно
  поле, когда в чистом теле снят родитель; у LxBox лишний `field_missing`.
