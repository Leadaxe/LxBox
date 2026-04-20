/// Centralized string constants used across the app.
///
/// Values that also appear in `assets/wizard_template.json` must be kept
/// in sync manually. Template vars are the source of truth — dart
/// constants exist as compile-time mirrors for code that can't read the
/// template at runtime (UI checks, selectors, tests).
library;

/// Tag of the URLTest group that auto-selects the fastest node.
///
/// **Source of truth:** `auto_proxy_tag` variable in
/// `assets/wizard_template.json` (hidden, non-editable). If you change
/// either side, change the other AND add a one-shot migration in
/// `SettingsStorage` for existing user data (`CustomRule.target` renamed).
const kAutoOutboundTag = '✨auto';

/// Префикс в `tag`, помечающий ноду как detour-сервер (посредник-dialer,
/// не endpoint). Ставится:
///   - парсером при разборе chained-нод подписки (автоматически);
///   - юзером через toggle «Mark as detour server» в `node_settings_screen`.
///
/// Builder детектит этот префикс у main-ноды и применяет per-server
/// `DetourPolicy` вместо дефолтной регистрации в selector/auto (см.
/// `server_list_build.dart`). См. `docs/spec/tasks/006-per-node-detour-toggles.md`.
const kDetourTagPrefix = '⚙ ';
