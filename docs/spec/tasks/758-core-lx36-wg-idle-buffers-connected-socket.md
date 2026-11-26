# 758 — ядро v1.14.4-lx.36: ключи сна в `lx.wg.idle`, настройки `lx.wg.buffers` и `lx.wg.connected_socket`

| | |
|---|---|
| **Статус** | Done — вышло в v2.26.0 (26.11.2026); проверено владельцем |
| **Дата** | 2026-11-24 |
| **Повод** | Релиз ядра `v1.14.4-lx.36` (sing-box-lx): раскладка `lx.wg` изменена без периода совместимости, две новые группы настроек; владелец хочет видеть их в приложении |
| **Связанные** | 709 (корневой блок `lx` из шаблона), 536 / 542 (lazy_build, build_max), 704 (миксины), 729 (прошлый пин lx.35); ядро: SPEC 098 §2.1–§3, SPEC 158 §9, SPEC 160 §3 |

## Docs to update

- `docs/KERNEL.md` — пин, история версий (javap, теги сборки).
- `docs/USER_GUIDE.md` / `.ru.md` — карточка WireGuard.
- `CHANGELOG.md`.

## Problem

1. Ядро lx.36 перенесло ключи сна WireGuard в подблок `lx.wg.idle`:
   `idle_suspend` → `idle.suspend`, `idle_suspend_reachable` →
   `idle.suspend_reachable`, `idle_teardown` → `idle.teardown`, `lazy_build`
   → `idle.lazy_build`, `build_max` → `idle.build_max`, `build_overflow` →
   `idle.build_overflow`. Конфиг со старым именем не загружается
   (`lx.wg.idle_suspend is moved to lx.wg.idle.suspend`). Шаблон LxBox пишет
   старые имена: с новым ядром без правки шаблона VPN не стартует при любых
   умолчаниях (сон включён по умолчанию).
2. Новые ключи ядра, работают в любой сборке (не только с
   `with_lx_idle_suspend`):
   - `lx.wg.buffers.read_datagram_count` — 1–128, умолчание 128;
   - `lx.wg.buffers.send_by_mtu` — bool, умолчание `true`, `false` —
     диагностика;
   - `lx.wg.connected_socket` — bool, умолчание `false`.

## Diagnosis

- Ключи ядра пишет только `config.lx` шаблона (`app/assets/wizard_template.json`).
  Хранилище держит **имена переменных** (`wg_idle_suspend` и т. п.), а не
  пути ядра; имена переменных не меняются (SPEC 098 ядра §3: «Имена
  переменных реестра и настроек приложения не меняются»). Миграция хранилища
  настроек не нужна.
- Старые пути ядра могут лежать только в **миксинах** (§704): цель
  `lx.wg.idle_suspend`, `merge` объекта в `lx.wg` / `lx` / корень,
  `remove` списка ключей у `lx.wg`. Миксин применяется к итоговому конфигу
  последним, поэтому такой миксин после пина ломает загрузку ядра.
- Сборка с ядром: Debug API / probe-конфиг блок `lx.wg` не пишут
  (`probe_config.dart` кладёт только `sniff_guard`).

## Solution

**Шаблон (`wizard_template.json`).**

- `config.lx.wg` перестроен: сон — в `idle` (`suspend`, `suspend_reachable`,
  `lazy_build`, `build_max`), условия прежние.
- Три новые переменные секции `wireguard`, имена и варианты совпадают с
  реестром контракта 1.1.183 (сессия лаунчера):
  - `wg_read_datagram_count` — `int`, закрытые options 128 / 32 / 8 / 2 / 1,
    умолчание **8** (решение владельца 24.11: лучше для Android, 1 МБ на
    туннель вместо 16,4); ключ пишется при значении ≠ 128, то есть по
    умолчанию всегда (`buffers.read_datagram_count: 8`). У лаунчера то же имя
    переменной: 8 для удалённой Linux-машины (роутера), 128 локально и на
    прочих ОС (ноты контракта 1.1.183, лаунчер 6eb07db2); реестр
    `default_value` против шаблона не сверяет;
  - `wg_send_by_mtu` — `bool`, умолчание `true`; при `false` пишется
    `buffers.send_by_mtu: false`;
  - `wg_connected_socket` — `bool`, умолчание `false`; при `true` пишется
    `connected_socket: true`, подсказка называет непроверенную смену
    Wi-Fi ↔ LTE.
- Блок `wg` пишется, если есть хотя бы одно из: сон не `off`, буферы не по
  умолчанию, `connected_socket`. Подблок `buffers` — только при непустом
  содержимом. Сон `off` + новые ключи — `wg` без `idle`.
- Строки (i) экрана Core (`_lxVarHints`) называют новые пути; три новые.
- `SettingsStorage._configVarKeys` — три новые переменные.
- Переводы: `l10n/{ru,zh}/template.json` (подписи и подсказки),
  `l10n/{ru,zh}/ui.json` (строки (i), ключи старых строк переименованы).

**Миграция миксинов (`lib/services/mixins/mixin_legacy_lx_wg.dart`).**
`Mixin.fromJson` (хранилище, бэкап, дублирование в списке) переписывает:

- цель `lx.wg.<старое>` → `lx.wg.idle.<новое>`;
- объект у цели `lx.wg`, `lx`, корня: старые ключи внутри `wg` уходят в
  `wg.idle`, при совпадении с уже записанным новым ключом новое сильнее;
- `remove` у `lx.wg` со списком только старых ключей → цель `lx.wg.idle`.

Идемпотентно, без маркера; файл хранилища получает новые имена при
следующей записи миксинов. Миксин, созданный через Debug API `POST /mixins`
или редактор, не переписывается — это явный ввод.

**Пин.** `app/android/libbox.version` и `kCoreBuildTagsPin` →
`v1.14.4-lx.36` — одним коммитом с шаблоном: шаблон на новых именах с
ядром lx.35 не загружается, и наоборот.

## Risks and edge cases

- `connected_socket` на телефоне со сменой сети не проверен ядром; по
  умолчанию выключен.
- `read_datagram_count` на Android выведен ядром из кода, не замерен на
  устройстве. Умолчание 8 выключает на сокете туннеля склейку приёма (UDP GRO,
  ядро 158 §9.1.1); по замеру ядра на 100–160 Мбит/с скорость в пределах
  разброса. Выбор 128 возвращает поведение ядра.
- `remove` смешанным списком (старый и новый ключ) у `lx.wg` не
  переписывается.
- Реестр переменных (`app/assets/contract/registry/vars.json`) — зеркало
  контракта; новые переменные и ноты к путям приходят синком 1.1.183, руками
  зеркало не правится.

## Verification

- `test/builder/lx_block_template_test.dart` — новая раскладка, старых
  плоских имён нет ни при каких значениях; по умолчанию
  `buffers.read_datagram_count: 8`, при 128 `buffers` нет; send_by_mtu /
  connected_socket только при отличии от дефолта; сон off + новые ключи.
- `test/services/mixins/mixin_legacy_lx_wg_test.dart` — шесть имён, объекты,
  `remove`, идемпотентность, `Mixin.fromJson`.
- Golden-конфиги `test/fixtures/storage/golden/*.config.json` перезаписаны:
  изменился только блок `lx.wg` (`idle`, `buffers.read_datagram_count: 8`).
- Затронутые наборы: l10n, `ui_check`, хранилище, контракт шаблона —
  зелёные.
- Десктопный бинарь релиза `sing-box 1.14.4-lx.36` (darwin-arm64, SHA256
  сверен), `check`: golden `avd_v0` на новой раскладке проходит целиком,
  тот же конфиг до правки — `lx.wg.idle_suspend is moved to
  lx.wg.idle.suspend`; `buffers` + `connected_socket` проходят,
  `read_datagram_count: 200` — ошибка диапазона. Блок `idle` десктопная
  сборка на `check` принимает (гейт сборки — на старте).
- Теги сборки AAR lx.36 = lx.35 (`build_libbox/main.go`: правка только в
  комментарии), исходники `experimental/libbox` идентичны; AAR не
  скачивался, javap не прогонялся.
- Эмулятор 24.11 (AVD `LxBox_a161`, Android 36.1, headless; CI `build-fast`
  run 45320272525 с 997aeabf, `2.25.23-rc.2-dev.19`, `libbox.so` =
  `1.14.4-lx.36`; установка `install -r` поверх 2.25.22-dev.83, через Debug API):
  - по умолчанию собранный и работающий (`/config/running`) конфиг —
    `lx.wg {idle {suspend, suspend_reachable, lazy_build, build_max},
    buffers {read_datagram_count: 8}}`, `check-config` — ok, VPN стартует,
    все WG/Tailscale endpoint'ы `up`; ядро собирает WARP по требованию
    (`lx idle: lazy … rebuild by=dial`) — ключи сна в `idle` действуют;
  - `wg_read_datagram_count = 128` → `buffers` нет ни в собранном, ни в
    работающем конфиге;
  - `wg_connected_socket = true` → старт без ошибки, в работающем конфиге
    `connected_socket: true`; возвращено в `false`;
  - трафик через WireGuard на стенде не проверен: WARP (WireGuard) и домашний
    WireGuard-узел не отвечают на urltest одинаково при 8 и при 128
    (соединения уходят в туннель, ответа нет — сеть стенда), WARP MASQUE
    через тот же туннель отвечает (209–331 мс).

## Unresolved / follow-up

- Синк контракта 1.1.183 (реестр `vars.json`, `core_config.json`) — после
  коммита лаунчера.
- Прогон на телефоне: трафик и скорость WireGuard с `read_datagram_count: 8` против 128,
  `Connected tunnel socket` при смене Wi-Fi ↔ LTE.
