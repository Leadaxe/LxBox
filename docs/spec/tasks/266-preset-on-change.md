# §266 — on_change пресета: FakeIP глушит resolve_enabled (@rule_enable AND @dns_enable)

**Статус:** РЕАЛИЗОВАНО, DEVICE-VERIFIED (CPH2411, 09.07.2026) — FakeIP on → `resolve_enabled=false`
в userVars (verified через `/diag/dump`); route-resolve исчезает после холодного рестарта VPN.
**Зависит от:** §232 (декларативный `on_change`), §257 (магическая `dns_enable`), §263 (why
resolve вреден при FakeIP), §264/§265 (`resolve_enabled` — глобальная в internal-секции).
**Тип:** расширение `on_change` (§232) с section-vars на ПРЕСЕТЫ + псевдо-var `@rule_enable`.

---

## 0. Проблема

Route-resolve обесценивает FakeIP (§263): при FakeIP реального резолва быть не должно, а
`resolve inbound:tun-in` форсит его. Юзер должен вручную выключать `resolve_enabled` при
включении FakeIP — легко забыть. Нужна автоматика: FakeIP активен → resolve выключен.

## 1. Решение — псевдо-var `@rule_enable` + on_change

**Формула:** `resolve_enabled = false` когда FakeIP включён как правило (`@rule_enable`) И его
DNS-аспект активен (`@dns_enable`); иначе `true`.

```json
{"name": "rule_enable", "type": "bool", "wizard_ui": "hidden",
  "default_value": "true", "required": false,
  "on_change": {"set": {
    "@resolve_enabled": {"#if": {"and": ["@rule_enable", "@dns_enable"], "value": "false", "else": "true"}}
  }}
}
```
Идентичный `on_change` висит и на `dns_enable` — оба входа формулы триггерят пересчёт при своём
изменении.

**Псевдо-vars** (не хранятся, вычисляются из состояния пресета):
- `@rule_enable` = `cr.enabled` (пресет включён свичем). Симметрия с `dns_enable` (§257).
- `@dns_enable` = §257 `presetDnsEnableVar` (DNS-аспект пресета).

## 2. Движок — `services/preset_on_change.dart`

`applyPresetOnChange(preset, cr)` — общий (любой пресет с `on_change`):
- собирает namespace `{rule_enable: cr.enabled, dns_enable: <varsValues/default>, ...userVars}`;
- для каждой var пресета с `on_change` резолвит `#if` (`evalIfScalar`);
- пишет цель в ГЛОБАЛЬНЫЙ userVars (`SettingsStorage.setVar`) — цель `resolve_enabled` глобальна.

Отличие от section-var `on_change` (`settings_screen._applyOnChange`): там источник и цель в
одной `VarValuesModel`; здесь источник — состояние пресета (custom_rules), цель — глобаль
(userVars). Пишем сразу в userVars (setVar).

## 3. Точки вызова (все 5, где меняются rule_enable/dns_enable)

| Точка | Файл:метод | var |
|---|---|---|
| Создание пресета из каталога | `routing_screen._copyPreset` | rule_enable (нач. enabled) |
| Toggle свича в списке | `routing_screen` onSwitchChanged | rule_enable |
| Toggle enabled в редакторе | `edit_controller.setEnabled` | rule_enable |
| Toggle dns_enable в редакторе | `edit_controller.onBoolVarToggle` | dns_enable |
| Toggle dns_enable в DNS Settings | `dns_settings_screen._togglePresetDnsEnable` | dns_enable |

## 4. Грабля (device-caught) — required-var роняет пресет

`rule_enable` без `default_value` = required по дефолту модели (`WizardVar.fromJson`:
`required ?? true`) без значения → `expandPreset` (preset_expand.dart:133) прерывал ВЕСЬ пресет
(«required var rule_enable unset») → fakeip dns_servers/dns_rules НЕ эмитились. on_change при
этом работал (отдельный путь) — баг выглядел как «on_change ок, DNS нет».
**Фикс:** `default_value:"true"` + `required:false`. Реальное значение подставляет on_change из
`cr.enabled`; в развёртке нужен лишь безопасный дефолт. УРОК: любая псевдо/hidden-var, чьё
значение приходит извне, ОБЯЗАНА иметь default_value или required:false.

## 5. Поведение (device-verified)

| Состояние | resolve_enabled |
|---|---|
| FakeIP on + dns_enable on | **false** (глушим route-resolve) |
| FakeIP off | true (вернулась) |
| FakeIP on, dns_enable off | true (DNS-аспект off → не глушим) |

on_change = **событие** (§232, разовый эффект): срабатывает при переключении, не форсит
состояние. Юзер может вручную вернуть resolve. Изменение resolve_enabled попадает в route.rules
после rebuild/холодного рестарта VPN (on_change пишет userVars сразу, конфиг догоняет).

## 6. Тесты

`test/services/preset_on_change_test.dart` (5, реальный шаблон): вкл→false, выкл→true,
dns off→true, идемпотентность, ru-direct (без on_change) не трогается. + регрессия в
`preset_expand_test.dart`: реальный fakeip эмитит dns (rule_enable не ломает).
