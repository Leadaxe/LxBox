part of '../home_controller.dart';

/// Выбор узла и группы на главном экране: pull-to-refresh групп, применение
/// выбранной группы, выбор члена selector-группы (§565) и смена узла (§605).
/// Вынесено `part`'ом из `home_controller.dart` (задача 740) — та же
/// библиотека и тот же `HomeController`, тела методов не менялись. Общие с
/// контроллером поля/хелперы объявлены абстрактно; реализацию даёт
/// `HomeController`.
mixin _NodeSelectionMixin on ChangeNotifier {
  // --- surface, предоставляемая HomeController ---
  HomeState get _state;
  CcChannel get _cc;
  void _emit(HomeState next);
  void _addDebug(DebugSource source, String message);
  void _applyGroups(List<CcGroup> ccGroups);
  Future<void> _pushNotificationLabels();

  /// §122/SPEC015 — ручной pull-to-refresh (свайп вниз на списке нод). Тянет
  /// свежий снапшот групп через unary `getGroups` (детерминированно, не
  /// пересоздавая screenClient как раньше). `null` (ядро не STARTED) → оставляем
  /// текущее; непустой → применяем. Закрывает остаточную гонку push'а.
  Future<void> pullToRefresh() async {
    if (!_state.tunnelUp) {
      _applyGroups(_state.ccGroups);
      return;
    }
    final groups = await _cc.getGroups();
    if (!_state.tunnelUp) return;
    if (groups != null) {
      _applyGroups(groups);
    } else {
      _applyGroups(_state.ccGroups);
    }
  }

  Future<void> applyGroup(String? tag) async {
    if (tag == null) {
      _emit(
        _state.copyWith(
          nodes: <String>[],
          activeInGroup: null,
          highlightedNode: null,
        ),
      );
      return;
    }
    final group = _state.groupOf(tag);
    if (group == null) return;
    final nodes = group.items.map((e) => e.tag).toList();
    final now = group.selected.isEmpty ? null : group.selected;
    _emit(
      _state.copyWith(
        nodes: nodes,
        activeInGroup: now,
        highlightedNode: now,
      ),
    );
    // §047 Шаг 2 — mirror в native-кеш: активная нода/группа (для condition-
    // плагина) + списки нод текущей группы и всех групп (для Spinner'а выбора
    // в edit-Activity setting-плагина). Покрывает авто-выбор URLTest.
    BoxVpnClient.I.setAutomationActiveState(
      node: now,
      group: tag,
      nodes: nodes,
      groups: _state.groups,
    );
    // §123 — activeInGroup стал известен → обновить подтекст шторки.
    await _pushNotificationLabels();
  }

  /// §565 / задача 570 — наблюдатель выбора члена selector-группы (главный
  /// экран и экран узла): Home передаёт его в `SubscriptionController`,
  /// который запоминает выбор у своей группы (папки или подписки), чтобы он
  /// пережил перезапуск. Зовётся только после принятого ядром выбора.
  void Function(String group, String node)? onMemberSelected;

  /// §565 / задача 570 — выбрать члена [nodeTag] в selector-группе [group]
  /// вживую, не делая её выбранной группой главного экрана (экран узла).
  /// `false` — туннеля нет или ядро выбор отвергло.
  Future<bool> selectInGroup(String group, String nodeTag) async {
    if (group == _state.selectedGroup) {
      await switchNode(nodeTag);
      return _state.activeInGroup == nodeTag;
    }
    if (!_state.tunnelUp) return false;
    try {
      final ok = await _cc.selectOutbound(group, nodeTag);
      if (!ok) return false;
      final fresh = await _cc.getGroups();
      if (fresh != null) _applyGroups(fresh);
      _addDebug(DebugSource.app, 'Node selected in $group: $nodeTag');
      onMemberSelected?.call(group, nodeTag);
      return true;
    } catch (e) {
      _addDebug(DebugSource.app, 'Node switch error: $e');
      return false;
    }
  }

  /// §605 — `false` только когда ядро отвергло выбор (пойманная ошибка):
  /// automation-мост по нему шлёт `VPN_ERROR`. Ранний выход и уже активная
  /// нода — `true` (менять нечего, это не отказ).
  Future<bool> switchNode(String nodeTag) async {
    final group = _state.selectedGroup;
    if (group == null || !_state.tunnelUp) return true;
    final prevNode = _state.activeInGroup;
    // §290 — уже активна: не делать re-select и не рвать соединения группы
    // (ядро по галке Направления, §143 §9) на ровном месте. Общий путь UI + automation:
    // тап по подсвеченной ноде тоже не должен дёргать сеть. Ждущему Tasker'у
    // шлём лёгкое подтверждение (gated за State), иначе Wait Event уйдёт в
    // timeout — смены нет, поэтому НЕ ACTIVE_NODE_CHANGED.
    if (prevNode == nodeTag) {
      AutomationEventEmitter.I.emitNodeAlreadyActive(nodeTag, group);
      return true;
    }
    _emit(_state.copyWith(busy: true, highlightedNode: nodeTag));
    try {
      // §122 — выбор ноды через CommandClient `selectOutbound` (unary RPC),
      // не Clash PUT /proxies/<group>.
      final ok = await _cc.selectOutbound(group, nodeTag);
      if (!ok) throw const FormatException('selectOutbound rejected');
      // §143 §9 — обрыв соединений при смене узла делает ядро по галке
      // Направления (`interrupt_exist_connections`, SPEC 064); тумблер
      // приложения снят 01.11.2026.
      // §122/SPEC015 — после selectOutbound ТЯНЕМ свежий снапшот через
      // getGroups-pull, а не reloadProxies() поверх СТАРОГО `_state.ccGroups`
      // (там `selected` ещё прежний → горела старая нода до ручного свайпа).
      // Раньше выручал groups-push с новым `selected`, но он приходит не сразу/
      // не всегда — pull детерминирован. Оптимистично сразу подсветим выбранную
      // (highlightedNode уже = nodeTag), затем pull подтвердит `activeInGroup`.
      final fresh = await _cc.getGroups();
      if (fresh != null) {
        _applyGroups(fresh);
      } else {
        // ядро не отдало (редко) — пере-применим что есть + оптимистично выбор.
        _applyGroups(_state.ccGroups);
        _emit(_state.copyWith(activeInGroup: nodeTag));
      }
      _addDebug(DebugSource.app, 'Node selected: $nodeTag');
      onMemberSelected?.call(group, nodeTag);
      // §047 — outgoing state event (gated, default OFF). reason=user: явный
      // выбор ноды (через UI или automation SWITCH_NODE — оба идут сюда).
      AutomationEventEmitter.I
          .emitNodeChanged(prevNode, nodeTag, group, 'user');
      // §047 Шаг 2 — mirror в native-кеш для Locale condition-плагина.
      BoxVpnClient.I.setAutomationActiveState(node: nodeTag, group: group);
      return true;
    } catch (e) {
      _emit(_state.copyWith(
          lastError: PrefixedMsg(ErrPrefix.switchFailed, formatUserError(e))));
      _addDebug(DebugSource.app, 'Node switch error: $e');
      return false;
    } finally {
      _emit(_state.copyWith(busy: false));
    }
  }
}
