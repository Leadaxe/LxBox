# §188 — TUN-зависимые тумблеры → Mode-вкладка (keep-alive ON by default)

**Тип:** UX-рефактор + изменение дефолта
**Статус:** ✅ DEVICE-VERIFIED (dev, vc=2880). Тумблеры в Mode-вкладке видны/скрыты
по режиму; в App Settings их нет; keep_on_exit дефолт ON (Debug API подтвердил).
**Приоритет:** Medium
**Связано:** §119 (VPN mode), §084 M14 (native VPN toggles), §052 (keep-on-exit),
§049 F15 (allow_bypass), §164 (lifecycle)

## Зачем

В блоке «Native VPN System toggles» (App Settings) три тумблера. Два из них —
**allow_bypass** и **keep_on_exit** — осмысленны ТОЛЬКО при наличии TUN-inbound
(оба работают вокруг `VpnService`/`Builder`, которого нет в `proxy`-режиме §119):

- `allow_bypass` → `VpnService.Builder.allowBypass()` вызывается только в
  `openTun()` (`BoxVpnService.kt:281-282`), т.е. при establish.
- `keep_on_exit` → keep-alive вокруг `VpnService.onTaskRemoved`
  (`BoxService.kt:220`).

В чистом `proxy`-режиме (без TUN, без establish) обе бессмысленны. Логичное
место — **Mode-вкладка** (`vpn_mode_tab.dart`), под выбором режима, видимые
только при `_cfg.hasTun` (= `vpn` | `vpn_proxy`).

`interrupt_on_switch` — режим-НЕзависима (про смену ноды) → ОСТАЁТСЯ в App Settings.

## Решения (согласовано с юзером)

1. **keep_on_exit дефолт `false → true`** глобально (native
   `BootReceiver.isKeepOnExit` default-арг). Затрагивает существующих юзеров без
   ключа — это и есть «по умолчанию ON». keep-alive ожидаем и безопасен.
2. **allow_bypass дефолт остаётся `false`** (strict tunnel). ON ослабляет туннель
   — не дефолтим.
3. Оба тумблера в Mode-вкладке под segmented-выбором, ДО «Local proxy», группа
   «Tunnel options». Видны при `hasTun`, скрыты в `proxy`.

## Что меняется

### Native
- `BootReceiver.kt` — `isKeepOnExit` default-арг `false → true`. allow_bypass НЕ
  трогаем. Механика `get/setKeepOnExit`/`get/setAllowBypass` — без изменений.

### Dart — `vpn_mode_tab.dart` (добавить)
- State `_keepOnExit`/`_allowBypass` (грузить из `BoxVpnClient` в `_load`).
- Зависимость на `BoxVpnClient` (новый field, как в settings_screen).
- Тумблеры в `build()` под segmented (до `if (_cfg.hasMixed)`-блока), обёрнуты
  `if (_cfg.hasTun) ...`. Группа «Tunnel options».
- Хэндлеры: `setKeepOnExit`/`setAllowBypass` (native, НЕ через stageChanges —
  они в native SharedPrefs, не в vpn_mode storage) + `markConfigChangedNeedRestart`.
- ВАЖНО: эти тумблеры НЕ идут через `_commit()`/`stageChanges` (тот пишет
  vpn_mode). Свой путь: native-set + restart-banner.

### Dart — `settings_screen.dart` (убрать)
- Удалить SwitchListTile keep_on_exit + allow_bypass (строки ~203-244).
- Удалить state `_allowBypass`/`_keepOnExit`, хэндлеры `_toggleAllowBypass`/
  `_toggleKeepOnExit`, загрузку в `_load`. ОСТАВИТЬ `_interruptOnSwitch`.

## НЕ трогать (битых ссылок не будет)
- `get/setKeepOnExit`/`get/setAllowBypass` (BoxVpnClient + native) — backup
  (`backup_service.dart`), debug API (`handlers/*.dart`) их используют.
- `interrupt_on_switch` — остаётся в App Settings.
- vpn_mode storage shape — не меняется.

## Границы / риски
- Дефолт-ON keep_on_exit меняет поведение существующих установок — намеренно.
- В `proxy`-режиме тумблеры скрыты, но сохранённые native-значения целы (вернутся
  при переключении на vpn). Гейт чисто визуальный.
- Restart-banner: смена обоих тумблеров требует restart туннеля (как было в
  settings) — через `markConfigChangedNeedRestart`.
