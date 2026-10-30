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
    this.usedByResolver = false,
    this.usedByList = const [],
    this.danglingResolver = '',
    this.groupMembersInList = 0,
    this.groupLiveMembers = 0,
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

  /// §696 — сервер выбран в DNS Final / Default Domain Resolver или член
  /// (рекурсивно) такой группы: сборка эмитит его независимо от `enabled`.
  /// Подписи лока — из [usedByList] (пикеры, группа).
  final bool usedByResolver;

  /// §680 — ссылки из самого списка: группы (`servers[]`), `domain_resolver`
  /// других серверов, значения DNS Final / Default Domain Resolver. Метки
  /// источников в порядке обнаружения. Лок удаления и выключения; сборка
  /// такой сервер не форсирует (он включён — ссылка жива).
  final List<String> usedByList;

  /// §695 — цель `domain_resolver` (строка или `{server}`, у template после
  /// подстановки vars), которой нет в списке; пусто — ключа нет или цель
  /// есть. Сборка такой ключ снимает (heal §680), ядро идёт через Default
  /// Domain Resolver.
  final String danglingResolver;

  /// §695 — у группы: сколько тегов `servers[]` реально есть в списке
  /// (независимо от `enabled`); у не-группы 0.
  final int groupMembersInList;

  /// §695 — у группы: сколько тегов `servers[]` есть в списке и включены
  /// (или `forceIncluded`) — столько членов оставит сборка (§312); у
  /// не-группы 0.
  final int groupLiveMembers;

  bool get isGroup => body['type'] == 'group';

  /// §695 — выключенную группу без живых членов включить нельзя: сборка
  /// получила бы пустую группу (фатальный `EmptyDnsGroup`).
  bool get enableBlockedEmptyGroup =>
      isGroup && !enabled && !forceIncluded && groupLiveMembers == 0;

  /// §680/§695 — копия с состоянием относительно списка: источники ссылок,
  /// висячий `domain_resolver`, счётчики членов группы.
  ResolvedServer withListState({
    bool? usedByResolver,
    List<String>? usedByList,
    String? danglingResolver,
    int? groupMembersInList,
    int? groupLiveMembers,
  }) =>
      ResolvedServer(
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
        usedByResolver: usedByResolver ?? this.usedByResolver,
        usedByList: usedByList == null
            ? this.usedByList
            : List.unmodifiable(usedByList),
        danglingResolver: danglingResolver ?? this.danglingResolver,
        groupMembersInList: groupMembersInList ?? this.groupMembersInList,
        groupLiveMembers: groupLiveMembers ?? this.groupLiveMembers,
      );

  bool get isOverridden => kind == ServerKind.inline && overrides != null;
  bool get isUserOnly => kind == ServerKind.inline && overrides == null;

  /// §117 lifecycle: сервер реферится активным пресетом → управляемый
  /// (enabled-тоггл и delete заблокированы, build делает force-include).
  bool get lockedByPreset =>
      kind == ServerKind.preset || overrides == ServerKind.preset;

  /// §117 lifecycle (locked №7): реферимый активным пресетом ИЛИ правилом
  /// с DNS-опцией ИЛИ (§696) пикером DNS Final / Default Domain Resolver —
  /// сборка эмитит его независимо от `enabled` (force-include,
  /// [dnsServerRefEmitted]).
  bool get forceIncluded =>
      lockedByPreset || usedByRule != null || usedByResolver;

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
