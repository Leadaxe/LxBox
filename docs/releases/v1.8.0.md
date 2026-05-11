# L×Box v1.8.0

«Backup overhaul + routing order fix» release. Главное:

- **§063 / §040 — backup format переписан** под полный snapshot
  `lxbox_settings.json` + native VPN toggles. Старый формат **silently терял**
  большинство user data (`custom_rules`, `tun_apps`, `enabled_groups`,
  `route_final`, `rule_outbounds`, `dns_options`). **Breaking:** старые
  backup-файлы reject'ятся при import — пере-export после обновления.
- **§062 — custom_rules cross-kind order fix**: storage order теперь end-to-end
  управляемый между preset/inline/srs (раньше builder ломал cross-kind
  ordering двумя независимыми проходами).
- **§053 — editor split** Stage 1+2+3: `custom_rule_edit_screen.dart`
  2060 → 456 LOC (−77%) через секции / tabs / `CustomRuleEditController`
  (`ChangeNotifier`).

**Quick links:**
[🐞 Fixes](#-fixes) ·
[✨ New](#-new) ·
[🔧 Changed](#-changed) ·
[🏗 Refactor](#-refactor) ·
[📚 Docs](#-docs) ·
[🇷🇺 На русском](#-lxbox-v180-на-русском)

---

## 🐞 Fixes

### §062 — custom_rules order broken между kind-ами (preset/inline/srs)

`SettingsStorage.custom_rules` это **один список** с mixed `kind`, и
UI/Debug API (`POST /rules/reorder`) предполагают что order этого списка =
order matching в sing-box `route.rules[]` (first-wins сверху вниз).

**Bug:** builder делал 2 прохода — `applyPresetBundles` (только `kind:preset`)
→ `applyCustomRules` (только `kind:inline|srs`) — поэтому в финальном
sing-box config все preset правила оказывались **перед** всеми inline/srs
**независимо** от storage order. Юзер ставил «RU apps inline» между
«Private IPs preset» и «Russian domains preset» в Routing → Rules, но
inline всегда уезжал в самый конец `route.rules[]`. Reorder API «провёртывался
вхолостую» в плане эффекта на routing.

**Fix:** новый `applyAllCustomRules` обходит rules в **одном цикле** с
dispatch по kind. Per-rule logic вынесена в private `_applyPresetSingle` /
`_applyInlineSingle` / `_applySrsSingle`. Старые public
`applyPresetBundles` / `applyCustomRules` остались как **shim** через те же
private — backward-compat для тестов.

Cross-preset rule_set dedup переехал с `mergeFragments` на
`RuleSetRegistry.tryRegisterRuleSet` (identical-skip / first-wins warning) —
работает естественно при per-rule обходе.

**Verified on device:** storage `[Block Ads, Private IPs, RU apps inline,
Russian domains, Russia-only, BitTorrent]` теперь даёт config
`[ads-all, ip_is_private, RU apps, ru-domains, ru-inside, bittorrent]` —
порядок 1-к-1 (за вычетом 3 system rules `resolve` / `sniff` / `dns hijack`
которые builder вставляет в голову).

Spec: [§062](../spec/tasks/062-custom-rules-unified-order.md).
Tests: 614 → 620, +6 в `test/services/builder/apply_all_custom_rules_test.dart`
покрывают cross-kind order, mixed kinds, identical-skip + cross-kind, DNS aspect.

### §064 — Custom rule editor View tab показывал пустой preview для disabled rules

Юзер открывал editor disabled-правила, переходил на View → видел
`{rule_set: [], rules: []}` потому что `applyCustomRules` фильтровал по
`cr.enabled`. Семантика «что родит в реальном конфиге» уместна для production
pipeline, но **не для editor preview** — юзер открыл editor именно для inspect'а
формы.

**Fix:** parameter `skipDisabled` на `applyCustomRules` (default `true` для
backward-compat; production pipeline `applyAllCustomRules` поведение не меняется).
`ViewTab` зовёт с `skipDisabled: false` — preview показывает «что родит при
включении» независимо от Switch.

Spec: [§064](../spec/tasks/064-view-tab-preview-independent-of-enabled.md).

---

## ✨ New

### Info tooltip на `Allow VPN bypass` toggle

VPN Settings → System → `Allow VPN bypass` теперь имеет `info_outline` icon
рядом с заголовком. Tap → tooltip на 12 секунд объясняет:

- **что делает** — `ConnectivityManager.bindProcessToNetwork()` bypass
- **когда полезно** — банкинг, captive portal detection, системные сервисы
  которые отказываются работать через VPN
- **что значит off** — strict tunnel (весь трафик через VPN)
- **когда применяется** — на следующий VPN connect

Тот же паттерн что в DNS settings (`Tooltip` с `triggerMode: tap`).

---

## 🔧 Changed

### Backup format переписан — full storage snapshot

Старый формат `{vars, server_lists}` на корне **не сохранял большую часть
пользовательских данных** — `custom_rules`, `tun_apps`, `enabled_groups`,
`enabled_rules`, `route_final`, `rule_outbounds`, `dns_options` живут как
top-level ключи `lxbox_settings.json`, а export'ил только `data['vars']`.
Inline rule_set'ы вида «Ru Apps» (57 пакетов через `CustomRule.inline`)
**исчезали при restore** silently.

**Новый wire-format:**
```jsonc
{
  "app": "lxbox",
  "kind": "snapshot",
  "created_at": "...",
  "source_app_version": "...",
  "storage": { /* lxbox_settings.json целиком */ },
  "vpn_settings": {
    "auto_start": ..., "keep_on_exit": ..., "background_mode": ...,
    "core_logs_enabled": ..., "allow_bypass": ...
  }
}
```

- `version` поле убрано — single-format. Файлы старого образца reject'ятся
  с message «Unsupported backup format. Re-export from a recent app version.»
- **`storage` блок** = deep-clone всего `lxbox_settings.json` через
  `SettingsStorage.exportRaw()`. Restore — через `replaceRaw(map, merge:)`:
  при `merge=false` overwrite целиком, при `merge=true` top-level merge
  с recursive vars upsert.
- **`vpn_settings` блок** — отдельный native-side state из `boxvpn_boot`
  SharedPreferences (BootReceiver читает at boot-time когда Flutter ещё
  не запущен; не перенесён в Flutter storage ради simplicity).
- **Категории UI — 5** (было 4): Server lists, Routing, App settings,
  **VPN system toggles** (новая), Debug API. Filter работает на уровне
  keys в `storage` map — будущие top-level настройки попадают в backup
  автоматически без правок allowlist'ов.
- Debug API `/backup/export|import` синхронизирован с UI — symmetric
  round-trip.

Spec: [§040 backup](../spec/features/040%20backup%20restore%20ui/spec.md).
Tests: 13 cases в [`backup_service_test.dart`](../../app/test/services/backup_service_test.dart)
— round-trip, selective categories, merge vs replace, legacy reject,
deep-clone semantics.

---

## 🏗 Refactor

### §053 — `custom_rule_edit_screen.dart` split

Stage 1 / 2 / 3 поэтапно вынесли editor's 2060 LOC monolith в композицию:

- **Stage 1 (v14080)** — 3 wifi widgets extracted: `widgets/wifi_entry.dart`,
  `wifi_saved_picker_sheet.dart`, `wifi_manual_add_dialog.dart` +
  validators + normalizers с unit-тестами.
- **Stage 2 (v14090)** — 7 секций + 2 shared widgets в
  `screens/custom_rule_edit/sections/` и `widgets/`. Sections — dumb
  `StatelessWidget` с props (controllers + callbacks); `ItemsField` —
  единственный `StatefulWidget` (подписан на controller через
  `addListener` для self-rebuild). Editor: 1795 → 1330 LOC.
- **Stage 3 (v14100)** — выделен **`CustomRuleEditController extends
  ChangeNotifier`** ([edit_controller.dart](../../app/lib/screens/custom_rule_edit/edit_controller.dart)):
  владеет всеми 8 `TextEditingController`-ами, флагами, коллекциями,
  async state + mutator'ами + `snapshot()` / `isDirty()` + pure async
  методами. Раздаётся вниз через `CustomRuleEditScope` (plain
  `InheritedNotifier`). Tabs выделены в `tabs/params_tab.dart`,
  `tabs/preset_params_tab.dart`, `tabs/view_tab.dart`. Editor scaffold:
  1330 → 456 LOC (−65%; от исходных 2060 — −77%). Save-icon обёрнут
  в `AnimatedBuilder` чтобы dirty-rebuild не дёргал весь AppBar.

На screen State остались только UI-actions требующие `BuildContext`:
save/back/delete dialog'и, cloud-menu, picker-вызовы, snackbar'ы.
Save flow unchanged.

Spec: [§053](../spec/tasks/053-custom-rule-editor-split.md).
Tests: 620 pass; analyzer clean.

---

## 📚 Docs

### §054 — Spec reorg: features vs tasks classification audit

`docs/spec/features/` теперь содержит **только живые** продуктовые /
архитектурные концепции. Семь демотированных в `docs/spec/tasks/`:

| Был | Стал | Reason |
|-----|------|--------|
| ~~001~~ mobile stack | [`055`](../spec/tasks/055-mobile-stack-decision/spec.md) | Historical architectural decision |
| ~~002~~ MVP scope | [`056`](../spec/tasks/056-mvp-scope-historical/spec.md) | Historical milestone |
| ~~004x~~ subscription parser | [`057`](../spec/tasks/057-subscription-parser-v1-superseded/spec.md) | Superseded by §026 |
| ~~005x~~ config generator | [`058`](../spec/tasks/058-config-generator-wizard-v1-superseded/spec.md) | Superseded by §026 |
| ~~013~~ routing | [`059`](../spec/tasks/059-routing-v1-superseded/spec.md) | Superseded by §030 |
| ~~039~~ libbox 1.13 migration | [`060`](../spec/tasks/060-libbox-1-13-migration/spec.md) | One-shot migration (Done) |
| ~~041~~ DNS rules refactor | [`061`](../spec/tasks/061-dns-rules-refactor/spec.md) | Refactor; live spec — §014 |

Освобождённые номера (001 / 002 / 004 / 005 / 013 / 039 / 041) **не
переиспользуются** — archive-ссылки сохраняются. Все cross-refs обновлены
в `docs/**/*.md`, `CHANGELOG.md`, `app/lib/**/*.dart`, `app/test/**/*.dart`;
grep на retired numbers — 0 hits.

Spec: [§054](../spec/tasks/054-spec-reorg-features-vs-tasks.md).

### ARCHITECTURE Feature Specs map + CHANGELOG order audit

Пост-реорг audit нашёл два расхождения:

1. **`docs/ARCHITECTURE.md` → Feature Specs** всё ещё перечисляла 7
   демотированных как live features → синхронизирована с
   `docs/spec/features/README.md` (демотированные в отдельной секции).
2. **CHANGELOG.md** — блок `[1.2.0] — 2026-04-18` стоял между
   `[1.4.0]` и `[1.3.1]` (chronologically wrong) → переставлен в
   правильный newest-first порядок.

### §047 — Public Intent API spec расширен

Добавлены outgoing events (broadcast intents от LxBox: `VPN_STATE_CHANGED`,
`CONFIG_RELOAD`, опционально `RULE_FIRED`) + 2 incoming actions
(`SET_RULE_ENABLED`, `SWITCH_PRESET_GROUP`) + symmetric input/output
pattern. Статус остаётся **Draft** — не имплементировано.

Spec: [§047](../spec/features/047%20public%20intent%20api/spec.md).

---

## 📦 Install

CI APK: `LxBox-v1.8.0-arm64-v8a.apk` (после tag'а).

`adb install -r LxBox-v1.8.0-arm64-v8a.apk` поверх 1.7.3 — настройки
сохраняются (`lxbox_settings.json` в внутренней storage app'а).

---

## 🇷🇺 L×Box v1.8.0 на русском

Minor-релиз с переписанным форматом backup'а и исправлением порядка правил.

**§062 — порядок правил роутинга наконец работает end-to-end.** Если ты
переставлял правила в Routing → Rules через drag-and-drop или Debug API
`/rules/reorder`, ты замечал что inline-правила (`kind:inline`) всегда
оказывались **в конце** независимо от того куда ты их перемещал. Это была
архитектурная особенность билдера — он шёл двумя проходами (сначала все
preset, потом все inline/srs), и storage order между kind-ами терялся.
Теперь builder идёт одним проходом — порядок в storage = порядок в
sing-box config.

**§064 — preview правила в editor теперь работает для disabled.**
Открываешь рулу с выключенным Switch → View → видишь как будет выглядеть
конфиг при включении. Раньше показывалось пусто.

**Backup format переписан.** Старый экспортил только `vars` — теряли
`custom_rules` / `tun_apps` / `enabled_groups` итд при restore. Теперь
backup это полный snapshot `lxbox_settings.json` + native VPN toggles.
**Backward incompatible** — backup'ы старого формата не импортируются.

**Allow VPN bypass теперь с подсказкой.** Если ты не помнил что это —
тапни на ⓘ рядом с переключателем, на 12 сек появится объяснение.

**Editor правил роутинга разобран на компоненты** ([§053](../spec/tasks/053-custom-rule-editor-split.md)).
Внутренний рефакторинг — поведение без изменений, но монолитный
`custom_rule_edit_screen.dart` (2060 LOC) разбит на секции / tabs /
state controller. Editor scaffold: 2060 → 456 LOC. На баги по форме
правил это не должно влиять; если что — сообщайте.

**Документация почищена** ([§054](../spec/tasks/054-spec-reorg-features-vs-tasks.md)).
`docs/spec/features/` теперь только живые спеки; исторические /
superseded переехали в `docs/spec/tasks/`. Это внутреннее — юзер
изменений не увидит.

---

## 🔗 Refs

- Spec: [§062 — custom_rules unified order](../spec/tasks/062-custom-rules-unified-order.md)
- Spec: [§053 — editor split](../spec/tasks/053-custom-rule-editor-split.md)
- Spec: [§063 / §040 — backup format](../spec/features/040%20backup%20restore%20ui/spec.md)
- Spec: [§054 — spec reorg](../spec/tasks/054-spec-reorg-features-vs-tasks.md)
- ARCHITECTURE: [build pipeline diagram](../ARCHITECTURE.md)
- CHANGELOG: [Unreleased section](../../CHANGELOG.md)
