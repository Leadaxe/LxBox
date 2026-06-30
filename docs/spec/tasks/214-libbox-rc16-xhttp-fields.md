# §214 — ядро sing-box-lx → rc.16 (XHTTP SPEC 002 v2 поля)

> **СТАТУС: РЕАЛИЗАЦИЯ.** Бамп пина + fetch AAR.

## Зачем

§127 (XHTTP full URL params) эмитит расширенные поля транспорта
(`sc_max_each_post_bytes`, `session_placement`, `x_padding_obfs_mode` и др.).
Ядро **rc.15** их не знает — на устройстве конфиг падает на load:

```
decode config: outbounds[N].transport.sc_max_each_post_bytes:
json: unknown field "sc_max_each_post_bytes"
```

Это роняет **весь** конфиг (не только xhttp-ноду) → туннель не стартует.
Поля добавлены в ядро в **rc.16** (коммит `ab29eb1b` "rc.16 — SPEC 002 v2 full
XHTTP param support", релиз `v1.14.0-lx.1-rc.16`).

## Решение

Бамп пина `app/android/libbox.version`: `v1.14.0-lx.1-rc.15` → `v1.14.0-lx.1-rc.16`.
`fetch-libbox.sh` подтянет AAR из релиза форка. CommandClient API не менялся
(только transport-decode расширился) — javap-проверка не требуется, native-
обвязка та же.

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| pin | `app/android/libbox.version` | rc.15 → rc.16 |
| AAR | `app/android/app/libs/libbox.aar` | fetch (не в git, .gitignored) |

## Критерии приёмки

- `fetch-libbox.sh` качает rc.16 AAR (sha совпадает с релизом).
- Сборка APK ок.
- Device: xhttp-подписка с `sc_max_each_post_bytes` → конфиг грузится, туннель
  стартует (rc.15 ронял).
- `/device` (§213) → `core_version` = `1.14.0-lx.1-rc.16`.

## Связанные

- §127 XHTTP full URL params (потребитель новых полей).
- §213 Debug API core_version (диагностика рассинхрона).
- §210 — предыдущий бамп rc.14→rc.15 (тот же паттерн).
