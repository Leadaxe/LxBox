part of '../subscription_controller.dart';

/// UI-обёртка вокруг `ServerList`. Хранит кэшированный nodeCount и статус.
/// Делегирует мутации полей на wrapped список через `copyWith` + persist
/// через контроллер.
///
/// Вынесено `part`'ом из `subscription_controller.dart` — та же библиотека,
/// поэтому library-private доступ (`_replaceList`, `_formatAgo`) к/из
/// `SubscriptionController` сохраняется идентично исходнику.
class SubscriptionEntry extends ChangeNotifier {
  ServerList _list;
  int nodeCount;
  String status;

  SubscriptionEntry({
    required ServerList list,
    int? nodeCount,
    this.status = '',
  })  : _list = list,
        nodeCount = nodeCount ??
            (list is SubscriptionServers ? list.lastNodeCount : list.nodes.length);

  ServerList get list => _list;

  String get id => _list.id;
  String get name => _list.name;
  bool get enabled => _list.enabled;
  String get tagPrefix => _list.tagPrefix;
  DetourPolicy get detourPolicy => _list.detourPolicy;
  String get type => _list.type;

  /// URL подписки (пусто для UserServer).
  String get url => _list is SubscriptionServers ? (_list as SubscriptionServers).url : '';

  /// Inline-URI строки (пусто для SubscriptionServers).
  List<String> get connections {
    if (_list is UserServer) {
      final raw = (_list as UserServer).rawBody;
      if (raw.isEmpty) return const [];
      return raw
          .split(RegExp(r'\r?\n'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const [];
  }

  DateTime? get lastUpdated =>
      _list is SubscriptionServers ? (_list as SubscriptionServers).lastUpdated : null;

  SubscriptionMeta? get meta =>
      _list is SubscriptionServers ? (_list as SubscriptionServers).meta : null;

  int get uploadBytes => meta?.uploadBytes ?? 0;
  int get downloadBytes => meta?.downloadBytes ?? 0;
  int get totalBytes => meta?.totalBytes ?? 0;
  int get expireTimestamp => meta?.expireTimestamp ?? 0;
  String get supportUrl => meta?.supportUrl ?? '';
  String get webPageUrl => meta?.webPageUrl ?? '';
  int get updateIntervalHours => _list is SubscriptionServers
      ? (_list as SubscriptionServers).updateIntervalHours
      : 0;

  int get consecutiveFails => _list is SubscriptionServers
      ? (_list as SubscriptionServers).consecutiveFails
      : 0;

  UpdateStatus get lastUpdateStatus => _list is SubscriptionServers
      ? (_list as SubscriptionServers).lastUpdateStatus
      : UpdateStatus.never;

  /// Количество chained-детур узлов (⚙). В `nodeCount` они не включены,
  /// потому что в списке `.nodes` детуры живут как поле `.chained` у
  /// главного узла, не отдельным элементом.
  int get detourCount =>
      _list.nodes.where((n) => n.chained != null).length;

  bool get registerDetourServers => detourPolicy.registerDetourServers;
  bool get registerDetourInAuto => detourPolicy.registerDetourInAuto;
  bool get useDetourServers => detourPolicy.useDetourServers;
  String get overrideDetour => detourPolicy.overrideDetour;
  bool get replaceDetourChain => detourPolicy.replaceDetourChain;

  static String formatAgo(DateTime dt) => _formatAgo(dt);

  String get displayName {
    if (name.isNotEmpty) return name;
    if (url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      if (uri != null && uri.host.isNotEmpty) return uri.host;
      return url.length > 40 ? '${url.substring(0, 40)}…' : url;
    }
    if (_list.nodes.isNotEmpty) {
      return _list.nodes.first.label.isNotEmpty
          ? _list.nodes.first.label
          : _list.nodes.first.tag;
    }
    final conns = connections;
    if (conns.isNotEmpty) {
      final c = conns.first;
      if (c.startsWith('{')) {
        final tagMatch = RegExp(r'"tag"\s*:\s*"([^"]+)"').firstMatch(c);
        if (tagMatch != null) return tagMatch.group(1)!;
      }
      return c.length > 40 ? '${c.substring(0, 40)}...' : c;
    }
    return '(empty)';
  }

  String get subtitle {
    final parts = <String>[];
    if (status.isNotEmpty) parts.add(status);
    if (lastUpdated != null) parts.add(_formatAgo(lastUpdated!));
    return parts.join(' · ');
  }

  static String _formatAgo(DateTime dt) =>
      relativeTime(DateTime.now(), dt);

  void _replaceList(ServerList next) {
    _list = next;
    notifyListeners();
  }

  // ─── UI-facing mutable setters (persist via controller.persistSources) ───
  //
  // Каждый setter мутирует обёрнутый ServerList через `copyWith` по типу.
  // UI после каждого set должен вызвать `controller.persistSources()`, чтобы
  // записать на диск. Так же было в v1 ProxySource-паттерне.

  set name(String v) => _replaceList(_copy(name: v));
  set enabled(bool v) => _replaceList(_copy(enabled: v));
  set tagPrefix(String v) => _replaceList(_copy(tagPrefix: v));

  /// Только для SubscriptionServers. Пользовательский override дефолта
  /// `profile-update-interval` (24ч). AutoUpdater читает значение через
  /// `updateIntervalHours` каждый раз при проверке — persist'им через
  /// `controller.persistSources()` на стороне UI.
  set updateIntervalHours(int v) {
    final list = _list;
    if (list is! SubscriptionServers) return;
    final clamped = v < 1 ? 1 : v;
    _replaceList(list.copyWith(updateIntervalHours: clamped));
  }

  set registerDetourServers(bool v) =>
      _replaceList(_copy(detourPolicy: detourPolicy.copyWith(registerDetourServers: v)));
  set registerDetourInAuto(bool v) =>
      _replaceList(_copy(detourPolicy: detourPolicy.copyWith(registerDetourInAuto: v)));
  set useDetourServers(bool v) =>
      _replaceList(_copy(detourPolicy: detourPolicy.copyWith(useDetourServers: v)));
  set overrideDetour(String v) =>
      _replaceList(_copy(detourPolicy: detourPolicy.copyWith(overrideDetour: v)));
  set replaceDetourChain(bool v) =>
      _replaceList(_copy(detourPolicy: detourPolicy.copyWith(replaceDetourChain: v)));

  /// §128 — атомарно выставляет `overrideDetour` + `replaceDetourChain` одним
  /// `copyWith` (один persist). Нужно для «Force direct-out» (tag=`direct-out`,
  /// replace=true) и для смены пунктов detour-dropdown без двойной записи.
  void setDetourOverride(String tag, {required bool replace}) =>
      _replaceList(_copy(
          detourPolicy: detourPolicy.copyWith(
              overrideDetour: tag, replaceDetourChain: replace)));

  ServerList _copy({
    String? name,
    bool? enabled,
    String? tagPrefix,
    DetourPolicy? detourPolicy,
  }) {
    if (_list is SubscriptionServers) {
      return (_list as SubscriptionServers).copyWith(
        name: name,
        enabled: enabled,
        tagPrefix: tagPrefix,
        detourPolicy: detourPolicy,
      );
    }
    return (_list as UserServer).copyWith(
      name: name,
      enabled: enabled,
      tagPrefix: tagPrefix,
      detourPolicy: detourPolicy,
    );
  }
}
