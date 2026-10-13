# §642 — Контракт 1.1.118: masque `network` без legacy, отбраковка носителя detour, hysteria → `protocol_extension_unsupported`, `chrome_155`

| Поле | Значение |
|------|----------|
| Тип | Синк контракта + нормы |
| Статус | D (done), выпущено в v2.25.14 |
| Дата | 2026-10-14 |
| Связанные | контракт 1.1.118 (лаунчер `6dc299d4`, TASKS_LXBOX §115, решения D-128 / D-129), аудит §591 (пункты 1–7 списка лаунчера), §393 (masque vhttp), §636 (§7 реестра `tls.fragment` forbidden_for) |

## Проблема

Решение владельца 14.10.2026 по п. 6 аудита: старые ссылки masque с
`?network=h2|h3` не поддерживаются и не мигрируются, ключ `network`
освобождается под семантику sing-box (`tcp`/`udp`; сегодня это
`network_list`), реализация переименования — не сейчас, старая логика
снимается полностью. Лаунчер закрыл это контрактом 1.1.118 вместе с
остальными пунктами аудита §591. LxBox должен синкнуться и исполнить свою
часть; без этого гарды реестра и корпус красные.

## Что принёс 1.1.118 (норма — `app/contract/TASKS_LXBOX.md` §115)

| П. | Что в контракте | Что делает LxBox |
|---|---|---|
| 6 (D-129) | `$legacy_flat` оставлен только за `query.server_name`; `network` снят из маппера `singbox_flat_fields_stripped`; `body.skipped.network` — «зарезервировано под tcp/udp, не читается, не эмитится, в теле — общий `unknown_key`»; golden `uri/masque/legacy_params_ignored` — две записи `uri_param_unknown` (`$legacy_flat` с `value` и `network`) | снять зеркало стрипа и комментарии о legacy `network` (`json_parsers.dart` ~:1390, `config_node.dart` ~:76, тест `json_parsers_test.dart` ~:200); парсер URI masque отдаёт `uri_param_unknown` для `network` по общему правилу — сверить с golden |
| 5 (D-128) | `detour_target_missing` / `detour_to_group` / `detour_cycle_broken` — severity **error**; носитель отбраковывается записью `kind=unsupported`; «connects directly» снято; хоп без узла = `detour_target_missing`; кольцо и самоссылка роняют всех участников; `direct` и предел глубины как прежде | импорт sing-box (`singbox_config.dart` ~:490-540): вместо «цепь обрезана, узел идёт прямо» — узел не эмитится, запись `unsupported` с этим кодом; тексты предупреждений (`node_warning.dart` ~:400-450) без «connects directly» |
| 7 | `tls.fragment` / `record_fragment` / `fragment_fallback_delay`: `forbidden_for` += hysteria, hysteria2, tuic; код `tls_not_applicable_quic` | ничего в коде: `fieldAllowedOn` читает реестр; проверить тестом, что `applyTlsFragment` (§636) не дописывает флаги hysteria2/tuic |
| 4 | новый код `protocol_extension_unsupported {scheme, alternative}` (error); поле секции `extension_alternative` (`hysteria.json` → `hysteria2`) | hysteria v1 (URI и sing-box/Xray тело): отказ с этим кодом, `alternative` из реестра, не из кода; гард синка кодов реестра ↔ `kWarn*`/классы предупреждений должен увидеть эмит |
| 3 | `body.core` → 1.14.3-lx.17; uTLS-пресет `chrome_155` в `allowlists.utls_fingerprints` и обоих списках `tls.json` | `kUtlsFingerprints` (`utls_fingerprint.dart:21`) += `chrome_155`; гард сверки с реестром зелёный |
| 1, 2 | закрыты в 1.1.108, правок нет | — |

## Решение

1. Синк: `bash app/tool/sync_contract.sh --to 6dc299d4` (ТОЛЬКО так, из
   `~/projects/singbox-launcher`), проверить `app/contract/VERSION` =
   1.1.118 и `app/contract.lock`. Зеркала `app/assets/contract`,
   `docs/contract` обновляет скрипт.
2. Прогнать гарды и корпус (точечно, по одному файлу): `registry_sync_test`,
   корпусные раннеры (`app/test/contract/*corpus*`), тест uTLS-списка,
   `json_parsers_test`, тесты sing-box-импорта detour (найти по
   `detour_target_missing`/`DetourTargetMissingWarning` в `app/test`).
   Красное — чинить реализацией по таблице выше, не ожиданиями, кроме
   ожиданий, прямо изменённых контрактом (golden `legacy_params_ignored`,
   severity detour-кодов, тексты «connects directly»).
3. П. 5 — норма целиком: любой из трёх detour-кодов → запись
   `kind=unsupported` с кодом, узел в список не попадает; при кольце —
   все участники; `direct` как цель остаётся допустимым; предел глубины —
   прежний код и поведение.
4. П. 4 — код `protocol_extension_unsupported` с параметрами `scheme`,
   `alternative`; `alternative` читается из секции реестра
   (`extension_alternative`), при его отсутствии параметр пустой. Где
   сегодня hysteria v1 отказывается другим кодом — заменить на этот; если
   hysteria v1 сегодня молча не распознаётся — добавить распознавание
   схемы `hysteria://` и тела `type: hysteria` ровно для отказа.
5. Документация: ревизии в `docs/spec/features/002-NODE_IMPORT` (detour
   при импорте sing-box; hysteria v1), `016-DPI_HARDENING/tls-fragmentation`
   (QUIC-протоколы не фрагментируются — одной строкой, md + ru),
   `CHANGELOG.md` (контракт 1.1.118, видимые изменения: узел с битым detour
   больше не идёт напрямую; hysteria v1 — отказ с подсказкой hysteria2;
   `chrome_155`).

## Проверка

- Все тесты п. 2 зелёные; новый/дополненный тест на п. 5 (три кода →
  `unsupported`, кольцо роняет всех, `direct` остаётся) и п. 4 (hysteria
  URI и тело → код с `alternative: hysteria2`).
- Линты CI: `use_null_aware_elements`,
  `no_leading_underscores_for_local_identifiers`.

## Отклонения при реализации

1. **П. 6 — кода нет.** Golden `uri/masque/legacy_params_ignored` прошёл
   сразу после синка: URI-движок читает `$legacy_flat` из реестра, и
   `network=` уже шёл общим `uri_param_unknown`. Правки — комментарии и
   названия тестов (`json_parsers.dart`, `config_node.dart`, пять тестов).
2. **П. 5 — голое своё тело тоже fail-closed.** Свой сервер или член папки
   из одного sing-box-объекта с `detour` на тег вне тела (`"detour":
   "warp-out"`) теперь не создаётся (`detour_target_missing` в `dropped[]`).
   Прежде `detour` тела снимался, и узел шёл по политике сборки. Так же у
   лаунчера: одиночный outbound он заворачивает в `{"outbounds":[ob]}` и
   ведёт тем же `parseSingboxConfig`. Фикстуры `verbatim_body_test` и
   `unknown_node_type_test` лишились `detour`, добавлены тесты на отказ.
   **Решено владельцем 14.10.2026: оставить строго.** Мягкий путь не
   возвращается; тест §455 `checkPayloadFor` переписан (висячий `detour` →
   `null`).
3. **П. 5 — кольцо.** Отбраковка записывается на КАЖДОГО участника (A → B →
   C → A — три записи). У лаунчера на момент синка было две: один участник
   поглощался как хоп и пропадал без записи — дефект лаунчера против D-128,
   исправлен в тот же день (лаунчер `800670ee`, без бампа контракта;
   тест `TestDetourChainCycleOfThreeDropsEveryParticipant`). Счётчики
   совпадают. Узел, лишь ведущий в кольцо, отбраковывается тем же
   `detour_cycle_broken` — как у лаунчера.
4. **П. 4 — проверка в движке, не в парсерах.** `foreignExtensionReject`
   (`engine_mapper.dart`) читает `extension`/`extension_alternative`
   протокола; срабатывает в `mapViaEngine` (ссылки), `mapJsonViaEngine`
   (Xray) и в разборе sing-box до модели и правила «свой незнакомый тип»
   §585. Xray `hysteria` без `version` — v1 по `detect` реестра, тоже отказ.
   У класса предупреждения нет (`dart: null` в реестре) — `RegistryWarning`.
5. **П. 3 — `chrome_155` и в `kRealityHybridFingerprints`:** реестр включил
   его в исключения advisory `reality_fp_not_chrome`.
6. **Ожидания, изменённые контрактом:** `registry_load_test` (`body.core` =
   `1.14.3-lx.17`); эталон `test/fixtures/storage/golden/rich_v0.config.json`
   перезаписан `UPDATE_GOLDEN=1` — у hysteria2/tuic сняты `fragment` и
   `fragment_fallback_delay` (п. 7).
7. **CHANGELOG:** устаревшая строка «контракт 1.1.115 без изменений» в
   Unreleased заменена на «Контракт 1.1.118 (from 1.1.115)».
