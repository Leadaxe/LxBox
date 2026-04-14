# 015 — Rule Outbound Selection & Route Final

## Контекст

Сейчас у каждого `selectable_rule` outbound захардкожен в шаблоне (`direct-out`, `action: reject`). Пользователь не может выбрать — например, пустить торренты через vpn-1 вместо direct, или российские домены через proxy. Также `route.final` (куда идёт весь остальной трафик) не настраивается — всегда `proxy-out`.

## Что делаем

### 1. Выбор outbound для каждого правила

В настройках рядом с чекбоксом каждого правила добавляется дропдаун с выбором outbound.

**Доступные варианты** (динамически, в зависимости от включённых групп):
- `direct` → `direct-out`
- `proxy` → `proxy-out`
- `auto` → `auto-proxy-out`
- `vpn-1` → `vpn-1` (только если группа vpn-1 включена в `enabledGroups`)
- `vpn-2` → `vpn-2` (только если группа vpn-2 включена в `enabledGroups`)

**Правила с `action`** (Block Ads → `action: reject`) — дропдаун не показывается, outbound не применяется (action-based правила outbound не имеют).

**Default**: берётся из шаблона (`rule.outbound`). Если в шаблоне нет `outbound` (action-based) — не показываем дропдаун.

### 2. Настройка route.final

В конце секции правил — отдельная строка **"Default traffic"** с таким же дропдауном. Определяет `route.final` в конфиге. Default: `proxy-out`.

### 3. Хранение

В `SettingsStorage` добавляются два новых поля в `boxvpn_settings.json`:

```json
"rule_outbounds": {
  "Russian domains direct": "direct-out",
  "BitTorrent direct": "vpn-1",
  "Russia-only services direct": "direct-out"
},
"route_final": "proxy-out"
```

`rule_outbounds` — Map\<String, String\>: label правила → tag outbound.  
`route_final` — String: tag outbound для `route.final`.

Если значение не задано — используется дефолт из шаблона.

### 4. Применение в config_builder

В `_applySelectableRules` при добавлении rule в конфиг:
- Если у правила есть `outbound` и пользователь выбрал значение → подставляем пользовательский outbound вместо шаблонного.
- Если выбранный outbound не существует в активных группах (например vpn-1 отключили) → fallback на шаблонный.

В `_applyVars` для `route.final`:
- Берём `route_final` из настроек, подставляем в `config['route']['final']`.
- Fallback: значение из шаблона (`proxy-out`).

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/services/settings_storage.dart` | `getRuleOutbounds()`, `saveRuleOutbounds()`, `getRouteFinal()`, `saveRouteFinal()` |
| `lib/services/config_builder.dart` | Применение user outbound в `_applySelectableRules`, применение `route_final` |
| `lib/screens/settings_screen.dart` | Дропдаун рядом с каждым правилом, строка "Default traffic" |

## Критерии приёмки

- [ ] Рядом с каждым outbound-правилом отображается дропдаун выбора outbound.
- [ ] Правила без outbound (action-based) дропдаун не показывают.
- [ ] В дропдауне только активные группы (vpn-1/vpn-2 появляются если включены).
- [ ] Выбор сохраняется в `boxvpn_settings.json` и восстанавливается при следующем открытии.
- [ ] Сгенерированный конфиг содержит выбранные outbound в правилах.
- [ ] Строка "Default traffic" управляет `route.final` в конфиге.
- [ ] Если выбранный outbound отключён — используется дефолт из шаблона.
