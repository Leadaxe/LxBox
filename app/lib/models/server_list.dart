import 'package:collection/collection.dart';

import '../services/parser/body_decoder.dart';
import '../services/parser/parse_all.dart';
import 'core_reject_verdict.dart';
import 'dns_ref.dart';
import 'import_rule.dart';
import 'node_link.dart';
import 'node_sections.dart';
import 'node_spec.dart';
import 'subscription_meta.dart';

/// Контейнер узлов (§1 спеки 026). Sealed: `SubscriptionServers` (fetch по
/// URL) vs `UserServer` (paste/file/qr/manual) vs `FolderServers` (§234 —
/// папка ручных серверов, состав редактирует юзер). Хранится записями
/// `sources[]` контракта 1.0 — кодек `codec/source_record.dart` (§439).
sealed class ServerList {
  final String id; // uuid, стабилен на всём жизненном цикле
  final String name;
  final bool enabled;
  final String tagPrefix;
  final DetourPolicy detourPolicy;
  final List<NodeSpec> nodes; // mutable: перезаписывается на refresh/reparse

  ServerList({
    required this.id,
    required this.name,
    required this.enabled,
    required this.tagPrefix,
    required this.detourPolicy,
    List<NodeSpec>? nodes,
  }) : nodes = nodes ?? <NodeSpec>[];

  String get type;
}

/// Статус последней попытки auto-update подписки.
enum UpdateStatus { never, ok, failed, inProgress }

/// §323 — что делать после **успешного авто**-обновления подписки. Ручной ⟳
/// сюда не относится: там юзер сам видит плашку и жмёт Apply.
///
/// Причина существования поля: до §323 автообновление шло тем же путём, что
/// ручная правка (`_persist` → `configDirty` → пересборка → `saveParsedConfig`
/// при живом туннеле → плашка «restart to apply»). Подписка почти всегда
/// меняет конфиг, интервал бывает 1 час — плашка вылезала раз в час у юзера,
/// который ничего не трогал.
enum SubscriptionOnUpdateAction {
  /// Пересобрать конфиг и записать. Туннель продолжает крутить старый —
  /// плашка «restart to apply» остаётся, применяет юзер. Default: ровно
  /// прежнее наблюдаемое поведение, поэтому миграция не нужна.
  rebuild,

  /// Пересобрать, записать и (если туннель up) `reloadVPN()` — ядро
  /// перечитывает конфиг in-place. Плашки нет. Цена: туннель дропается ~3с,
  /// in-flight TCP умирают (см. §030).
  reload,

  /// Ничего: ноды обновлены в списке, `configDirty` стоит. Конфиг пересоберётся
  /// на следующем обычном триггере (возврат на home, Start, ручной Apply).
  none;

  static SubscriptionOnUpdateAction fromJson(dynamic raw) =>
      SubscriptionOnUpdateAction.values.firstWhere(
        (a) => a.name == raw,
        orElse: () => SubscriptionOnUpdateAction.rebuild,
      );
}

/// §289 — per-subscription override идентичности HTTP-фетча (§118). Полный
/// слепок всех переменных: когда у подписки `identity != null` (режим Custom),
/// фетч использует ТОЛЬКО эти значения и полностью игнорирует глобальный
/// `SubscriptionIdentity`. `null` (режим Default) → глобальные значения, как §118.
///
/// Не каскад/не пофайловый fallback: либо весь глобальный набор, либо весь
/// локальный слепок. Инициализируется копией глобальных при включении Custom;
/// отбрасывается (→ null) при возврате в Default.
class SubscriptionIdentityOverride {
  /// User-Agent. Пусто → дефолт из глобала (брендированный `LxBox-android`,
  /// см. `resolveSubscriptionUserAgent`).
  final String userAgent;

  /// Слать ли `x-hwid` + device-meta заголовки при фетче.
  final bool sendHwid;

  /// `x-hwid` (UUIDv4). Заголовок не кладём если пусто (или `sendHwid == false`).
  final String hwid;

  /// device-meta заголовки. Пусто → соответствующий заголовок не кладём.
  final String deviceOs;
  final String verOs;
  final String deviceModel;

  const SubscriptionIdentityOverride({
    this.userAgent = '',
    this.sendHwid = false,
    this.hwid = '',
    this.deviceOs = '',
    this.verOs = '',
    this.deviceModel = '',
  });

  Map<String, dynamic> toJson() => {
        if (userAgent.isNotEmpty) 'user_agent': userAgent,
        'send_hwid': sendHwid,
        if (hwid.isNotEmpty) 'hwid': hwid,
        if (deviceOs.isNotEmpty) 'device_os': deviceOs,
        if (verOs.isNotEmpty) 'ver_os': verOs,
        if (deviceModel.isNotEmpty) 'device_model': deviceModel,
      };

  SubscriptionIdentityOverride copyWith({
    String? userAgent,
    bool? sendHwid,
    String? hwid,
    String? deviceOs,
    String? verOs,
    String? deviceModel,
  }) =>
      SubscriptionIdentityOverride(
        userAgent: userAgent ?? this.userAgent,
        sendHwid: sendHwid ?? this.sendHwid,
        hwid: hwid ?? this.hwid,
        deviceOs: deviceOs ?? this.deviceOs,
        verOs: verOs ?? this.verOs,
        deviceModel: deviceModel ?? this.deviceModel,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SubscriptionIdentityOverride &&
          userAgent == other.userAgent &&
          sendHwid == other.sendHwid &&
          hwid == other.hwid &&
          deviceOs == other.deviceOs &&
          verOs == other.verOs &&
          deviceModel == other.deviceModel);

  @override
  int get hashCode =>
      Object.hash(userAgent, sendHwid, hwid, deviceOs, verOs, deviceModel);
}

const _eq = DeepCollectionEquality();

/// §439 п. 10 — отметка выключенного узла в записи хранится unix seconds:
/// равенство моделей сравнивает её с той же точностью (TTL-очистка от 24 ч
/// разницы в долях секунды не видит).
Map<String, int> _disabledSeconds(Map<String, DateTime> marks) => {
      for (final e in marks.entries)
        e.key: e.value.millisecondsSinceEpoch ~/ 1000,
    };

final class SubscriptionServers extends ServerList {
  final String url;
  final SubscriptionMeta? meta;
  final DateTime? lastUpdated;         // успешное обновление
  final DateTime? lastUpdateAttempt;   // любая попытка (fail или success)
  final UpdateStatus lastUpdateStatus;
  final int updateIntervalHours;
  final int lastNodeCount;
  /// Подряд фейлов с последнего успеха. Персистится, чтобы после рестарта
  /// показать юзеру "(3 fails)". Сбрасывается в 0 на успех. **Не используется
  /// для фризинга** — для этого есть in-memory `_failCounts` в `AutoUpdater`
  /// с maxFailsPerSession=5, которое сбрасывается на рестарт (спек §026).
  final int consecutiveFails;

  /// §283/§400 — per-node disable: идентичность ноды (тег, уникализированный
  /// внутри источника — см. services/node_hash.dart)
  /// → когда источник ноды последний раз видели в теле подписки (lastSeen —
  /// для TTL-очистки спящих отметок на успешном сетевом refresh). Оверлей
  /// поверх `nodes`: сами ноды остаются видны в UI (с toggle), но builder их
  /// не эмитит. Персистится (в отличие от nodes) и потому обязан жить в
  /// кодеке записи и в copyWith — поле без чтения молча терялось бы.
  final Map<String, DateTime> disabledHashes;

  /// Фича 478 / CANON §9.4 — оверлей ХРАНИМЫХ предупреждений узлов тем же
  /// ключом, что и [disabledHashes]: тег-идентичность → записи
  /// `{code, params}`. Сегодня здесь живёт ровно `core_rejected` — вердикт
  /// ядра, который пересчётом по телу не воспроизводится; прочие
  /// предупреждения по-прежнему вычисляются при разборе и не хранятся.
  /// Персистится рядом с `disabled` → обязан жить в кодеке записи и в
  /// copyWith; ключ в slice-таблице остаётся (§221), в файл вердикт
  /// страховки не едет (§489).
  final Map<String, List<StoredWarning>> nodeWarnings;

  /// §289 — per-subscription override идентичности фетча. `null` = режим Default
  /// (глобальный `SubscriptionIdentity`); объект = режим Custom (полный слепок).
  /// Персистится → обязан жить в кодеке записи и copyWith (как §283
  /// `disabledHashes`).
  final SubscriptionIdentityOverride? identity;

  /// §302 — per-subscription правила обработки тела на импорте (REPLACE +
  /// DISABLE, см. import_rule.dart). Пустой список = поведение как сейчас.
  /// Часть записи подписки → едет в backup вместе с ней (инвариант §221);
  /// обязан жить в кодеке записи и copyWith (как §283 `disabledHashes`).
  final List<ImportRule> importRules;

  /// §302 — общий тумблер набора правил. `false` → все правила подписки
  /// игнорируются на импорте (не удаляя их). Плюс per-rule `ImportRule.enabled`.
  final bool importRulesEnabled;

  /// §323 — реакция на успешное **авто**-обновление (см.
  /// [SubscriptionOnUpdateAction]). Персистится → обязан жить в кодеке записи
  /// и copyWith (как §283 `disabledHashes`).
  final SubscriptionOnUpdateAction onUpdateAction;

  SubscriptionServers({
    required super.id,
    required super.name,
    required super.enabled,
    required super.tagPrefix,
    required super.detourPolicy,
    required this.url,
    this.meta,
    this.lastUpdated,
    this.lastUpdateAttempt,
    this.lastUpdateStatus = UpdateStatus.never,
    this.updateIntervalHours = 24,
    this.lastNodeCount = 0,
    this.consecutiveFails = 0,
    this.disabledHashes = const {},
    this.nodeWarnings = const {},
    this.identity,
    this.importRules = const [],
    this.importRulesEnabled = true,
    this.onUpdateAction = SubscriptionOnUpdateAction.rebuild,
    super.nodes,
  });

  /// §302 — правила, реально применяемые на импорте: набор включён + правило
  /// включено + паттерн валиден. Пусто → тело подписки не трогается.
  List<ImportRule> get activeImportRules =>
      importRulesEnabled ? importRules.where((r) => r.isUsable).toList() : const [];

  @override
  String get type => 'subscription';

  SubscriptionServers copyWith({
    String? name,
    bool? enabled,
    String? tagPrefix,
    DetourPolicy? detourPolicy,
    String? url,
    SubscriptionMeta? meta,
    DateTime? lastUpdated,
    DateTime? lastUpdateAttempt,
    UpdateStatus? lastUpdateStatus,
    int? updateIntervalHours,
    int? lastNodeCount,
    int? consecutiveFails,
    Map<String, DateTime>? disabledHashes,
    Map<String, List<StoredWarning>>? nodeWarnings,
    SubscriptionIdentityOverride? identity,
    bool clearIdentity = false,
    List<ImportRule>? importRules,
    bool? importRulesEnabled,
    SubscriptionOnUpdateAction? onUpdateAction,
    List<NodeSpec>? nodes,
  }) =>
      SubscriptionServers(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        tagPrefix: tagPrefix ?? this.tagPrefix,
        detourPolicy: detourPolicy ?? this.detourPolicy,
        url: url ?? this.url,
        meta: meta ?? this.meta,
        lastUpdated: lastUpdated ?? this.lastUpdated,
        lastUpdateAttempt: lastUpdateAttempt ?? this.lastUpdateAttempt,
        lastUpdateStatus: lastUpdateStatus ?? this.lastUpdateStatus,
        updateIntervalHours: updateIntervalHours ?? this.updateIntervalHours,
        lastNodeCount: lastNodeCount ?? this.lastNodeCount,
        consecutiveFails: consecutiveFails ?? this.consecutiveFails,
        disabledHashes: disabledHashes ?? this.disabledHashes,
        nodeWarnings: nodeWarnings ?? this.nodeWarnings,
        // §289 — clearIdentity: true снимает Custom (→ Default); иначе обычный
        // ?? (передача identity меняет слепок, null-аргумент сохраняет старый).
        identity: clearIdentity ? null : (identity ?? this.identity),
        importRules: importRules ?? this.importRules,
        importRulesEnabled: importRulesEnabled ?? this.importRulesEnabled,
        onUpdateAction: onUpdateAction ?? this.onUpdateAction,
        nodes: nodes ?? this.nodes,
      );

  /// Равенство записи (§439): `nodes` — кэш выдачи (`sub_cache/`), в
  /// значение подписки не входит.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SubscriptionServers &&
          id == other.id &&
          name == other.name &&
          enabled == other.enabled &&
          tagPrefix == other.tagPrefix &&
          detourPolicy == other.detourPolicy &&
          url == other.url &&
          meta == other.meta &&
          lastUpdated == other.lastUpdated &&
          lastUpdateAttempt == other.lastUpdateAttempt &&
          lastUpdateStatus == other.lastUpdateStatus &&
          updateIntervalHours == other.updateIntervalHours &&
          lastNodeCount == other.lastNodeCount &&
          consecutiveFails == other.consecutiveFails &&
          _eq.equals(_disabledSeconds(disabledHashes),
              _disabledSeconds(other.disabledHashes)) &&
          _eq.equals(nodeWarnings, other.nodeWarnings) &&
          identity == other.identity &&
          _eq.equals(importRules, other.importRules) &&
          importRulesEnabled == other.importRulesEnabled &&
          onUpdateAction == other.onUpdateAction);

  @override
  int get hashCode => Object.hash(
        id,
        name,
        enabled,
        tagPrefix,
        detourPolicy,
        url,
        meta,
        lastUpdated,
        lastUpdateAttempt,
        lastUpdateStatus,
        updateIntervalHours,
        lastNodeCount,
        consecutiveFails,
        _eq.hash(_disabledSeconds(disabledHashes)),
        _eq.hash(nodeWarnings),
        identity,
        _eq.hash(importRules),
        importRulesEnabled,
        onUpdateAction,
      );
}

/// §219 — origin: write-only диагностические метаданные (пишутся в JSON /
/// видны в `/state/subs`, но нигде не влияют на поведение и не показываются
/// в UI). В текущем коде присваиваются только `paste` и `manual`; `file`
/// (file:-подписки идут как SubscriptionServers с `url:'file:<uuid>'`, §129) и
/// `qr` (сканер — незавершённый задел) не присваиваются. Значения оставлены:
/// удаление ломает десериализацию старых записей (есть orElse→manual, но
/// история origin потерялась бы) и задел QR-фичи.
enum UserSource { paste, file, qr, manual }

final class UserServer extends ServerList {
  /// §219 — write-only диагностика. Записью 1.0 не хранится (§439: имя
  /// `origin` занято контрактом): после чтения записи — умолчание `manual`.
  final UserSource origin;

  final String rawBody; // оригинал paste'а для reparse в случае багов

  /// §435 — секции узла (контракт ## 13): правила маршрута и DNS-записи,
  /// которые узел носит с собой. Форма хранения — ONE_NAMESPACE §2, с
  /// плейсхолдерами `@self` как есть. `null` = поля нет (пустые секции не
  /// пишутся). Истина — это поле; `importedSections` узла, найденные при
  /// перечитывании `raw_body`, на старте игнорируются.
  final NodeSections? sections;

  /// Фича 478 / CANON §9.4 — хранимые предупреждения ручного сервера:
  /// сегодня ровно `core_rejected`. Персистится рядом с `enabled` (ключ
  /// `warnings` записи источника). В бэкап вердикт страховки не едет (§489).
  final List<StoredWarning> warnings;

  UserServer({
    required super.id,
    required super.name,
    required super.enabled,
    required super.tagPrefix,
    required super.detourPolicy,
    this.origin = UserSource.manual,
    this.rawBody = '',
    this.warnings = const [],
    NodeSections? sections,
    super.nodes,
  }) : sections = (sections == null || sections.isEmpty) ? null : sections;

  @override
  String get type => 'user';

  UserServer copyWith({
    String? name,
    bool? enabled,
    String? tagPrefix,
    DetourPolicy? detourPolicy,
    UserSource? origin,
    String? rawBody,
    List<StoredWarning>? warnings,
    List<NodeSpec>? nodes,
    NodeSections? sections,
    // §435 — `sections ?? this.sections` не позволяет обнулить: явный флаг
    // (паттерн `clearDns` у правил).
    bool clearSections = false,
  }) =>
      UserServer(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        tagPrefix: tagPrefix ?? this.tagPrefix,
        detourPolicy: detourPolicy ?? this.detourPolicy,
        origin: origin ?? this.origin,
        rawBody: rawBody ?? this.rawBody,
        warnings: warnings ?? this.warnings,
        sections: clearSections ? null : (sections ?? this.sections),
        nodes: nodes ?? this.nodes,
      );

  /// Равенство записи (§439): `nodes` выводятся из [rawBody]; `name` (с §243
  /// пуст) и [origin] записью 1.0 не хранятся и в значение сервера не входят.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UserServer &&
          id == other.id &&
          enabled == other.enabled &&
          tagPrefix == other.tagPrefix &&
          detourPolicy == other.detourPolicy &&
          rawBody == other.rawBody &&
          _eq.equals(warnings, other.warnings) &&
          sections == other.sections);

  @override
  int get hashCode => Object.hash(
      id, enabled, tagPrefix, detourPolicy, rawBody, _eq.hash(warnings), sections);
}

/// §234 — член папки: самодостаточный парсируемый фрагмент (URI-строка,
/// WG-INI, JSON-outbound) + per-member toggle. Инвариант member ↔ нода 1:1
/// обеспечивается на импорте (контроллер сплитит вход по нодам); если raw
/// всё же парсится в несколько нод, берём первую.
final class FolderMember {
  final String raw;
  final bool enabled;

  /// Фича 478 / CANON §9.4 — хранимые предупреждения члена: сегодня ровно
  /// `core_rejected`. Персистится рядом с [enabled] (ключ `warnings`
  /// записи члена). В бэкап вердикт страховки не едет (§489).
  final List<StoredWarning> warnings;

  /// §456 — имя члена, хранимое полем записи (`tag`): у INI-источника тега в
  /// тексте нет, и узел разбирается с этим hint'ом. У ссылки/JSON пусто.
  final String nameHint;

  /// §237 — личный detour члена: ссылка на узел (D-112; [NodeLink.none] —
  /// нет). Аналог `DetourPolicy.overrideDetour` одиночного сервера; политика
  /// папки применяется к нему как подписка к родной цепочке (см.
  /// server_list_build). Сосед по папке — пара с `id` этой папки.
  final NodeLink detour;

  /// §435 — секции узла-члена (контракт ## 13), как у `UserServer.sections`.
  final NodeSections? sections;

  /// Распарсенная нода фрагмента; null = битый raw (member виден в UI как
  /// нечитаемый, юзер может отредактировать/удалить).
  final NodeSpec? node;

  FolderMember({
    required this.raw,
    this.enabled = true,
    this.warnings = const [],
    this.detour = NodeLink.none,
    this.nameHint = '',
    NodeSections? sections,
    NodeSpec? node,
  })  : sections = (sections == null || sections.isEmpty) ? null : sections,
        node = node ?? _parseFirst(raw, nameHint);

  /// §439 — член-группа (запись `kind: auto`, `codec/auto_group_record.dart`):
  /// текста нет, узел — сама группа. detour и секций у группы не бывает.
  ///
  /// Контракт 1.1.66 — у группы тела нет, и её `warnings` (например
  /// `group_member_missing`) пересчитать нечем: они едут как есть.
  FolderMember.auto(AutoSelectSpec group,
      {bool enabled = true, List<StoredWarning> warnings = const []})
      : this(raw: '', enabled: enabled, node: group, warnings: warnings);

  static NodeSpec? _parseFirst(String raw, String nameHint) {
    if (raw.trim().isEmpty) return null;
    try {
      final nodes =
          parseAll(decode(raw), nameHint: nameHint.isEmpty ? null : nameHint);
      return nodes.isEmpty ? null : nodes.first;
    } catch (_) {
      return null;
    }
  }

  FolderMember copyWith({
    String? raw,
    bool? enabled,
    List<StoredWarning>? warnings,
    NodeLink? detour,
    String? nameHint,
    NodeSections? sections,
    bool clearSections = false,
  }) =>
      FolderMember(
        raw: raw ?? this.raw,
        enabled: enabled ?? this.enabled,
        warnings: warnings ?? this.warnings,
        detour: detour ?? this.detour,
        nameHint: nameHint ?? this.nameHint,
        sections: clearSections ? null : (sections ?? this.sections),
        // Смена raw или имени → re-parse в конструкторе; иначе нода та же.
        node: raw == null && nameHint == null ? node : null,
      );

  /// Равенство записи (§439): [node] выводится из [raw]; у члена-группы
  /// текста нет, и значением служит сама группа.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FolderMember &&
          raw == other.raw &&
          enabled == other.enabled &&
          _eq.equals(warnings, other.warnings) &&
          detour == other.detour &&
          nameHint == other.nameHint &&
          sections == other.sections &&
          _sameGroup(node, other.node));

  static bool _sameGroup(NodeSpec? a, NodeSpec? b) => a is AutoSelectSpec
      ? b is AutoSelectSpec && a.sameGroupAs(b)
      : b is! AutoSelectSpec;

  @override
  int get hashCode =>
      Object.hash(raw, enabled, _eq.hash(warnings), detour, nameHint, sections);
}

/// §234 — папка ручных серверов: контейнер членов с общим toggle,
/// tag_prefix и detour-политикой на всех. Подписка в папку не кладётся
/// (у подписки составом владеет источник). `nodes` (база) = ноды только
/// включённых членов — builder работает без folder-ветвлений.
final class FolderServers extends ServerList {
  final List<FolderMember> members;

  /// Поле LxBox записи (`created_at`, §439): его отдаёт Debug API `/folders`.
  final DateTime createdAt;

  /// §284 — опции теста этой папки (override глобальных ping_options). null =
  /// брать глобальное значение. Хранятся в самом объекте папки (едут в backup).
  /// Папка «WARP GENERATOR» ставит IP-URL сюда, чтобы Test шёл без DNS.
  final String? pingUrl;
  final int? pingTimeoutMs;

  FolderServers({
    required super.id,
    required super.name,
    required super.enabled,
    required super.tagPrefix,
    required super.detourPolicy,
    List<FolderMember>? members,
    DateTime? createdAt,
    this.pingUrl,
    this.pingTimeoutMs,
  })  : members = members ?? <FolderMember>[],
        createdAt = createdAt ?? DateTime.now(),
        super(nodes: [
          for (final m in members ?? const <FolderMember>[])
            if (m.enabled && m.node != null) m.node!,
        ]);

  @override
  String get type => 'folder';

  /// Сколько членов выключено (для строки «N servers · M off»).
  /// §455 — raw-тексты членов, выровненные с [nodes] (тот же фильтр
  /// enabled+parsed, тот же порядок): сборка решает по ним, идёт ли член в
  /// конфиг дословно (`origin.kind: json`).
  List<String> get memberRaws => [
        for (final m in members)
          if (m.enabled && m.node != null) m.raw,
      ];

  int get disabledCount => members.where((m) => !m.enabled).length;

  /// §237 — личные detour'ы, выровненные с [nodes] (тот же фильтр
  /// enabled+parsed, тот же порядок). Builder применяет их пер-нодно.
  List<NodeLink> get nodeDetours => [
        for (final m in members)
          if (m.enabled && m.node != null) m.detour,
      ];

  FolderServers copyWith({
    String? name,
    bool? enabled,
    String? tagPrefix,
    DetourPolicy? detourPolicy,
    List<FolderMember>? members,
    String? pingUrl,
    int? pingTimeoutMs,
    bool clearPing = false,
  }) =>
      FolderServers(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        tagPrefix: tagPrefix ?? this.tagPrefix,
        detourPolicy: detourPolicy ?? this.detourPolicy,
        createdAt: createdAt,
        members: members ?? this.members,
        pingUrl: clearPing ? null : (pingUrl ?? this.pingUrl),
        pingTimeoutMs: clearPing ? null : (pingTimeoutMs ?? this.pingTimeoutMs),
      );

  /// Равенство записи (§439): `nodes` выводятся из [members].
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FolderServers &&
          id == other.id &&
          name == other.name &&
          enabled == other.enabled &&
          tagPrefix == other.tagPrefix &&
          detourPolicy == other.detourPolicy &&
          _eq.equals(members, other.members) &&
          createdAt == other.createdAt &&
          pingUrl == other.pingUrl &&
          pingTimeoutMs == other.pingTimeoutMs);

  @override
  int get hashCode => Object.hash(id, name, enabled, tagPrefix, detourPolicy,
      _eq.hash(members), createdAt, pingUrl, pingTimeoutMs);
}

/// §248 — сброс detour-ссылок на Направление [tag] (или его auto-двойник
/// `<tag>-auto`) у одного списка: `detourPolicy.overrideDetour` + личные
/// `FolderMember.detour`. Ссылка на Направление — корневая `{tag}` (D-112);
/// пара адресует узел контейнера и Направлением не бывает, поэтому омонимов
/// здесь нет. Возвращает копию с изменениями (null = нечего лечить) + счётчик.
///
/// Общее ядро: storage-heal (`_healDetourDirectionRefs`) и in-memory ресинк
/// `SubscriptionController.syncDetourDirectionRefsCleared` обязаны сбрасывать
/// одинаково, иначе следующий `_persist()` воскресит вылеченную ссылку.
({ServerList? healed, int count}) clearDetourDirectionRefs(
    ServerList l, String tag) {
  final autoTag = '$tag-auto';
  bool matches(NodeLink v) => v.isRoot && (v.tag == tag || v.tag == autoTag);

  var count = 0;
  ServerList next = l;
  if (matches(l.detourPolicy.overrideDetour)) {
    final p = l.detourPolicy.copyWith(overrideDetour: NodeLink.none);
    next = switch (l) {
      SubscriptionServers s => s.copyWith(detourPolicy: p),
      UserServer u => u.copyWith(detourPolicy: p),
      FolderServers f => f.copyWith(detourPolicy: p),
    };
    count++;
  }
  if (next is FolderServers) {
    var membersChanged = false;
    final ms = next.members.map((m) {
      if (matches(m.detour)) {
        membersChanged = true;
        count++;
        return m.copyWith(detour: NodeLink.none);
      }
      return m;
    }).toList();
    if (membersChanged) next = next.copyWith(members: ms);
  }
  return (healed: count > 0 ? next : null, count: count);
}

/// §441 (SPEC 129 §6, D-114) — `body.detour` DNS-серверов в секциях узлов
/// списка [l] (одиночный сервер, члены папки) по [retarget]
/// ([retargetDnsServerDetour]). Возвращает копию (null — нечего лечить) и
/// число переписанных серверов.
///
/// Общее ядро: storage-heal (`_healDnsServerDirectionRefs`) и in-memory
/// ресинк `SubscriptionController.syncSectionsDnsDetourRefsHealed` обязаны
/// переписывать одинаково, иначе следующий `_persist()` воскресит ссылку.
({ServerList? healed, int count}) retargetSectionsDnsDetours(
  ServerList l,
  Map<String, String> retarget,
) {
  var count = 0;
  NodeSections? heal(NodeSections? sections) {
    if (sections == null || sections.dnsServers.isEmpty) return null;
    var changed = false;
    final servers = <DnsServerInline>[];
    for (final d in sections.dnsServers) {
      final next = retargetDnsServerDetour(d, retarget);
      if (!identical(next, d)) {
        changed = true;
        count++;
      }
      servers.add(next);
    }
    return changed ? sections.copyWith(dnsServers: servers) : null;
  }

  switch (l) {
    case UserServer u:
      final s = heal(u.sections);
      return (healed: s == null ? null : u.copyWith(sections: s), count: count);
    case FolderServers f:
      var changed = false;
      final members = <FolderMember>[];
      for (final m in f.members) {
        final s = heal(m.sections);
        if (s != null) changed = true;
        members.add(s == null ? m : m.copyWith(sections: s));
      }
      return (
        healed: changed ? f.copyWith(members: members) : null,
        count: count,
      );
    case SubscriptionServers():
      return (healed: null, count: 0);
  }
}

/// Политика применения detour-серверов (§1.3 спеки 026, перенесено из 018).
/// Хранится на `ServerList`, применяется inline в `buildConfig`.
class DetourPolicy {
  final bool registerDetourServers;
  final bool registerDetourInAuto;
  final bool useDetourServers;
  /// Ссылка на узел, через который идёт источник (D-112); [NodeLink.none] —
  /// override не задан.
  final NodeLink overrideDetour;
  // §073 — поведение overrideDetour: false (default) = APPEND (нативная
  // цепочка из конфига сохраняется, overrideDetour подставляется как
  // tail); true = REPLACE (старое поведение, цепочка отбрасывается).
  final bool replaceDetourChain;

  const DetourPolicy({
    this.registerDetourServers = false,
    this.registerDetourInAuto = false,
    this.useDetourServers = true,
    this.overrideDetour = NodeLink.none,
    this.replaceDetourChain = false,
  });

  static const defaults = DetourPolicy();

  /// Флаги политики именами записи. Ссылку [overrideDetour] кодек записи
  /// (`codec/source_record.dart`) переносит полем `detour`.
  Map<String, dynamic> toJson() => {
        'register_detour_servers': registerDetourServers,
        'register_detour_in_auto': registerDetourInAuto,
        'use_detour_servers': useDetourServers,
        'replace_detour_chain': replaceDetourChain,
      };

  DetourPolicy copyWith({
    bool? registerDetourServers,
    bool? registerDetourInAuto,
    bool? useDetourServers,
    NodeLink? overrideDetour,
    bool? replaceDetourChain,
  }) =>
      DetourPolicy(
        registerDetourServers:
            registerDetourServers ?? this.registerDetourServers,
        registerDetourInAuto:
            registerDetourInAuto ?? this.registerDetourInAuto,
        useDetourServers: useDetourServers ?? this.useDetourServers,
        overrideDetour: overrideDetour ?? this.overrideDetour,
        replaceDetourChain:
            replaceDetourChain ?? this.replaceDetourChain,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DetourPolicy &&
          registerDetourServers == other.registerDetourServers &&
          registerDetourInAuto == other.registerDetourInAuto &&
          useDetourServers == other.useDetourServers &&
          overrideDetour == other.overrideDetour &&
          replaceDetourChain == other.replaceDetourChain);

  @override
  int get hashCode => Object.hash(registerDetourServers, registerDetourInAuto,
      useDetourServers, overrideDetour, replaceDetourChain);
}
