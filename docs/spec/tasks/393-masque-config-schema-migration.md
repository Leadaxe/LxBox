# §393 — MASQUE: переход на новую схему конфига ядра

**Статус:** в работе
**Ядро:** `v1.14.0-lx.25-rc.5` (запинен) ([SPEC 062](https://github.com/Leadaxe/sing-box-lx/blob/lx/SPECS/TASKS/062-MASQUE_CONFIG_SCHEMA_MIGRATION/SPEC.md), [SPEC 021](https://github.com/Leadaxe/sing-box-lx/blob/lx/SPECS/TASKS/021-MASQUE_CONNECT_IP_OUTBOUND/SPEC.md))
**Связано:** [§130 MASQUE](../features/130%20masque/spec.md), §284/§305 (сканер), §386 (пресеты endpoint)

## Зачем

Ядро переименовало поля outbound'а `masque`: версия HTTP и TLS-опции переехали
из плоского корня в `vhttp` + вложенный `tls{}`. Старые имена ещё работают, но
каждый такой outbound пишет предупреждение в лог, а в `lx.30` поддержка
снимается. Плюс сменился дефолтный SNI.

**История имени.** В `rc.4` ключ назывался `transport`; в `rc.5` переименован в
`vhttp` — `transport` у остальных протоколов означает объект `{type: ws|grpc|…}`,
и совпадение путало. Промежуточное имя не выходило за пределы одного коммита в
`develop`: ни релиза, ни пользовательских URI с ним нет, поэтому в клиенте оно
не поддерживается вовсе — на входе живут только `vhttp` и legacy `network`.

## Что меняется в ядре

| устарело | заменить на |
|---|---|
| `network: "h3"` / `"h2"` | `vhttp: "h3"` / `"h2"` |
| `sni: "…"` | `tls.server_name: "…"` |
| `skip_cert_verify: true` | `tls.insecure: true` |
| `fragment: true` | `tls.fragment: true` |
| `record_fragment: true` | `tls.record_fragment: true` |
| `fragment_fallback_delay: "…"` | `tls.fragment_fallback_delay: "…"` |

Не менялись: `server`, `server_port`, `profile`, `private_key`, `public_key`,
`ip`, `ipv6`, `uri`, `mtu`, `idle_timeout`, `keep_alive_period`, `network_list`.

Новое поле: `tls.disable_sni` — ClientHello без SNI. Пустой `sni` этого НЕ давал
(подменялся дефолтом профиля), так что это не синоним пустой строки.

Одно и то же поле, заданное старым и новым именем **с разными значениями** —
fatal при старте. Одинаковые значения конфликтом не считаются. Отсюда правило
ниже: эмитить только один набор имён, никогда оба.

Дефолтный SNI: `consumer-masque.cloudflareclient.com` → `www.cloudflare.com`.
Причина (из релиза ядра): с прежним именем h3-туннель не поднимается на
российских каналах, замерено на двух независимых. Пиннинг ECDSA-ключа делает
имя некритичным для аутентификации.

Ядро теперь предупреждает (не падает) на неподдерживаемых для masque полях:
`tls.alpn`, `tls.ech`, `tls.reality`, `tls.kernel_*`, а также на фрагментации
при `vhttp: h3`.

## Решение: где живёт знание о старых именах

Пин ядра всегда один и он ≥ rc.5, поэтому **эмит знает только новую схему**.
Обратная совместимость нужна исключительно на входе — чужие конфиги, старые
бэкапы и уже сохранённые `masque://`-ссылки никуда не делись.

```
вход (legacy ∪ new)              модель            выход (new only)
─────────────────────            ──────            ────────────────
parseMasqueUri   ┐                                 emitMasque  → vhttp + tls{}
                 ├→ MasqueSpec.vhttp ─────────────┤
nodeFromSingbox  ┘                                 toUriMasque → vhttp=
```

Legacy-имена упоминаются ровно в двух парсерах. Ни билдер, ни модель, ни UI о
них не знают.

## Слои хранения (для справки — миграции НЕ делаем)

MASQUE хранится в двух несвязанных местах:

1. `masque_account` — top-level ключ `lxbox_settings.json`, кеш **регистрации**
   (ECDSA-ключи, device_id, token). Не config-significant. Порождает URI, но сам
   в конфиг не попадает.
2. Узлы — обычные `UserServer` в `server_lists`, строка `masque://…`.

Ключ `network` из `masque_account` **удалён совсем**: версия HTTP — свойство
узла, а не регистрации (одни креды дают и h3-, и h2-узлы через `ScanNodeBuilder`,
а визард выбирает её заново при каждом добавлении). Теперь она передаётся
параметром `toMasqueUri(vhttp:)` и живёт только в URI узла.

Миграции нет: старый ключ на диске не трогаем, при чтении он игнорируется и
исчезает при следующей записи.

Сохранённые URI с `network=` продолжат парситься; при следующем пересохранении
узла перепишутся на `vhttp=`. Дрейф без data-loss.

## Объём

| Слой | Файл | Правка |
|---|---|---|
| Модель | `models/node_spec.dart` | `MasqueSpec.network` → `vhttp`; новое `disableSni` |
| Эмит конфига | `models/node_spec_emit.dart` `emitMasque` | `vhttp` + `tls{}`; only-new |
| Эмит URI | `models/node_spec_emit.dart` `toUriMasque` | `vhttp=`, `disable_sni=` |
| URI-парсер | `parser/uri_parsers/masque_parser.dart` | `vhttp` ∪ legacy `network` |
| JSON-импорт | `parser/json_parsers.dart` | обе схемы, вложенный `tls{}` |
| WARP-генератор | `warp/masque_account.dart` | `toMasqueUri(vhttp:)`, ключ `network` удалён |
| Регистрация | `warp/warp_client.dart` | `registerMasque` без версии HTTP |
| Сканер | `warp/scan/scan_node_builder.dart` | версия HTTP при сборке URI |
| Лейбл узла | `models/config_node.dart` | `vhttp` — плоская строка, ветка до общей |
| Билдер | `builder/post_steps/tls_transforms.dart` | `applyTlsFragment` для masque h2 |
| Пин | `app/android/libbox.version`, `docs/KERNEL.md` | rc.3 → rc.5 ✅ |

### Решения по развилкам

**Фрагментация.** `applyTlsFragment` сейчас требует `tls.enabled == true`, а у
masque блока `tls` не было вовсе — глобальный `tls_fragment` его не касался.
Теперь касается, но **только при `vhttp: h2`**. При h3 — пропуск молча, без
UI-варнинга: глобальный тумблер не должен ругаться на каждый неподходящий узел,
и ядро само пишет предупреждение в лог. У masque нет `tls.enabled` (TLS всегда
включён по природе транспорта), поэтому гейт для него отдельный.

**`tls.disable_sni`.** Добавляется в модель, парсер и эмит. UI не трогаем —
ручка анти-DPI-нишевая, а тянет три экрана (визард, редактор узла, детали).
Задать можно через URI/JSON-импорт и редактор конфига.

**Дефолтный SNI.** Своих дефолтов не подставляем — пустой SNI по-прежнему
означает «решает ядро», и теперь это `www.cloudflare.com`. Правится только
доккоммент. ⚠️ Отдельно: `assets/warp_endpoints.json` вчера (9d5629ba) назначил
`recommended_sni` = `consumer-masque.cloudflareclient.com` — ровно то имя, с
которым, по замерам ядра, h3 не встаёт на РФ-каналах. Пересмотр рекомендации
выходит за рамки §393, вынесен отдельно.

## Проверка

- юнит: round-trip URI (legacy-вход → новый выход), JSON-импорт обеих схем,
  emit не содержит старых ключей, отсутствие двойных имён в одном outbound;
- `applyTlsFragment`: h2 получает `tls.fragment`, h3 не получает;
- девайс: бамп пина по регламенту `docs/KERNEL.md` (эмулятор, `strings libbox.so`,
  sha256 `classes.jar`), MASQUE h3 и h2 поднимаются, в логе нет deprecation-варнингов.

## Открыто

Пин закрыт: `rc.5` запинен, SHA256 AAR сверен, `vhttp` в ядре и в клиенте
совпадают. Осталась девайс-проверка (см. «Проверка»).

Побочное наблюдение при бампе, к §393 отношения не имеет: обещанное в rc.5 поле
`Group.mode` (kernel SPEC 019) в Android-AAR отсутствует — `classes.jar`
побайтово равен rc.4, `getMode()` в `OutboundGroup` нет, хотя нативная часть
собрана из rc.5. Детали — в `docs/KERNEL.md`.
