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
