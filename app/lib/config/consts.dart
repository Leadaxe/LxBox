/// Centralized string constants used across the app.
///
/// Values that also appear in `assets/wizard_template.json` must be kept
/// in sync manually. Template vars are the source of truth — dart
/// constants exist as compile-time mirrors for code that can't read the
/// template at runtime (UI checks, selectors, tests).
library;

// §267 — эти три const — compile-time зеркала `group_templates.magic_nodes.*`
// в `assets/wizard_template.json` (source of truth). Нужны там, где шаблон не
// читается в рантайме (case-метки, const-списки, UI/фильтры, тесты). Их
// синхронность с шаблоном стережёт `assertMagicNodeMirrors` в
// `template_loader.dart` (расхождение direct/block → StateError на load).

/// Имя-заготовка URLTest-группы, авто-выбирающей быстрейшую ноду.
///
/// §267 — зеркало `magic_nodes.auto`. У auto-ноды нет статического tag: реальный
/// per-channel тег собирается из `magic_nodes.auto.tpl` (`{parent_tag}-auto` →
/// `vpn-1-auto`, см. `Channel.autoTag` / `resolveTpl`). Эта константа — лишь
/// имя-маркер (иконка/фильтры/сортировка узнают auto по нему).
const kAutoOutboundTag = '✨auto';

/// Tag прямого outbound'а (без прокси — трафик идёт в обход туннеля наружу).
/// §267 — зеркало `magic_nodes.direct.tag`. Системный `{type: direct}`.
const kDirectOutboundTag = 'direct-out';

/// §201 — tag block-outbound'а (дроп трафика). Системный, `{type: block}`.
/// §267 — зеркало `magic_nodes.block.tag`. Опция селектора + route_final.
const kBlockOutboundTag = 'block';

/// Префикс в `tag`, помечающий ноду как detour-сервер (посредник-dialer,
/// не endpoint). Ставится:
///   - парсером при разборе chained-нод подписки (автоматически);
///   - юзером через toggle «Mark as detour server» в `node_settings_screen`.
///
/// Builder детектит этот префикс у main-ноды и применяет per-server
/// `DetourPolicy` вместо дефолтной регистрации в selector/auto (см.
/// `server_list_build.dart`). См. `docs/spec/tasks/006-per-node-detour-toggles.md`.
const kDetourTagPrefix = '⚙ ';

// §079 detour-marker detection + §085 R1 — display↔bare логика переехала в
// `services/tag_resolver.dart::TagResolver` (единый владелец domain-концепта
// «display-tag»). Здесь остаётся только сама константа-маркер.
