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

  /// §279 Phase 4 — статус = типизированный [UiMsg] (рендер по локали в
  /// build), `null` = статуса нет.
  UiMsg? status;

  SubscriptionEntry({
    required ServerList list,
    int? nodeCount,
    this.status,
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

  /// §323 — реакция на успешное авто-обновление. Для не-подписок значение
  /// смысла не имеет: их никто не фетчит, отдаём дефолт.
  SubscriptionOnUpdateAction get onUpdateAction => _list is SubscriptionServers
      ? (_list as SubscriptionServers).onUpdateAction
      : SubscriptionOnUpdateAction.rebuild;

  /// §289 — per-subscription слепок идентичности фетча. `null` = режим Default
  /// (глобальная идентичность). Пусто для не-подписок.
  SubscriptionIdentityOverride? get identity => _list is SubscriptionServers
      ? (_list as SubscriptionServers).identity
      : null;

  /// §289 — режим Custom активен (у подписки свой слепок идентичности).
  bool get hasCustomIdentity => identity != null;

  /// Количество chained-детур узлов (⚙). В `nodeCount` они не включены,
  /// потому что в списке `.nodes` детуры живут как поле `.chained` у
  /// главного узла, не отдельным элементом.
  /// §404 — считаем ЗВЕНЬЯ, а не узлов с цепочкой: многохоповый
  /// `dialerProxy` даёт больше одного outbound'а на владельца, и счётчик
  /// «+N⚙ nodes» должен показывать, сколько их реально уедет в конфиг.
  int get detourCount {
    var n = 0;
    for (final node in _list.nodes) {
      for (var hop = node.chained; hop != null; hop = hop.chained) {
        n++;
      }
    }
    return n;
  }

  bool get registerDetourServers => detourPolicy.registerDetourServers;
  bool get registerDetourInAuto => detourPolicy.registerDetourInAuto;
  bool get useDetourServers => detourPolicy.useDetourServers;
  String get overrideDetour => detourPolicy.overrideDetour;
  bool get replaceDetourChain => detourPolicy.replaceDetourChain;

  static String formatAgo(DateTime dt) => _formatAgo(dt);

  String get displayName {
    // §243 — у одиночного сервера (UserServer) поле name игнорируем:
    // источник правды — tag/label узла (правится в Node Settings). Непустой
    // name мог остаться от v2.11.0-импорта (писал туда имя файла) — показывать
    // его нельзя, иначе правка tag не отражается в списке Servers. Для
    // подписок и папок name работает как раньше.
    if (_list is! UserServer && name.isNotEmpty) return name;
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
    // §279 — display-имя составлено из user data (name/host/tag/URI) и не
    // локализуется; '(empty)'-маркер пустой записи оставлен английским
    // сознательно (граница §8: name-fallback'и не мигрируются).
    return '(empty)';
  }

  /// §285 — компонует локализованный статус в момент показа через
  /// getLocalText (render-path, без BuildContext-параметра).
  String subtitle() {
    final parts = <String>[];
    final s = status;
    if (s != null) parts.add(s.render());
    if (lastUpdated != null) parts.add(_formatAgo(lastUpdated!));
    return parts.join(' · ');
  }

  static String _formatAgo(DateTime dt) => relativeTime(DateTime.now(), dt);

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
  ///
  /// §129 — валидные спец-значения: `-1` = «Don't auto-update» (никогда,
  /// игнорировать серверный profile-update-interval), `0` = «Never (respect
  /// server)» (сами не по расписанию, но серверный заголовок принимаем).
  /// AutoUpdater.shouldUpdatePure пропускает подписки с interval ≤ 0 на
  /// авто-триггерах. Клампим только мусор < -1.
  set updateIntervalHours(int v) {
    final list = _list;
    if (list is! SubscriptionServers) return;
    final clamped = v < -1 ? -1 : v;
    _replaceList(list.copyWith(updateIntervalHours: clamped));
  }

  /// §323 — реакция на успешное авто-обновление. No-op для не-подписок.
  /// Persist через `controller.persistSources()` на стороне UI (как
  /// `updateIntervalHours` выше).
  set onUpdateAction(SubscriptionOnUpdateAction v) {
    final list = _list;
    if (list is! SubscriptionServers) return;
    _replaceList(list.copyWith(onUpdateAction: v));
  }

  /// §289 — включить режим Custom: инициализировать слепок копией текущих
  /// глобальных значений. No-op для не-подписок и если Custom уже активен.
  void enableCustomIdentity() {
    final list = _list;
    if (list is! SubscriptionServers || list.identity != null) return;
    _replaceList(
        list.copyWith(identity: SubscriptionIdentity.snapshotGlobal()));
  }

  /// §289 — выключить Custom: отбросить слепок (→ Default/глобальная). No-op
  /// для не-подписок. clearIdentity снимает поле в null (обычный `??` не может).
  void disableCustomIdentity() {
    final list = _list;
    if (list is! SubscriptionServers) return;
    _replaceList(list.copyWith(clearIdentity: true));
  }

  /// §289 — обновить слепок Custom (правка отдельных полей). No-op если Custom
  /// не активен (сначала [enableCustomIdentity]).
  void updateIdentity(SubscriptionIdentityOverride next) {
    final list = _list;
    if (list is! SubscriptionServers || list.identity == null) return;
    _replaceList(list.copyWith(identity: next));
  }

  /// §302 — заменить набор import-rules подписки целиком (после CRUD/reorder
  /// в редакторе). No-op для не-подписок. UI persist'ит через
  /// `controller.persistSources()`; правила вступают в силу на следующем
  /// refresh (существующие ноды не переразбираются на месте).
  void updateImportRules(List<ImportRule> rules) {
    final list = _list;
    if (list is! SubscriptionServers) return;
    _replaceList(list.copyWith(importRules: rules));
  }

  /// §302 — общий тумблер набора (не удаляя правила). No-op для не-подписок.
  set importRulesEnabled(bool v) {
    final list = _list;
    if (list is! SubscriptionServers) return;
    _replaceList(list.copyWith(importRulesEnabled: v));
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

  ServerList _copy({
    String? name,
    bool? enabled,
    String? tagPrefix,
    DetourPolicy? detourPolicy,
  }) =>
      switch (_list) {
        final SubscriptionServers s => s.copyWith(
            name: name,
            enabled: enabled,
            tagPrefix: tagPrefix,
            detourPolicy: detourPolicy,
          ),
        final UserServer u => u.copyWith(
            name: name,
            enabled: enabled,
            tagPrefix: tagPrefix,
            detourPolicy: detourPolicy,
          ),
        final FolderServers f => f.copyWith(
            name: name,
            enabled: enabled,
            tagPrefix: tagPrefix,
            detourPolicy: detourPolicy,
          ),
      };
}
