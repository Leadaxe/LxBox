part of '../subscription_controller.dart';

/// Бюджет узлов (задача 714): доли подписок и перерезка из кэша тела.
///
/// Доля считается раздачей [splitNodeBudget] по текущим записям: ручное
/// ([countManualBudgetNodes]) вычитается первым, остаток делится между
/// включёнными подписками. Сама обрезка идёт в воркере разбора
/// ([cutNodesToQuota] из `parseCachedBody` / `parseFetchedWithRules`);
/// здесь — только входы для него и перерезка без сети, когда доли сменились
/// (включение/выключение подписки, ручные серверы и члены папок, сам
/// бюджет).
extension _NodeBudgetOps on SubscriptionController {
  /// Доля подписки [target]. Её собственный размер до разбора неизвестен:
  /// доля тогда — максимум, что ей может достаться, и `min(размер, доля)`
  /// совпадает с итогом раздачи по известному размеру. Выключенная
  /// подписка, которую разбирают (обновление выключенных, включение),
  /// считается вместе с включёнными.
  int _nodeBudgetQuotaFor(SubscriptionServers target) {
    final lists = <ServerList>[for (final e in _entries) e.list];
    if (!lists.any((l) => l.id == target.id)) lists.add(target);
    final quotas = nodeBudgetQuotas(
      budget: SettingsStorage.nodeBudget.value,
      sources: lists,
      includeId: target.id,
      sizeOf: (s) => s.id == target.id
          ? kNodeBudgetUnknownSize
          : subscriptionBudgetSize(s),
    );
    return quotas[target.id] ?? 0;
  }

  /// Узлы подписки со ссылками (Направления, цепочки, правила, detour
  /// источников и членов папок). Ошибка
  /// чтения хранилища — без защищённых: обрезка тогда идёт по порядку.
  Future<SourceProtectedTags> _protectedNodeTagsFor(
      SubscriptionServers s) async {
    try {
      final all = collectProtectedNodeTags(
        directions: await SettingsStorage.getDirections(),
        chains: await SettingsStorage.getChains(),
        rules: await SettingsStorage.getCustomRules(),
        sources: [for (final e in _entries) e.list],
      );
      return all.forSource(s);
    } catch (e) {
      AppLog.I.warning(
          'Node budget: references not read ($e)');
      return ProtectedNodeTags.empty.forSource(s);
    }
  }

  /// Вход обрезки для разбора подписки [s]: доля и защищённые узлы.
  Future<({int quota, SourceProtectedTags protected})> _nodeBudgetInputFor(
      SubscriptionServers s) async {
    final protected = await _protectedNodeTagsFor(s);
    return (quota: _nodeBudgetQuotaFor(s), protected: protected);
  }

  /// Пересчёт долей после любой записи источников и при смене бюджета.
  /// Проход один на раз; запрос во время прохода повторяет его в конце.
  void _scheduleNodeBudgetRebalance() {
    if (stale) return;
    if (_budgetRebalancing) {
      _budgetRebalanceAgain = true;
      return;
    }
    _budgetRebalancing = true;
    lastNodeBudgetRebalanceForTesting = Future<void>(() async {
      try {
        do {
          _budgetRebalanceAgain = false;
          await _rebalanceNodeBudget();
        } while (_budgetRebalanceAgain && !stale);
      } catch (e) {
        AppLog.I.warning(
            'Node budget: rebalance failed ($e)');
      } finally {
        _budgetRebalancing = false;
      }
    });
  }

  /// Доли всех включённых подписок по известным размерам; подписка, чей
  /// итог `min(размер, доля)` сменился, перерезается из кэша тела.
  /// Неразобранные (узлов нет, доли не было) пропускаются — долю им даст
  /// разбор.
  Future<void> _rebalanceNodeBudget() async {
    if (stale) return;
    final lists = <ServerList>[for (final e in _entries) e.list];
    final quotas = nodeBudgetQuotas(
      budget: SettingsStorage.nodeBudget.value,
      sources: lists,
    );
    final subs = [
      for (final e in _entries)
        if (quotas.containsKey(e.id)) e,
    ];
    for (var i = 0; i < subs.length; i++) {
      if (stale) return;
      final e = subs[i];
      final l = e.list;
      if (l is! SubscriptionServers || !_entries.contains(e)) continue;
      final applied = e._budgetQuota;
      if (applied == null && l.nodes.isEmpty) continue;
      final quota = quotas[l.id] ?? 0;
      final size = subscriptionBudgetSize(l);
      final before = min(size, applied ?? kNodeBudgetUnknownSize);
      final after = min(size, quota);
      if (before == after) {
        e._budgetQuota = quota;
        continue;
      }
      await _recutFromCache(e, l, quota);
    }
  }

  /// Перерезка подписки до [quota] разбором кэша тела (без сети).
  Future<void> _recutFromCache(
      SubscriptionEntry entry, SubscriptionServers list, int quota) async {
    final shortUrl = maskSubscriptionUrl(list.url);
    final body = await HttpCache.loadBody(list.url);
    if (stale || body == null || body.isEmpty) return;
    final protected = await _protectedNodeTagsFor(list);
    final parsed = await _parseCachedBody(
        CacheParseInput(
          body: body,
          rules: list.activeImportRules,
          disabledHashes: list.disabledHashes,
          nodeWarnings: list.nodeWarnings,
          quota: quota,
          protected: protected,
        ),
        shortUrl);
    if (stale || !_entries.contains(entry)) return;
    final cur = entry.list;
    // Запись сменилась, пока шёл разбор: перерезку сделает следующий проход
    // (его запросит запись, сменившая её).
    if (cur is! SubscriptionServers ||
        cur.url != list.url ||
        !identical(cur.disabledHashes, list.disabledHashes) ||
        !identical(cur.nodeWarnings, list.nodeWarnings) ||
        !identical(cur.importRules, list.importRules) ||
        cur.importRulesEnabled != list.importRulesEnabled) {
      _budgetRebalanceAgain = true;
      return;
    }
    if (parsed.totalNodeCount == 0) return;
    final nodes = parsed.nodes;
    entry._replaceList(cur.copyWith(
      nodes: nodes,
      lastNodeCount: nodes.length,
      totalNodeCount: parsed.totalNodeCount,
      disabledHashes: parsed.migrated ?? cur.disabledHashes,
    ));
    entry._budgetQuota = quota;
    entry.nodeCount = nodes.length;
    final detours = nodes.where((n) => n.chained != null).length;
    entry.status = SubStatusNodes(nodes.length, detours: detours);
    AppLog.I.info('Node budget: $shortUrl keeps ${nodes.length} of '
        '${parsed.totalNodeCount} nodes');
    await _persist();
    notifyListeners();
  }
}
