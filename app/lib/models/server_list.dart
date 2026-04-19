import 'node_spec.dart';
import 'subscription_meta.dart';

/// Контейнер узлов (§1 спеки 026). Sealed: `SubscriptionServers` (fetch по
/// URL) vs `UserServers` (paste/file/qr/manual). Персистится на диск
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
        return UserServers.fromJson(j);
      default:
        throw FormatException('Unknown ServerList type: $t');
    }
  }
}

/// Статус последней попытки auto-update подписки.
enum UpdateStatus { never, ok, failed, inProgress }

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
      };

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
        nodes: nodes ?? this.nodes,
      );
}

enum UserSource { paste, file, qr, manual }

final class UserServers extends ServerList {
  final UserSource origin;
  final DateTime createdAt;
  final String rawBody; // оригинал paste'а для reparse в случае багов

  UserServers({
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

  factory UserServers.fromJson(Map<String, dynamic> j) => UserServers(
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
        rawBody: (j['raw_body'] as String?) ?? '',
      );

  UserServers copyWith({
    String? name,
    bool? enabled,
    String? tagPrefix,
    DetourPolicy? detourPolicy,
    UserSource? origin,
    DateTime? createdAt,
    String? rawBody,
    List<NodeSpec>? nodes,
  }) =>
      UserServers(
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

/// Политика применения detour-серверов (§1.3 спеки 026, перенесено из 018).
/// Хранится на `ServerList`, применяется inline в `buildConfig`.
class DetourPolicy {
  final bool registerDetourServers;
  final bool registerDetourInAuto;
  final bool useDetourServers;
  final String overrideDetour; // '' = no override

  const DetourPolicy({
    this.registerDetourServers = false,
    this.registerDetourInAuto = false,
    this.useDetourServers = true,
    this.overrideDetour = '',
  });

  static const defaults = DetourPolicy();

  factory DetourPolicy.fromJson(Map<String, dynamic> j) => DetourPolicy(
        registerDetourServers:
            (j['register_detour_servers'] as bool?) ?? false,
        registerDetourInAuto:
            (j['register_detour_in_auto'] as bool?) ?? false,
        useDetourServers: (j['use_detour_servers'] as bool?) ?? true,
        overrideDetour: (j['override_detour'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'register_detour_servers': registerDetourServers,
        'register_detour_in_auto': registerDetourInAuto,
        'use_detour_servers': useDetourServers,
        'override_detour': overrideDetour,
      };

  DetourPolicy copyWith({
    bool? registerDetourServers,
    bool? registerDetourInAuto,
    bool? useDetourServers,
    String? overrideDetour,
  }) =>
      DetourPolicy(
        registerDetourServers:
            registerDetourServers ?? this.registerDetourServers,
        registerDetourInAuto:
            registerDetourInAuto ?? this.registerDetourInAuto,
        useDetourServers: useDetourServers ?? this.useDetourServers,
        overrideDetour: overrideDetour ?? this.overrideDetour,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DetourPolicy &&
          registerDetourServers == other.registerDetourServers &&
          registerDetourInAuto == other.registerDetourInAuto &&
          useDetourServers == other.useDetourServers &&
          overrideDetour == other.overrideDetour);

  @override
  int get hashCode => Object.hash(registerDetourServers, registerDetourInAuto,
      useDetourServers, overrideDetour);
}
