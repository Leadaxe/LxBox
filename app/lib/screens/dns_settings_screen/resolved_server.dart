// ===========================================================================
// §044: Typed render-layer for DNS servers (заменяет underscore-аннотации
// в Map'ах из §043).
// §117: + vars/varValues (template-серверы) и lockedByPreset (lifecycle).
// ===========================================================================

import '../../models/parser_config.dart' show WizardVar;

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
    this.presetId = '',
    this.vars = const [],
    this.varValues = const {},
    this.usedByRule,
    this.usedByList = const [],
  });

  final ServerKind kind;
  final String tag;
  final String description;
  final bool enabled;
  final Map<String, dynamic> body;
  final ServerKind? overrides;
  final String? presetLabel;

  /// §439 — `preset_id` пресета сервера (свой у preset-ref, канонический у
  /// override пресета); пусто — пресет не известен.
  final String presetId;

  /// §117: var-определения template-обёртки (`{vars, server}`). Только для
  /// `kind: template`; preset-vars редактируются в редакторе правила,
  /// inline-body редактируется как JSON.
  final List<WizardVar> vars;

  /// §117: выбранные значения vars из ref-записи (`varValues` в storage).
  final Map<String, String> varValues;

  /// §117 задача 3: имя routing-правила с активной DNS-опцией, ссылающегося
  /// на этот сервер. null = правила не ссылаются.
  final String? usedByRule;

  /// §680 — ссылки из самого списка: группы (`servers[]`), `domain_resolver`
  /// других серверов, значения DNS Final / Default Domain Resolver. Метки
  /// источников в порядке обнаружения. Лок удаления и выключения; сборка
  /// такой сервер не форсирует (он включён — ссылка жива).
  final List<String> usedByList;

  /// §680 — копия с источниками ссылок из списка.
  ResolvedServer withUsedByList(List<String> refs) => ResolvedServer(
        kind: kind,
        tag: tag,
        description: description,
        enabled: enabled,
        body: body,
        overrides: overrides,
        presetLabel: presetLabel,
        presetId: presetId,
        vars: vars,
        varValues: varValues,
        usedByRule: usedByRule,
        usedByList: List.unmodifiable(refs),
      );

  bool get isOverridden => kind == ServerKind.inline && overrides != null;
  bool get isUserOnly => kind == ServerKind.inline && overrides == null;

  /// §117 lifecycle: сервер реферится активным пресетом → управляемый
  /// (enabled-тоггл и delete заблокированы, build делает force-include).
  bool get lockedByPreset =>
      kind == ServerKind.preset || overrides == ServerKind.preset;

  /// §117 lifecycle (locked №7): реферимый активным пресетом ИЛИ правилом
  /// с DNS-опцией — сборка эмитит его независимо от `enabled`
  /// (force-include, [dnsServerRefEmitted]).
  bool get forceIncluded => lockedByPreset || usedByRule != null;

  /// §117 №7 + §680: на сервер ссылаются (пресет, правило, список) — не
  /// выключается / не удаляется независимо.
  bool get locked => forceIncluded || usedByList.isNotEmpty;

  /// §680 — все источники ссылки по порядку: пресет, правило, список.
  List<String> get lockedBySources => [
        if (lockedByPreset) presetLabel ?? 'preset',
        ?usedByRule,
        ...usedByList,
      ];

  /// Кто ссылается — для «used by <…>» в UI. §680: несколько источников —
  /// через запятую первые два, дальше «+N».
  String get lockedByLabel {
    final all = lockedBySources;
    if (all.length <= 2) return all.join(', ');
    return '${all.take(2).join(', ')} +${all.length - 2}';
  }
}
