# 550 — профиль разбора ссылок: куда уходят 370 мкс на ссылку

| Поле | Значение |
|------|----------|
| Статус | Done (замер; оптимизации — отдельной задачей по решению координатора) |
| Дата старта | 2026-09-25 |
| Дата завершения | 2026-09-25 |
| Коммиты | ветка `task-550` от `da3c236d`: `perf(550)` — бенч и общий хелпер профиля, `docs(550)` — этот отчёт |
| Связанные spec'ы | §480 (`engine_perf_test.dart`), §548 (профиль санитайзера, обвязка VM service), §549 (срезы санитайзера, не влита), §472/§512 (маршрут схем через реестр) |

## Проблема

Бенч §480 (2000 trojan-ссылок, 5 форм) даёт на develop: слой маппера
`mapViaEngine` ≈98 мкс/ссылка, полная воронка `parseUri` ≈370 мкс/ссылка.
Разрыв ≈270 мкс между маппером и готовой моделью не профилирован. Санитайзер
по §548 стоит 45–60 мкс на trojan-тело, то есть основная цена не в нём.
Задача — бенч по этапам и типам, профиль, проверка гипотез H1–H6. Код разбора
не меняется.

## Диагностика

### Бенч

`app/test/perf/parse_perf_test.dart`. Гейт `LX_PERF=1` (без него тест молчит),
`LX_PERF_RUNS` — число прогонов (берётся лучший), `LX_PERF_QUICK=1` — только
(a) и (b). Корпус 2000 ссылок с уникальными хостами и именами:
vless vision, vless ws, vless reality+grpc, trojan (5 форм §480),
hysteria2 obfs, ss с plugin, tuic, wireguard, awg (URI-форма с jc/jmin/h1…),
vmess ws (base64-JSON). Смешанный корпус идёт по кругу типов.

Этапы `parseUri` → `_parseUriInner` → `parseUriViaPipeline` → `_runPipeline`
меряются вызовом тех же функций, вход готовится вне замера:

- **маршрут** — схема (`split('://')`), `_wireguardSchemes()` (копия,
  функция приватная), `pipelineSchemes()`, `registrySchemeType()`;
- **маппер** — `mapViaEngine`;
- **санитайзер** — `RegistrySanitizer.sanitize` на телах маппера
  (`coreVersion: '0.0.0'`, без гейтов ядра, как в `_runPipeline`);
- **модель** — `tagFromLabel` + `parseSingboxEntry` + `markPipelineParsed`;
- **баннер** — `isBannerTarget` (копия `_providerBannerWarning`);
- **остаток** — `parseUri` минус сумма этапов: у wireguard/awg это
  `_parseWgConfBase64Link` (проверка формы `awg://<base64 .conf>`) и второй
  вызов `registrySchemeType`, у остальных — шум и накладные расходы вызова.

Identity (`nodeIdentityKey`) в `parseUri` не входит, меряется для справки.
Вход sing-box JSON — `parseSingboxConfigs` на телах `getEntries(null).main`
тех же узлов (wireguard — в `endpoints`).

Профиль — общий хелпер `app/test/perf/vm_profile.dart` (вынесен из §548 без
изменений логики; §548-бенч переведён на него). Команды (из `app/`):

```
LX_PERF=1 LX_PERF_RUNS=5 flutter test test/perf/parse_perf_test.dart
LX_PERF=1 LX_PERF_RUNS=1 LX_PERF_QUICK=1 LX_PERF_PROFILE=1 flutter test --coverage \
  --coverage-path=/tmp/lcov.info test/perf/parse_perf_test.dart
# один тип / вход sing-box JSON:
... LX_PERF_PROFILE_SHAPE='vless ws' ...
... LX_PERF_PROFILE_SCENARIO=json ...
```

Машина: хост macOS, JIT (`flutter test`), соседние процессы нагружают CPU —
расхождение повторов до ±10 %. Цифры сняты на `da3c236d`, **до §549**.

### (a) Целиком, мкс/ссылка (лучший из 5)

| корпус | `parseUri` | sing-box JSON |
|---|---:|---:|
| смешанный | 397 | 242 |
| trojan §480 (5 форм) | 347 | 180 |

Разбор ссылки дороже разбора того же узла из JSON: на ссылке 170 мкс уходит
на выбор маршрута, которого у JSON нет.

### (b) Этапы `parseUri`, смешанный корпус

| этап | мкс/ссылка | доля |
|---|---:|---:|
| `parseUri` целиком | 391 | 100 % |
| маршрут схемы | 169 | 43 % |
| маппер `mapViaEngine` | 91 | 23 % |
| санитайзер | 62 | 16 % |
| модель (`tagFromLabel` + `parseSingboxEntry`) | 10 | 3 % |
| баннер | 0,7 | — |
| остаток | 58 | 15 % |
| identity (вне `parseUri`) | 0,2 | — |

### (c) По типам ссылки, мкс/ссылка

| тип | `parseUri` | маршрут | маппер | санитайзер | модель | остаток | JSON |
|---|---:|---:|---:|---:|---:|---:|---:|
| vless vision | 355 | 170 | 100 | 53 | 5 | 28 | 178 |
| vless ws | 359 | 170 | 113 | 59 | 6 | 10 | 210 |
| vless reality grpc | 442 | 175 | 121 | 89 | 11 | 46 | 287 |
| trojan 5 форм | 343 | 166 | 95 | 52 | 5 | 24 | 170 |
| hysteria2 obfs | 300 | 165 | 50 | 55 | 5 | 24 | 174 |
| ss plugin | 231 | 177 | 26 | 21 | 4 | 3 | 97 |
| tuic | 282 | 164 | 37 | 55 | 5 | 20 | 177 |
| wireguard | 354 | 166 | 70 | 64 | 22 | 33 | 235 |
| awg | 387 | 167 | 80 | 78 | 21 | 39 | 293 |
| vmess ws | 382 | 174 | 138 | 56 | 6 | 7 | 181 |

Маршрут стоит одинаково на всех типах (164–177 мкс): он не зависит от ссылки,
только от числа секций в реестре.

### Горячие точки (профиль `parseUri`, смешанный корпус, 26 957 сэмплов)

Inclusive, код lxbox:

| функция | доля | что делает |
|---|---:|---|
| `_wireguardSchemes` | 38,8 % | на КАЖДУЮ ссылку: `pipelineSchemes()` + `registrySchemeType(s)` для каждой из ~25 схем |
| `registrySchemeType` | 35,4 % | перебор `typesFor('uri')` × `scheme_in` каждой секции; из них ~31 % внутри `_wireguardSchemes`, ~4 % — вызов в `parseUriViaPipeline` |
| `runSection` (маппер) | 29,8 % | из них `_Run._reportUnknown` 8,4 %, `_Run._declared` 7,7 % |
| `MapperSections.typesFor` | 23,5 % | на каждый вызов: обход `_draft.keys`, `protocolNames`, `cast`, `toList()..sort()` |
| `RegistrySanitizer.sanitize` | 20,7 % | в т. ч. `sharedSchema` без кеша 4,2 % (§548 R1) |
| `MapperSections.sectionFor` | 7,6 % | строит ключ `'$kind/$type'` интерполяцией на каждый вызов из цикла `registrySchemeType` |
| `pipelineSchemes` / `registryUriSchemes` | 5,8 / 4,5 % | сборка множества схем заново на каждую ссылку |
| `parseSingboxEntry` | 3,7 % | в т. ч. `newUuidV4` через `SecureRandom` 1,4 % |
| `_decodeBase64Lenient` | 2,6 % | vmess/ss/wg-ключи |
| RegExp (все) | ≈2,5 % | матчинг; компиляция не видна — VM кеширует `RegExp` по шаблону |

Self, свёрнутый до кода lxbox: `typesFor` 19,9 %, `sectionFor` 7,6 %,
`registrySchemeType` 7,2 %, `_Run._declared.<closure>` 5,7 %,
`_Ctx._sanitizeObjectBody` 4,3 %, `ContractRegistry.rawProtocol` 3,6 %,
`_expand` 2,7 %, `_decodeBase64Lenient` 2,6 %, `_Run._applyParam` 2,3 %,
`_Run._readSource` 2,2 %.

Сырые кадры VM (self): `_OneByteString.==` 17,5 %, `LinkedHashMap._getValueOrData`
6,3 %, `_OneByteString.hashCode` 4,3 %, `LinkedHashSet._add` 4,2 %,
`ListIterator.moveNext` 3,8 %, `toLowerCase` 2,7 %, `_HashBase._hashPattern`
2,6 %, `Map._hashCode` 2,6 %, `Sort._insertionSort` 2,2 %,
`_substringMatches` 2,0 %. Почти всё это — сравнение строк схем, поиск по
картам и сортировка в `typesFor`/`registrySchemeType`: работа маршрута, а не
разбора.

Вход sing-box JSON (профиль `LX_PERF_PROFILE_SCENARIO=json`): санитайзер
60 % (`sharedSchema` 14 %), `legacyNodeIdentityHash`/`nodeDedupSignature`
12,7 %, `jsonEncode` 10,5 % (`_prettyJson` 7,9 %), `parseSingboxEntry` 9,9 %.

### A/B по гипотезам

Временные правки в worktree, в коммиты не вошли. Лучший из 5, `LX_PERF_QUICK=1`.

| вариант | смешанный `parseUri` | trojan §480 | маппер (смеш.) |
|---|---:|---:|---:|
| база | 391–397 | 347 | 91 |
| V1: мемо `pipelineSchemes`, `registrySchemeType`, `_wireguardSchemes` | 193–212 | 166 | 92 |
| V1 + V2: `_Run._declared` из кеша по экземпляру секции (`Expando`) | 162–183 | 127 | 63 |
| V1 + V2 + V3: RegExp вынесены в top-level/кеш (`formMatchesText`, паддинг base64, проверка `awg://<base64>`) | 152–182 | 123–127 | 61–64 |

V1 снимает маршрут со 169 до 3 мкс и заодно половину остатка (58 → 26):
второй `registrySchemeType` в `parseUriViaPipeline` и повтор у wireguard.
V3 — в шуме.

### Вердикт по гипотезам

- **H1 — регулярки/`Uri.parse` без кеша: отклонена.** `Uri.parse` на пути
  нет (ссылку разбирает `lexUri`). Матчинг RegExp ≈2,5 %, компиляцию VM
  кеширует сама; вынос регулярок — в шуме (V3).
- **H2 — повторная работа с секциями на каждую ссылку: подтверждена, главная
  статья.** Не разбор секции (план `_SectionPlan` и `sectionFor` кешируются),
  а выбор маршрута: `_wireguardSchemes()` + `pipelineSchemes()` +
  `registrySchemeType()` пересобирают множества схем из реестра на каждую
  ссылку, `typesFor` каждый раз сортирует список. 43 % `parseUri`, −180…−185
  мкс/ссылка по A/B (V1). Вторая часть — `_Run._declared` (набор объявленных
  query-имён) строится на каждый прогон секции, хотя `_SectionPlan.declared`
  уже кеширует ровно такой же набор (без overlays): −29…−39 мкс (V2).
- **H3 — санитайзер: подтверждена как третья статья, совпадает с §548.**
  62 мкс/ссылка на смеси, 52 на trojan (§548: 45–60). §549 срезает ≈25 мкс
  на тело — около 6 % нынешней цены `parseUri`, но ≈15 % после R1+R2.
- **H4 — `jsonEncode`/`jsonDecode` тела: отклонена для ссылок.** На пути
  URI `rawSource` = сама ссылка, `_JsonStringifier` в профиле нет. На входе
  sing-box JSON `_prettyJson` — 7,9 % (≈19 мкс/узел).
- **H5 — identity/хеши: отклонена для ссылок.** `nodeIdentityKey` 0,2 мкс,
  в `parseUri` не входит; `newUuidV4` через `SecureRandom` 1,4 % (≈5 мкс).
  На входе sing-box JSON `legacyNodeIdentityHash` — 12,7 % (≈30 мкс/узел).
- **H6 — другое: `_Run._reportUnknown` 8,4 %** (поиск необъявленных
  query-ключей, опирается на тот же `_declared`, часть снимает V2);
  `sharedSchema` без кеша (закрывает §549 R1); декодер base64 ключей WG
  (§549 R4).

## Решение

Код не менялся. Бенч и общий хелпер профиля — в ветке `task-550`.

### Рекомендации (в порядке выигрыша; ни одна не меняет наблюдаемое поведение)

| № | Что | Ожидаемый выигрыш, мкс/ссылка | Основание |
|---|---|---:|---|
| R1 | Кешировать маршрут схем: `pipelineSchemes()`, карту «схема → тип» (`registrySchemeType`) и `_wireguardSchemes()` — один раз на загрузку секций. Сброс — там же, где сбрасывается `MapperSections._cache` (перезагрузка реестра/черновиков), либо ключом по поколению загрузки, как `_planCache` по экземпляру секции. `typesFor` — тоже кешировать отсортированный список по `kind` | −180…−185 (смесь 397 → ≈210, trojan 347 → 166) | A/B V1 |
| R2 | `_Run._declared` брать из кеша по экземпляру секции (расширить `_SectionPlan.declared` на overlays и читать его), то же для `_declaredJson`/`_declaredJsonPaths`/`_declaredIni` | −29…−39 | A/B V2 |
| R3 | Влить §549 (кеш `sharedSchema`, связи `FieldSchema`, декодер WG) | ≈−25 на тело | §548/§549 |
| R4 | Вход sing-box JSON: `legacyNodeIdentityHash`/`nodeDedupSignature` и `_prettyJson` сериализуют тело отдельно — считать сериализацию один раз на узел | ≈−15…−25 на узел JSON (оценка по профилю, без A/B) | профиль json |
| R5 | `newUuidV4` на `Random` вместо `Random.secure()` для id узла (если id не несёт требований к стойкости — проверить по коду до правки) | ≈−4 | профиль, без A/B |
| R6 | Регулярки — оставить как есть | 0 (шум) | A/B V3 |

После R1+R2 разбор ссылки ≈160–180 мкс, с §549 — ≈135–155 мкс: примерно
в 2,5 раза быстрее нынешнего. Следующая по весу статья тогда — маппер
(≈60 мкс) и санитайзер (≈35–40 мкс), без явного лидера внутри.

## Риски и edge cases

- Кеш маршрута (R1) обязан сбрасываться при перезагрузке реестра и черновиков
  секций: схемы, приехавшие контрактом (§512), иначе не увидятся до
  перезапуска. Тест на «новая схема после перезагрузки» — в задачу R1.
- `_SectionPlan.declared` сейчас не включает overlays, а `_Run._declared`
  включает: при слиянии (R2) взять полный набор, иначе `_reportUnknown`
  начнёт ругаться на query-ключи overlays.
- Цифры JIT, не AOT; порядок статей от этого не меняется, абсолютные
  значения на устройстве другие.

## Верификация

- `flutter analyze test/perf/` — чисто.
- Бенч `parse_perf_test.dart` прогнан: полный (лучший из 5) и `LX_PERF_QUICK`
  по каждому варианту A/B; профили — база (смесь), после V1+V2 (смесь),
  sing-box JSON.
- Бенч §548 после выноса хелпера — только `analyze`, логика профиля не
  менялась.

## Нерешённое / follow-up

- R1–R2 — отдельной задачей по решению координатора.
- Повтор замера после влития §549 — тем же бенчем, `LX_PERF_RUNS=5`.
