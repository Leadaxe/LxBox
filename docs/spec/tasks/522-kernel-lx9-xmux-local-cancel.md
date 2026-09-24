# 522 — Ядро v1.14.1-lx.9 (SPEC 094: XMUX-брейкер не считает сбоем локальную отмену)

| Поле | Значение |
|------|----------|
| Статус | Реализовано (бамп пина), проверено на эмуляторе |
| Дата | 2026-09-24 |
| Ядро | `v1.14.1-lx.9` (`a7aec0ab3`) — один слой поверх lx.8. **SPEC 094** (заявка LxBox [#148](https://github.com/Leadaxe/LxBox/issues/148)): XMUX-брейкер больше не считает сбоем сервера наше собственное закрытие соединения. Тело http2/h1, закрытое нами при переключении узла или при выводе XMUX-сессии из оборота, приходило на читающую сторону как `context.Canceled` / `net.ErrClosed`; брейкер читал это как обрыв потока — строка `ERROR connection download closed: http2: response body closed` на каждый запрос плюс пометка сессии негодной и её пересборка на живом узле. lx.9 распознаёт локальную отмену на границе xhttp-conn и не логирует её и не считает; настоящий обрыв на стороне сервера сообщается как раньше. `option/` не менялся, Go 1.26.8, сабмодули без изменений |
| Связанные | §468 (предыдущий бамп, lx.8), §462/§461/§457 (та же процедура), `docs/KERNEL.md` («Gotchas when bumping the version»), память `kernel-bump-emulator-verify` |

## Зачем

Лог рабочего xhttp/REALITY-узла был засорён: на каждый запрос через туннель
ядро писало `ERROR connection download closed: http2: response body closed` —
хотя узел исправен, а тело закрыли мы сами. Владелец и пользователи читают
этот лог как есть, и ошибка уровня ERROR на здоровом узле обесценивает лог.
Второй, уже не косметический эффект: помеченная негодной XMUX-сессия
вытеснялась (`xmux: evicted`) и пересобиралась, то есть каждое переключение
сервера стоило лишней пересборки сессии.

## Решение

- `app/android/libbox.version`: `v1.14.1-lx.8` → `v1.14.1-lx.9`;
  AAR приносит `scripts/fetch-libbox.sh` с проверкой SHA256 против релизного
  `SHA256SUMS` (маркер `.libbox.version` в `libs/`, сам AAR в git не идёт).
- Контракт (§460, готча 2 в `KERNEL.md`) **не трогаем**: в lx.9 `option/` не
  менялся — новых полей конфига нет, реестр протоколов и `min_core` в силе.
  Готча 6 (метод `vless.encryption`) тоже ни при чём: `lx_encryption.go` в
  диффе релиза не участвует.
- Кода приложения задача не трогает: ни новых строк UI, ни l10n.

## Проверка API (гарантия «API-neutral»)

javap по `classes.jar` из **релизных** AAR обеих версий (lx.8 скачан из
Releases, а не взят из `libs/` — там он мог протухнуть), обход всех классов
одной командой:

- списки классов совпадают: **253 класса** в обеих версиях, дифф имён пуст;
- дифф сигнатур: **пусто**, 3493 строки подписей в обеих версиях;
- sha256 релизного AAR lx.9 —
  `96a17be18a4ecd130584cc1720ef9e826340b26eac9a3f302816d50e3cd0097d`
  (совпал с `SHA256SUMS` релиза; sha256 `classes.jar` показателем не является —
  gomobile AAR не байт-воспроизводим, готча 3).

## Проверка на устройстве

Версия ядра в собранном APK — из самой библиотеки, а не из пина:

```
$ unzip -p app-arm64-v8a-release.apk lib/arm64-v8a/libbox.so | strings -a \
    | grep -E 'lx\.9|lx\.8|1\.14\.1' | sort -u
1.14.1-lx.9
```

Ровно одна строка, `lx.8` в библиотеке не встречается. На устройстве то же самое
подтверждает `GET /device` → `core_version: 1.14.1-lx.9` (готча 4 в `KERNEL.md`
про невидимость `Libbox.version()` через `strings` касается Java-обёртки; строка
версии Go-сборки в `libbox.so` есть).
Эмулятор `emulator-5554` (AVD `LxBox_test`, Android 14, arm64-v8a), входы из
демо-набора: **A** — `vpn://` AmneziaWG 3, **D** — подписка rrtrg с
vless/xhttp/REALITY.

| Шаг | Ожидание | Факт |
|---|---|---|
| 1. `GET /device` | версия ядра `lx.9` | `core_version: 1.14.1-lx.9`, app `2.25.2-dev.4`, Android 14 / arm64-v8a ✅ |
| 2. Старт на xhttp-узле (`🇩🇪 DE-satx-VRX VLESS-xhttp-REALITY`), 5 запросов через туннель | **ноль** строк `ERROR … response body closed` (на lx.8 — по одной на запрос), ноль `xmux: evicted` | страховка `started_clean`, tunnel `connected`; 5/5 запросов прошли (egress `185.129.85.98`, `loc=DE`, `colo=WAW`); в 500 записях `source=core`: `response body closed` — **0**, `xmux: evicted` — **0**. Единственное упоминание закрытия — `TRACE … connection download closed`, т.е. событие осталось, но уровня ERROR и пометки сбоя у него больше нет. Все 5 строк `error` в логе — посторонний шум эмулятора (`endpoint/wireguard … disabled UDP GSO, NIC(s) may not support checksum offload`) ✅ |
| 3. `switch-node` на второй xhttp (`🇨🇭 SWITZ-just-VRX VLESS-xhttp-REALITY`) при живом туннеле | без `cause=failing` | `{"ok":true}`, tunnel остался `connected`, `last_error` пуст; egress сменился DE `185.129.85.98` → CH `194.87.18.156` (`colo=ZRH`). В логе после переключения: `cause=failing` — **0**, `failing` вообще — **0**, `evicted` — **0**, `response body closed` — **0**; единственная строка про xmux — `DEBUG xhttp: xmux: opened connection (pool=2, left_requests=755)`, то есть сессия переиспользована, а не пересобрана ✅ |
| 4. Переключение на AWG3 (`DE-satx-awg3.1 AWG`) | tunnel up, egress ≠ IP хоста | tunnel `connected`, `last_error` пуст; egress `185.129.85.98` (`loc=DE`) против IP хоста `104.28.196.105` (`loc=RU`) — разные ✅ |
| 5. Стоп (broadcast `ACTION_STOP`), `ip link show tun0` | `does not exist` | до стопа `30: tun0: <POINTOPOINT,UP,LOWER_UP> mtu 1420`; после — `Device "tun0" does not exist.`, `tunnel: stopping → disconnected` ✅ |

Скриншоты прогона — в scratchpad задачи (`bump522/`), в репозиторий не идут.

## Регресс

- `flutter analyze` — `No issues found!`.
- `flutter test` — `+6535 ~31 -17`. Все 17 падений — в одном файле
  `app/test/contract/body_contract_test.dart` (корпус контракта, расхождения по
  `json_field_unknown` в `warnings[]`) и **предшествуют задаче**: тот же файл
  падает на чистом `develop` в основном дереве, состав падений там другой,
  потому что копия `app/contract/` в дереве другая. К бампу ядра отношения не
  имеет — Dart-кода задача не трогает. Остальные 6535 тестов зелёные.
- Версия ядра в `test/` фигурирует
  только в двух комментариях (`app/test/contract/body_sanitizer_test.dart`,
  `app/test/parser/task_512_registry_schemes_test.dart`) — ассертов на строку
  пина нет, поведение тестов от бампа не зависит.
