// ===========================================================================
// §044: Typed render-layer for DNS servers (заменяет underscore-аннотации
// в Map'ах из §043).
// ===========================================================================

/// Порядок enum-значений = порядок render'а в UI (§044): template первым
/// (системные defaults), потом preset (от active preset'ов), потом inline
/// (user-defined / overrides). `_displayedServers` сортирует по `kind.index`.
enum ServerKind {
  template,
  preset,
  inline;

  static ServerKind? tryParse(String s) {
    switch (s) {
      case 'inline':
        return ServerKind.inline;
      case 'preset':
        return ServerKind.preset;
      case 'template':
        return ServerKind.template;
    }
    return null;
  }

  String get name => toString().split('.').last;
}

/// §044: typed wrapper для render'а DNS-сервера в UI. Заменяет Map с
/// underscore-полями (`_kind`/`_overrides`/`_preset_label`).
///
/// Источники полей:
/// - `kind`/`tag`/`enabled` — `dns_options.servers[i]`
/// - `description` — `dns_options.servers[i].description` если override; иначе
///   из canonical (template/preset by tag)
/// - `body` — для inline это `dns_options.servers[i].body`; для template/preset —
///   canonical lookup. В обоих случаях с injected `tag` (single source of truth).
/// - `overrides`/`presetLabel` — computed (kind canonical'а если ref overrides).
class ResolvedServer {
  const ResolvedServer({
    required this.kind,
    required this.tag,
    required this.description,
    required this.enabled,
    required this.body,
    this.overrides,
    this.presetLabel,
  });

  final ServerKind kind;
  final String tag;
  final String description;
  final bool enabled;
  final Map<String, dynamic> body;
  final ServerKind? overrides;
  final String? presetLabel;

  bool get isOverridden => kind == ServerKind.inline && overrides != null;
  bool get isUserOnly => kind == ServerKind.inline && overrides == null;
}
