# 457 — Ядро v1.14.1-lx.4 + `tls.reality.key_share` (hybrid | classical)

| Поле | Значение |
|------|----------|
| Статус | Реализовано, тесты зелёные (15); DEVICE-PENDING |
| Дата старта | 2026-09-17 |
| Ядро | `v1.14.1-lx.4` (релиз 17.09.2026): SPEC 088 — `fragment`/`record_fragment` теперь действуют и на REALITY (раньше REALITY-клиент строил рукопожатие на голом сокете и молча их пропускал, включая авто-`record_fragment` под `detour`); SPEC 089 — по-узловая опция `tls.reality.key_share`. Провод, наборы тегов AAR, Go-тулчейн без изменений; Java-поверхность по нотам не менялась — проверить javap'ом |
| Коммиты | `bc160f30` (бамп ядра + KERNEL.md), `d61eb208` (`key_share`: модель, JSON, URI, тесты, доки) |
| Связанные | §451 (`kRealityHybridFingerprints`, код `reality_fp_not_chrome` — набор нормативен для пина lx.3+, lx.4 его сохраняет), §454 (TLS-allowlist: `reality` — типизированный блок, сквозная карта его не покрывает), §455 (JSON-источник идёт дословно — там поле пройдёт и без модели), §453 (прецедент: имя URI-параметра = ключ sing-box), контракт `registry/tls.json` → `reality` |

## 1. Бамп ядра

- `app/android/libbox.version`: `v1.14.1-lx.3` → `v1.14.1-lx.4`; `scripts/fetch-libbox.sh`
  качает AAR с проверкой SHA256.
- Java-поверхность: javap-обход всех классов одной командой (память
  `kernel-bump-emulator-verify`; sha256 `classes.jar` не показатель),
  дифф lx.3 → lx.4 ожидается пустым. Непустой дифф — стоп и отчёт.
- `docs/KERNEL.md`: блок «The current pin» → lx.4 (что принёс, Java-поверхность),
  строка в «Version history».
- `CHANGELOG.md` → Unreleased / Changed: ядро lx.4, два изменения REALITY.
- Пост-шаг `applyTlsFragment` (`post_steps/tls_transforms.dart`) REALITY-узлы
  не исключает — с lx.4 глобальный тумблер фрагментации реально действует
  и на них. Поведение приложения не меняется, меняется эффект в ядре;
  отметить в KERNEL.md.

## 2. `tls.reality.key_share`

Ядро (`option/tls.go:252-261`, `common/tls/reality_client.go:89-92`):

| Значение | Смысл |
|---|---|
| отсутствует / `""` | как несёт отпечаток (дефолт) |
| `hybrid` | требовать `X25519MLKEM768`; отпечаток без него — ошибка в начале рукопожатия |
| `classical` | вырезать `X25519MLKEM768` из `key_share` и `supported_groups` (~0,5 КБ, один сегмент; принимают только Xray-серверы старше v26.9.8) |
| иное | `unknown reality key_share` — **отказ создания outbound'а = отказ всего конфига** |

### Модель

`RealitySpec` ([`tls_spec.dart`](../../../app/lib/models/tls_spec.dart)) получает
`final String? keyShare;` (`null` = не задано, ключ не эмитится).
`toSingbox()`: `enabled, public_key, short_id, key_share` (порядок структуры
ядра). `==`/`hashCode` — с полем.

Допустимые значения — константа `kRealityKeyShares = {'hybrid', 'classical'}`
рядом с `RealitySpec`.

### Разбор

| Вход | Правило |
|---|---|
| sing-box JSON `tls.reality.key_share` (`_tlsFromSingbox`) | строка из `kRealityKeyShares` → в модель; иное (регистр не нормализуем, число, пусто) → **поле отброшено молча**, узел жив (guard «деградируй поле, не конфиг»: ядро отвергло бы конфиг целиком). Строка в GUARDS 2.1 |
| share-URI vless / trojan / anytls (`transport.dart`, там же `pbk`/`sid`) | query `key_share=hybrid\|classical` — имя = ключ sing-box (прецедент §453/§269); тот же guard. Читается только вместе с валидным REALITY (`pbk`), иначе игнорируется |
| Xray JSON (`_xrayTlsFromStream`, `realitySettings`) | аналога у Xray нет; не читаем |
| JSON-источник узла (§455) | идёт в ядро дословно, модель не участвует; проверку делает `CheckConfig` при Save |

### Эмит

- sing-box: `reality.key_share` только при непустом значении (omitempty ядра).
- URI (`toUriVless`, `toUriTrojan`, `toUriAnyTls`): `key_share=` только при
  наличии REALITY и значении. Узлы без поля — байт в байт прежние (parity).
- QUIC-типы: `reality` и так срезан (§282) — ничего не добавляется.

### Взаимодействие с §451

`reality_fp_not_chrome` — предупреждение об отпечатке, не о `key_share`; логика
не меняется. `key_share: classical` — осознанный выбор пользователя под старый
сервер, предупреждение об отпечатке к нему не относится (у chrome-семейства
его и нет). `hybrid` на отпечатке без гибрида ядро отвергнет само при
рукопожатии — это ошибка данных, приложение не подменяет.

### Контракт

`registry/tls.json` → `reality`: параметр `key_share` (`enum` hybrid|classical,
дефолт пусто, guard = drop, «Поддержка: обе»). Имя URI-параметра
`key_share=` **подтверждено лаунчером 17.09.2026**; та же семантика с обеих
сторон (drop, не подгон; чтение только при валидном `pbk`). Лаунчер гейтит
эмит по версии ядра ≥ lx.4 (у него ядро сменное). У LxBox ядро одно и
пин поднимается в этой же задаче, гейта нет — но **поле нормативно только
для пина lx.4+**: откат ядра ниже lx.4 = ядро отвергнет `key_share` как
неизвестный ключ, эмит придётся закрыть (как §451 с набором отпечатков).
Отметить в KERNEL.md рядом с §451.

## Проверка

- Бамп: `javap`-дифф lx.3 → lx.4 пуст; `strings libbox.so` в собранном APK
  показывает `1.14.1-lx.4`; прогон на эмуляторе — VPN поднимается, REALITY-узел
  с `key_share: classical` и с `hybrid` в running config (§311).
- `test/parser/reality_key_share_test.dart`: JSON `hybrid`/`classical` →
  round-trip; `"Hybrid"`, `"x"`, `1` → поля нет, узел жив; URI
  `key_share=classical` с `pbk` → в модель и обратно в `toUri()`; без `pbk` →
  игнор; узел без поля — emit и URI прежние байт в байт; hysteria2 с reality —
  как раньше (срезан).
- `flutter analyze`, `flutter test`, l10n-чекеры (новых строк нет).

## Docs to update

- `docs/KERNEL.md` — пин, история, заметка про fragment на REALITY.
- `docs/PROTOCOLS.md` — VLESS «TLS Behavior» / REALITY: `key_share` в JSON и
  URI; таблица параметров.
- `docs/GUARDS.md` 2.1 и 1.4: `key_share` вне enum → отброшено.
- `CHANGELOG.md` → Unreleased / Changed (ядро) и Added (`key_share`).
- Контракт: `registry/tls.json` (лаунчер), `TASKS_LXBOX.md` — статус.
