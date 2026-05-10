# 053 — CustomRuleEditScreen split: 2060-line State в композицию виджетов

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата | 2026-05-10 |
| Связанные | [`030 custom routing`](../features/030%20custom%20routing/spec.md) — sealed `CustomRule`; [`051 custom rule wifi conditions`](./051-custom-rule-wifi-conditions.md) — последний big-add (+539 LOC wifi секции в editor) |
| Затронутые файлы | `app/lib/screens/custom_rule_edit_screen.dart` (split source) → `app/lib/screens/custom_rule_edit/` (новая папка с секциями); `app/lib/widgets/wifi_saved_picker_sheet.dart` (extract); tests / smoke |

## Цель

`custom_rule_edit_screen.dart` — **2060+ строк в одном `_CustomRuleEditScreenState`**. С каждой новой фичей (§030 inline → §011 sealed split → §033 preset rendering → §045 bool var toggles → §051 wifi section) State разбухает. Сейчас содержит:

- 8 `TextEditingController` (name + 6 match-полей + srsUrl)
- 7 flags (`_enabled`, `_ipIsPrivate`, `_kind`, `_outbound`, `_protocols`, `_packages`, `_varsValues`)
- §051 wifi state: `_wifiNetworks: List<_WifiEntry>` (Phase 2)
- §045 preset-bool downloading: `_boolVarDownloading: Set<String>`
- Save logic + dirty-check + outbound rename + name collision
- 3 tabs (Params / View / JSON) — каждый рендерится отдельным методом
- Section-builders: `_matchSection`, `_portSection`, `_protocolSection`, `_appsSection`, `_srsSection`, `_wifiSection`
- §051 nested: `_pickSavedWifi` bottom sheet (~200 LOC), `_manualAddWifi` dialog (~80 LOC)
- Validators: `_isValidDomain`, `_isValidPort`, `_isValidPortRange`, `_isValidBssid`, `_isValidUrl`
- Normalizers: `_normalizedDomains`, `_normalizedCidrs`, `_normalizedPorts`, `_normalizedPortRanges`, `_normalizedKeywords`
- Helpers: `_itemsField`, `_sectionHeader`, `_invalidCount`, `_splitRaw`, `_pasteInto`
- Preset-rendering: `_buildPresetParams`, `_buildPresetVarWidget`, `_onBoolVarToggle`, `_resolvePresetSrsPaths`
- JSON tab logic
- Mutators: `_snapshot`, `_save`, `_handleBack`, `_showCloudMenu`, `_delete`, `_downloadSrs`

Большая часть — pure UI без shared state с другими секциями. Прямо просится split.

## Текущие pain points

1. **Locality of behaviour сломана**. Чтобы добавить новое поле в Match section, нужно править: state field + initState + _snapshot + _matchSection + JSON tab + dirty-check. 6 мест на одно изменение.
2. **Testability ≈ 0**. Каждая section — приватный метод на State. Unit test для wifi section невозможен без monкing всего editor'а.
3. **Cognitive load**: Cmd+P → custom_rule_edit_screen.dart → scroll 2060 строк. Не находишь нужное за 30 сек — ушёл в файл.
4. **Risk при изменении**: side-effect одного controller на rebuild целого State.
5. **§051 wifi section добавила ещё ~500 LOC** — обращало внимание что rate of growth не sustainable.

## Целевая структура

```
app/lib/screens/
├── custom_rule_edit_screen.dart            ← orchestration scaffold (≤ 200 LOC)
└── custom_rule_edit/
    ├── _state.dart                          ← shared state (ChangeNotifier-based controller)
    ├── _save_logic.dart                     ← _save, _snapshot, dirty-check, _handleBack
    ├── _validators.dart                     ← _isValidDomain/Port/PortRange/Bssid/Url
    ├── _normalizers.dart                    ← _normalized* + _splitRaw
    ├── sections/
    │   ├── match_section.dart               ← Domain/Suffix/Keyword/CIDR fields
    │   ├── port_section.dart                ← Port + PortRange fields
    │   ├── protocol_section.dart            ← chips Wrap
    │   ├── apps_section.dart                ← AppPicker entry
    │   ├── srs_section.dart                 ← URL + cloud-button + state
    │   ├── wifi_section.dart                ← §051 chip-list + 3 buttons
    │   └── outbound_section.dart            ← OutboundPicker wrapper
    ├── tabs/
    │   ├── params_tab.dart                  ← существующий `_buildParamsTab`
    │   ├── view_tab.dart                    ← существующий `_buildJsonTab` (View)
    │   └── preset_params.dart               ← §033/§045 preset rendering
    └── widgets/
        ├── items_field.dart                 ← multi-line TextField + Paste/Clear
        ├── section_header.dart              ← `_sectionHeader` extracted
        └── wifi_saved_picker_sheet.dart     ← §051 bottom sheet (extract `_pickSavedWifi`)
```

Top-level: каждая section = `StatefulWidget` с своим contracted props (callbacks `onChanged`, initial values). State в shared controller, sections подписываются на ChangeNotifier.

## Подход

### Подходящие patterns

1. **State controller** (вариант чистый) — `CustomRuleEditController extends ChangeNotifier` живёт в `_CustomRuleEditScreenState`, держит controllers + flags + collections. Sections читают через `InheritedWidget` или `Provider`. Все mutations → controller method → notify → секции rebuild только по `select` watching.
2. **`ValueNotifier`-фрагменты** (вариант мелкозернистый) — каждое поле = свой `ValueNotifier`, section подписывается через `ValueListenableBuilder`. Минимум rebuild'ов, но multiplied API surface.

Рекомендация: **#1 (controller + Provider)**. Provider уже в pubspec'е через transitive deps. Однонаправленный data flow.

### Этапы

**Stage 1 — Extract без architecture change** (low risk, immediate readability win):
- Validators / normalizers → standalone files, top-level functions
- `_itemsField` / `_sectionHeader` → standalone widgets в `widgets/`
- `_pickSavedWifi` → `WifiSavedPickerSheet` StatefulWidget с onSelect callback
- `_manualAddWifi` → standalone function returning `Future<_WifiEntry?>`
- Cost ~ 1 день, минус ~400 LOC из главного файла

**Stage 2 — Section-as-Widget** (medium risk):
- Каждый `_xxxSection` → `XxxSection extends StatefulWidget` с пропсами
- State controller передаёт shared editing state
- Cost ~ 2 дня. Кропотливо но прямолинейно.

**Stage 3 — Tab separation + state controller** (high impact):
- Tabs выносятся в свои Widgets
- `CustomRuleEditController` с ChangeNotifier
- Cost ~ 2 дня + тесты на controller

Total: ~ 5 дней с тестами + smoke.

### Что **не** делаем

- **Не меняем sealed `CustomRule` модель** — она здоровая.
- **Не меняем save flow** — `_snapshot()` остаётся источником истины для serialization.
- **Не вводим Riverpod / Bloc** — overengineering для одной кнопки. Provider + ChangeNotifier хватает.
- **Не пишем golden tests** — slow + flaky. Unit-test'ы для validators / save logic — да.

## Risks

- **Merge conflicts** во время refactor'а если параллельно идёт §051/§052-style работа. Mitigation: делать в одном sprint без cross-cutting features.
- **Hidden coupling** между sections (e.g., kind switch → reset SRS state). Каждый transition state→state нужно перенести в controller-method.
- **Preset rendering** (§033) — самый сложный кусок, потенциально trapdoor. Оставить на Stage 3 или вынести в отдельную таску 054.

## Tests

- Unit: validators (existing inline, переносятся как functions) + normalizers.
- Unit: `CustomRuleEditController` — name change, kind switch, save snapshot equality, dirty detection.
- Smoke на устройстве: создать rule всех 3 kind'ов через UI, save + reopen → fields preserved. Wifi chips: Add current / Manual / Pick saved + delete from history. Cancel-without-save → confirm dialog → discard.

## Acceptance

- [ ] `custom_rule_edit_screen.dart` ≤ 250 LOC (только scaffold)
- [ ] Section widgets accept `initial` + emit `onChanged` (или работают через controller)
- [ ] Save flow unchanged: same `_CustomRuleEditResult.saved(rule)` + same JSON shape
- [ ] Existing tests pass (`flutter test` 548+)
- [ ] New unit tests для validators + controller (≥ 10)
- [ ] Smoke: создать inline + srs + preset правила через UI без regression

## Out of scope

- Migration storage. Schema same.
- Refactor `CustomRule` model (sealed split done in task 011).
- Touch builder pipeline (`post_steps.dart` etc.).
- Visual redesign — keep current UI 1:1.
