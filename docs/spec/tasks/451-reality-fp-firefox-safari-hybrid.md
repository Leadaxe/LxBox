# 451 — REALITY: firefox и safari выходят из-под предупреждения

| Поле | Значение |
|------|----------|
| Статус | Реализовано, тесты зелёные (analyze чист, 4782 теста, пять чекеров pre-flight; корпус контракта без override). Полевая проверка firefox/safari — за владельцем |
| Дата | 2026-09-16 |
| Коммиты | `feat(451)` edb00882 — бамп пина, набор имён, тесты, контракт, KERNEL.md |
| Норма | контракт §20.2–20.3 (`contract/TASKS_LXBOX.md`); реестры `warnings.json` / `tls.json`; эталон Go `realityHybridUTLSFingerprints` (`node_parser_transport.go`) |
| Ядро | [SPEC 086](https://github.com/Leadaxe/sing-box-lx/blob/lx/SPECS/TASKS/086-UTLS_FORK_FIREFOX148/SPEC.md) (firefox, lx.2) + SPEC 087 (safari, lx.3) |
| Решение владельца | «firefox и safari убрать да»; «edge, ios, 360, qq — на них оставь ограничения» (16.09.2026) |
| Связанные | [§444](444-reality-fingerprint-no-override.md) (D-119, отпечаток не подменяется), §281 (нормализация uTLS), [§083 ядра](../../KERNEL.md) |

## Проблема

Предупреждение `reality_fp_not_chrome` висело на всём не-chrome семействе
разом: условие в `utls_fingerprint.dart` — `!isChromeFamilyFingerprint(value)`,
а множество содержало только шесть chrome-имён.

Основание было верным до сентября 2026: REALITY-сервер Xray ≥ v26.9.8
(`XTLS/REALITY@8cdf7bf`) требует в ClientHello key share `X25519MLKEM768`
перед X25519, а в `metacubex/utls` 1.8.7 гибрид несли только chrome-пресеты
(`firefox` там = Firefox 120). Узел с `fp=firefox` молча уходил на камуфляжный
сайт.

Ядро это закрыло. Форк `Leadaxe/utls-lx` (четвёртый сабмодуль) принёс из
`refraction-networking/utls` пресеты **Firefox 148** (ядро lx.2) и
**Safari 26.3** (ядро lx.3), оба с гибридным шаром. На стенде ядра против
Xray v26.9.9 оба дают 204, chrome и старые Xray без регрессии.

С пином `v1.14.1-lx.3` предупреждение на firefox и safari стало ложным: узел
рабочий, а приложение советует сменить отпечаток.

## Решение

### 1. Набор имён

`kChromeFamilyFingerprints` → **`kRealityHybridFingerprints`**, предикат
`isChromeFamilyFingerprint` → `isRealityHybridFingerprint`. Имя «chrome-семейство»
перестало быть правдой: firefox и safari в него не входят, а гибрид несут.

В набор добавлены `firefox` и `safari`. Под предупреждением остаются
`edge`, `ios`, `android`, `360`, `qq` — пресетов с гибридом для них нет ни у
`metacubex`, ни у `refraction`, у самого Xray-core та же граница.

`random` в набор не входит и под предупреждение не попадает по отдельному
условию: это дефолт URI-парсера при пустом `fp`, от явного `fp=random`
неотличим. `randomized` — гибрид монетой, предупреждение остаётся.

### 2. Условность от версии ядра

Набор нормативен **только для пина lx.3 и новее** (`app/android/libbox.version`).
В апстримном `metacubex/utls` гибрида у firefox и safari нет, поэтому при
откате ядра назад набор надо сузить обратно. Это записано в doc-комментарии
набора, чтобы через полгода не пришлось восстанавливать причину.

### 3. Что НЕ меняется

D-119 в силе: явный отпечаток из подписки уходит в конфиг как есть, ни одна
сторона его не подменяет. Снимается только предупреждение.

## Синхронность с лаунчером

Норма живёт в контракте: реестры `warnings.json` / `tls.json`, корпус-кейсы
`reality_fp_firefox_kept`, `reality_tcp_no_flow`, `grpc_reality_no_flow`
(теперь без warning) и `allowinsecure_lowercase_zero` (`fp=qq`, с warning).
Односторонняя правка уронила бы конформанс, поэтому контракт синхронизирован
(`tool/sync_contract.sh`) вместе с этой задачей.

## Проверка

Бамп пина: `v1.14.0-lx.39` → `v1.14.1-lx.3`. Java-поверхность
(`PlatformInterface`, `CommandClient`, `Libbox`) по javap-diff релизных AAR —
идентична; версия в бинаре подтверждена через `strings libbox.so`.

Полевая проверка firefox/safari против Xray ≥ v26.9.8 на стенде ядра —
за владельцем (стенд поднят в сессии ядра, порты заняты).
