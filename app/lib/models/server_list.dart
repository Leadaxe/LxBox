import '../services/parser/body_decoder.dart';
import '../services/parser/parse_all.dart';
import 'node_spec.dart';
import 'subscription_meta.dart';

/// Контейнер узлов (§1 спеки 026). Sealed: `SubscriptionServers` (fetch по
/// URL) vs `UserServer` (paste/file/qr/manual) vs `FolderServers` (§234 —
/// папка ручных серверов, состав редактирует юзер). Персистится на диск
/// `List<ServerList>` с дискриминатором `type`.
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

  Map<String, dynamic> toJson();

  static ServerList fromJson(Map<String, dynamic> j) {
    final t = j['type'] as String?;
    switch (t) {
      case 'subscription':
        return SubscriptionServers.fromJson(j);
      case 'user':
        return UserServer.fromJson(j);
      case 'folder':
        return FolderServers.fromJson(j);
      default:
        throw FormatException('Unknown ServerList type: $t');
    }
  }
}

/// Статус последней попытки auto-update подписки.
enum UpdateStatus { never, ok, failed, inProgress }

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

  factory SubscriptionIdentityOverride.fromJson(Map<String, dynamic> j) =>
      SubscriptionIdentityOverride(
        userAgent: (j['user_agent'] as String?) ?? '',
        sendHwid: (j['send_hwid'] as bool?) ?? false,
        hwid: (j['hwid'] as String?) ?? '',
        deviceOs: (j['device_os'] as String?) ?? '',
        verOs: (j['ver_os'] as String?) ?? '',
        deviceModel: (j['device_model'] as String?) ?? '',
      );

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
}

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

  /// §283 — per-node disable: identity-хеш ноды (см. services/node_hash.dart)
  /// → когда источник ноды последний раз видели в теле подписки (lastSeen —
  /// для TTL-очистки спящих отметок на успешном сетевом refresh). Оверлей
  /// поверх `nodes`: сами ноды остаются видны в UI (с toggle), но builder их
  /// не эмитит. Персистится (в отличие от nodes) и потому обязан жить в
  /// трио toJson/fromJson/copyWith — merge-импорт backup гоняет записи через
  /// fromJson→toJson, поле только в toJson молча терялось бы.
  final Map<String, DateTime> disabledHashes;

  /// §289 — per-subscription override идентичности фетча. `null` = режим Default
  /// (глобальный `SubscriptionIdentity`); объект = режим Custom (полный слепок).
  /// Персистится → обязан жить в трио toJson/fromJson/copyWith (как §283
  /// `disabledHashes`), иначе merge-импорт backup (fromJson→toJson) молча терял бы.
  final SubscriptionIdentityOverride? identity;

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
    this.identity,
    super.nodes,
  });

  @override
  String get type => 'subscription';

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'id': id,
        'name': name,
        'enabled': enabled,
        'tag_prefix': tagPrefix,
        'detour_policy': detourPolicy.toJson(),
        'url': url,
        if (meta != null) 'meta': meta!.toJson(),
        if (lastUpdated != null) 'last_updated': lastUpdated!.toIso8601String(),
        if (lastUpdateAttempt != null)
          'last_update_attempt': lastUpdateAttempt!.toIso8601String(),
        'last_update_status': lastUpdateStatus.name,
        'update_interval_hours': updateIntervalHours,
        'last_node_count': lastNodeCount,
        'consecutive_fails': consecutiveFails,
        if (disabledHashes.isNotEmpty)
          'disabled_hashes': disabledHashes
              .map((k, v) => MapEntry(k, v.toIso8601String())),
        if (identity != null) 'identity': identity!.toJson(),
      };

  /// §283 — толерантный парс: не-Map → пусто, битые значения-даты — скип
  /// записи (отметка без валидного lastSeen бесполезна для TTL).
  static Map<String, DateTime> _disabledHashesFromJson(dynamic raw) {
    if (raw is! Map) return const {};
    final out = <String, DateTime>{};
    raw.forEach((k, v) {
      final t = v is String ? DateTime.tryParse(v) : null;
      if (t != null) out[k.toString()] = t;
    });
    return out;
  }

  factory SubscriptionServers.fromJson(Map<String, dynamic> j) =>
      SubscriptionServers(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
        tagPrefix: (j['tag_prefix'] as String?) ?? '',
        detourPolicy: DetourPolicy.fromJson(
            (j['detour_policy'] as Map?)?.cast<String, dynamic>() ?? const {}),
        url: (j['url'] as String?) ?? '',
        meta: j['meta'] == null
            ? null
            : SubscriptionMeta.fromJson(
                (j['meta'] as Map).cast<String, dynamic>()),
        lastUpdated: (j['last_updated'] as String?) == null
            ? null
            : DateTime.tryParse(j['last_updated'] as String),
        lastUpdateAttempt: (j['last_update_attempt'] as String?) == null
            ? null
            : DateTime.tryParse(j['last_update_attempt'] as String),
        lastUpdateStatus: UpdateStatus.values.firstWhere(
          (s) => s.name == j['last_update_status'],
          orElse: () => UpdateStatus.never,
        ),
        updateIntervalHours:
            (j['update_interval_hours'] as num?)?.toInt() ?? 24,
        lastNodeCount: (j['last_node_count'] as num?)?.toInt() ?? 0,
        consecutiveFails: (j['consecutive_fails'] as num?)?.toInt() ?? 0,
        disabledHashes: _disabledHashesFromJson(j['disabled_hashes']),
        identity: j['identity'] == null
            ? null
            : SubscriptionIdentityOverride.fromJson(
                (j['identity'] as Map).cast<String, dynamic>()),
      );

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
    SubscriptionIdentityOverride? identity,
    bool clearIdentity = false,
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
        // §289 — clearIdentity: true снимает Custom (→ Default); иначе обычный
        // ?? (передача identity меняет слепок, null-аргумент сохраняет старый).
        identity: clearIdentity ? null : (identity ?? this.identity),
        nodes: nodes ?? this.nodes,
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
  final UserSource origin;
  final DateTime createdAt;
  final String rawBody; // оригинал paste'а для reparse в случае багов

  UserServer({
    required super.id,
    required super.name,
    required super.enabled,
    required super.tagPrefix,
    required super.detourPolicy,
    required this.origin,
    required this.createdAt,
    this.rawBody = '',
    super.nodes,
  });

  @override
  String get type => 'user';

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'id': id,
        'name': name,
        'enabled': enabled,
        'tag_prefix': tagPrefix,
        'detour_policy': detourPolicy.toJson(),
        'origin': origin.name,
        'created_at': createdAt.toIso8601String(),
        if (rawBody.isNotEmpty) 'raw_body': rawBody,
      };

  factory UserServer.fromJson(Map<String, dynamic> j) {
    final rawBody = (j['raw_body'] as String?) ?? '';
    // Реконструируем `nodes` из rawBody — toJson хранит только raw,
    // экономя место и избегая дрейфа сериализации NodeSpec. Без этого
    // после рестарта app узлы UserServer пропадают (NodeSettingsScreen
    // → пустой `nodes` → бесконечный спиннер на `_load()`).
    final nodes = <NodeSpec>[];
    if (rawBody.isNotEmpty) {
      try {
        nodes.addAll(parseAll(decode(rawBody)));
      } catch (_) {
        // Некорректный raw — оставляем nodes пустым, пользователь увидит
        // empty entry и сможет удалить.
      }
    }
    return UserServer(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? '',
      enabled: (j['enabled'] as bool?) ?? true,
      tagPrefix: (j['tag_prefix'] as String?) ?? '',
      detourPolicy: DetourPolicy.fromJson(
          (j['detour_policy'] as Map?)?.cast<String, dynamic>() ?? const {}),
      origin: UserSource.values.firstWhere(
        (e) => e.name == j['origin'],
        orElse: () => UserSource.manual,
      ),
      createdAt: DateTime.tryParse((j['created_at'] as String?) ?? '') ??
          DateTime.now(),
      rawBody: rawBody,
      nodes: nodes,
    );
  }

  UserServer copyWith({
    String? name,
    bool? enabled,
    String? tagPrefix,
    DetourPolicy? detourPolicy,
    UserSource? origin,
    DateTime? createdAt,
    String? rawBody,
    List<NodeSpec>? nodes,
  }) =>
      UserServer(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        tagPrefix: tagPrefix ?? this.tagPrefix,
        detourPolicy: detourPolicy ?? this.detourPolicy,
        origin: origin ?? this.origin,
        createdAt: createdAt ?? this.createdAt,
        rawBody: rawBody ?? this.rawBody,
        nodes: nodes ?? this.nodes,
      );
}

/// §234 — член папки: самодостаточный парсируемый фрагмент (URI-строка,
/// WG-INI, JSON-outbound) + per-member toggle. Инвариант member ↔ нода 1:1
/// обеспечивается на импорте (контроллер сплитит вход по нодам); если raw
/// всё же парсится в несколько нод, берём первую.
final class FolderMember {
  final String raw;
  final bool enabled;

  /// §237 — личный detour члена: display-form тег outbound'а ('' = нет).
  /// Аналог `DetourPolicy.overrideDetour` одиночного сервера; политика папки
  /// применяется к нему как подписка к родной цепочке (см. server_list_build).
  final String detour;

  /// Распарсенная нода фрагмента; null = битый raw (member виден в UI как
  /// нечитаемый, юзер может отредактировать/удалить).
  final NodeSpec? node;

  FolderMember({
    required this.raw,
    this.enabled = true,
    this.detour = '',
    NodeSpec? node,
  }) : node = node ?? _parseFirst(raw);

  static NodeSpec? _parseFirst(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final nodes = parseAll(decode(raw));
      return nodes.isEmpty ? null : nodes.first;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'raw': raw,
        'enabled': enabled,
        if (detour.isNotEmpty) 'detour': detour,
      };

  factory FolderMember.fromJson(Map<String, dynamic> j) => FolderMember(
        raw: (j['raw'] as String?) ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
        detour: (j['detour'] as String?) ?? '',
      );

  FolderMember copyWith({String? raw, bool? enabled, String? detour}) =>
      FolderMember(
        raw: raw ?? this.raw,
        enabled: enabled ?? this.enabled,
        detour: detour ?? this.detour,
        // Смена raw → re-parse в конструкторе (node: null); иначе нода та же.
        node: raw == null ? node : null,
      );
}

/// §234 — папка ручных серверов: контейнер членов с общим toggle,
/// tag_prefix и detour-политикой на всех. Подписка в папку не кладётся
/// (у подписки составом владеет источник). `nodes` (база) = ноды только
/// включённых членов — builder работает без folder-ветвлений.
final class FolderServers extends ServerList {
  final List<FolderMember> members;
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
  int get disabledCount => members.where((m) => !m.enabled).length;

  /// §237 — личные detour'ы, выровненные с [nodes] (тот же фильтр
  /// enabled+parsed, тот же порядок). Builder применяет их пер-нодно.
  List<String> get nodeDetours => [
        for (final m in members)
          if (m.enabled && m.node != null) m.detour,
      ];

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'id': id,
        'name': name,
        'enabled': enabled,
        'tag_prefix': tagPrefix,
        'detour_policy': detourPolicy.toJson(),
        'created_at': createdAt.toIso8601String(),
        'members': members.map((m) => m.toJson()).toList(),
        if (pingUrl != null) 'ping_url': pingUrl,
        if (pingTimeoutMs != null) 'ping_timeout_ms': pingTimeoutMs,
      };

  factory FolderServers.fromJson(Map<String, dynamic> j) => FolderServers(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
        tagPrefix: (j['tag_prefix'] as String?) ?? '',
        detourPolicy: DetourPolicy.fromJson(
            (j['detour_policy'] as Map?)?.cast<String, dynamic>() ?? const {}),
        createdAt: DateTime.tryParse((j['created_at'] as String?) ?? '') ??
            DateTime.now(),
        members: ((j['members'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => FolderMember.fromJson(m.cast<String, dynamic>()))
            .toList(),
        pingUrl: (j['ping_url'] as String?)?.trim().isNotEmpty == true
            ? (j['ping_url'] as String).trim()
            : null,
        pingTimeoutMs: (j['ping_timeout_ms'] as num?)?.toInt(),
      );

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
}

/// §248 — сброс detour-ссылок на канал [tag] (или его auto-двойник
/// `<tag>-auto`) в '' у одного списка: `detourPolicy.overrideDetour` +
/// личные `FolderMember.detour`. Интра-омонимы пропускаются: значение,
/// равное bare-тегу распарсенного члена ТОЙ ЖЕ папки (включая выключенных —
/// toggle члена не должен молча менять смысл ссылки), означает члена, а не
/// канал. Возвращает копию с изменениями (null = нечего лечить) + счётчик.
///
/// Общее ядро: storage-heal (`_healDetourChannelRefs`) и in-memory ресинк
/// `SubscriptionController.syncDetourChannelRefsCleared` обязаны сбрасывать
/// одинаково, иначе следующий `_persist()` воскресит вылеченную ссылку.
({ServerList? healed, int count}) clearDetourChannelRefs(
    ServerList l, String tag) {
  final autoTag = '$tag-auto';
  bool matches(String v) => v == tag || v == autoTag;

  final memberBare = l is FolderServers
      ? <String>{
          for (final m in l.members)
            if (m.node != null) m.node!.tag,
        }
      : const <String>{};

  var count = 0;
  ServerList next = l;
  final override = l.detourPolicy.overrideDetour;
  if (matches(override) && !memberBare.contains(override)) {
    final p = l.detourPolicy.copyWith(overrideDetour: '');
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
      if (matches(m.detour) && !memberBare.contains(m.detour)) {
        membersChanged = true;
        count++;
        return m.copyWith(detour: '');
      }
      return m;
    }).toList();
    if (membersChanged) next = next.copyWith(members: ms);
  }
  return (healed: count > 0 ? next : null, count: count);
}

/// Политика применения detour-серверов (§1.3 спеки 026, перенесено из 018).
/// Хранится на `ServerList`, применяется inline в `buildConfig`.
class DetourPolicy {
  final bool registerDetourServers;
  final bool registerDetourInAuto;
  final bool useDetourServers;
  final String overrideDetour; // '' = no override
  // §073 — поведение overrideDetour: false (default) = APPEND (нативная
  // цепочка из конфига сохраняется, overrideDetour подставляется как
  // tail); true = REPLACE (старое поведение, цепочка отбрасывается).
  final bool replaceDetourChain;

  const DetourPolicy({
    this.registerDetourServers = false,
    this.registerDetourInAuto = false,
    this.useDetourServers = true,
    this.overrideDetour = '',
    this.replaceDetourChain = false,
  });

  static const defaults = DetourPolicy();

  factory DetourPolicy.fromJson(Map<String, dynamic> j) => DetourPolicy(
        registerDetourServers:
            (j['register_detour_servers'] as bool?) ?? false,
        registerDetourInAuto:
            (j['register_detour_in_auto'] as bool?) ?? false,
        useDetourServers: (j['use_detour_servers'] as bool?) ?? true,
        overrideDetour: (j['override_detour'] as String?) ?? '',
        // Старые backup'ы без ключа → default false (append). См. §073
        // locked decision #4 (потенциально меняет поведение существующих
        // юзеров с override — release notes должен это подсветить).
        replaceDetourChain: (j['replace_detour_chain'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'register_detour_servers': registerDetourServers,
        'register_detour_in_auto': registerDetourInAuto,
        'use_detour_servers': useDetourServers,
        'override_detour': overrideDetour,
        'replace_detour_chain': replaceDetourChain,
      };

  DetourPolicy copyWith({
    bool? registerDetourServers,
    bool? registerDetourInAuto,
    bool? useDetourServers,
    String? overrideDetour,
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
