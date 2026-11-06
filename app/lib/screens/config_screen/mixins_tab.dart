import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/home_controller.dart';
import '../../controllers/subscription_controller.dart';
import '../../models/mixin.dart';
import '../../models/validation.dart';
import '../../services/l10n/locale_controller.dart';
import '../../services/settings_storage.dart';
import '../../services/ui_helpers.dart';
import '../../widgets/reorder_grab_strip.dart';
import '../mixin_edit_screen.dart';
import '../routing_screen/routing_screen_menus.dart';

/// §704 §5 — вкладка Mixins экрана Config: список миксинов в порядке
/// применения. Тумблер, порядок, удаление, Duplicate и Save формы пишут
/// список сразу (`SettingsStorage.setMixins`) и пересобирают конфиг; отказ
/// миксина последней сборки — строкой `⚠` под ним (`MixinIssue` по `mixinId`).
class ConfigMixinsTab extends StatefulWidget {
  const ConfigMixinsTab({
    super.key,
    required this.homeController,
    this.subController,
    this.onConfigRebuilt,
  });

  final HomeController homeController;

  /// `null` — пересборки нет (запись поднимает dirty, конфиг соберёт
  /// воронка главного экрана), подсказок и предпросмотра в форме тоже.
  final SubscriptionController? subController;

  /// Пересборка после правки миксинов сохранила новый конфиг.
  final VoidCallback? onConfigRebuilt;

  @override
  State<ConfigMixinsTab> createState() => _ConfigMixinsTabState();
}

class _ConfigMixinsTabState extends State<ConfigMixinsTab> {
  List<Mixin> _mixins = const [];
  bool _loading = true;

  /// Пересборка в полёте; правка за это время — флаг повтора, без
  /// параллельных `generateConfig`.
  Future<void>? _rebuild;
  bool _rebuildAgain = false;

  /// Сборка базы предпросмотра при входе на вкладку; `null` — не идёт.
  Future<void>? _baseBuild;

  @override
  void initState() {
    super.initState();
    widget.subController?.addListener(_onSubChanged);
    unawaited(_load());
    _ensureBase();
  }

  /// Базы предпросмотра нет (процесс перезапущен, сборки в нём не было) —
  /// собрать конфиг в память: без сохранения и без применения. Правка во
  /// время сборки встаёт повтором, как у [_requestRebuild].
  void _ensureBase() {
    final sub = widget.subController;
    if (sub == null || sub.lastConfigBeforeMixins != null) return;
    final build = sub.generateConfig().then<void>((_) {}, onError: (_) {});
    _baseBuild = build;
    _rebuild = build.whenComplete(() {
      _rebuild = null;
      _baseBuild = null;
      if (_rebuildAgain) _requestRebuild();
    });
    unawaited(_rebuild);
  }

  @override
  void dispose() {
    widget.subController?.removeListener(_onSubChanged);
    super.dispose();
  }

  void _onSubChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final list = await SettingsStorage.getMixins();
    if (!mounted) return;
    setState(() {
      _mixins = list;
      _loading = false;
    });
  }

  /// Записать список и пересобрать конфиг.
  Future<void> _persist(List<Mixin> next) async {
    setState(() => _mixins = next);
    await SettingsStorage.setMixins(next);
    _requestRebuild();
  }

  void _requestRebuild() {
    if (widget.subController == null) return;
    if (_rebuild != null) {
      _rebuildAgain = true;
      return;
    }
    _rebuild = () async {
      do {
        _rebuildAgain = false;
        await _rebuildOnce();
      } while (_rebuildAgain);
    }().whenComplete(() => _rebuild = null);
    unawaited(_rebuild);
  }

  /// Общий путь сохранения сущности: сборка, сохранение конфига, гейт
  /// автоприменения §667.
  Future<void> _rebuildOnce() async {
    final sub = widget.subController!;
    final home = widget.homeController;
    final config = await sub.generateConfig();
    if (config == null) return;
    await home.saveParsedConfig(config);
    widget.onConfigRebuilt?.call();
    await home.applyIfAutoReload();
  }

  MixinIssue? _issueOf(Mixin m) {
    final issues = widget.subController?.lastFatalIssues ?? const [];
    for (final i in issues.whereType<MixinIssue>()) {
      if (i.mixinId == m.id) return i;
    }
    return null;
  }

  void _onReorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _mixins.length) return;
    // `onReorderItem`: newIndex уже приведён к списку без перетаскиваемого.
    final next = [..._mixins];
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex.clamp(0, next.length), moved);
    unawaited(_persist(next));
  }

  void _toggle(int index, bool enabled) {
    final next = [..._mixins];
    next[index] = next[index].copyWith(enabled: enabled);
    unawaited(_persist(next));
  }

  Future<void> _open({Mixin? initial}) async {
    final saved = await Navigator.of(context).push<Mixin>(
      MaterialPageRoute(
        builder: (_) => MixinEditScreen(
          initial: initial,
          mixins: _mixins,
          subController: widget.subController,
          baseBuild: _baseBuild,
        ),
      ),
    );
    if (saved == null || !mounted) return;
    // Список мог смениться за время формы (Debug API) — перечитать.
    final current = [...await SettingsStorage.getMixins()];
    if (!mounted) return;
    final i = current.indexWhere((m) => m.id == saved.id);
    if (i >= 0) {
      current[i] = saved;
    } else {
      current.add(saved);
    }
    await _persist(current);
  }

  Future<void> _showContextMenu(int index, Offset pos) async {
    if (index < 0 || index >= _mixins.length) return;
    final m = _mixins[index];
    final action = await showRuleContextMenu(context, pos, showDuplicate: true);
    if (!mounted) return;
    switch (action) {
      case 'duplicate':
        final next = [..._mixins];
        final i = next.indexWhere((x) => x.id == m.id);
        if (i < 0) return;
        next.insert(i + 1, Mixin.fromJson(m.toBackupJson()));
        unawaited(_persist(next));
      case 'delete':
        final ok = await showDeleteConfirmDialog(
          context,
          title: getLocalText.s("Delete mixin?"),
          message: m.displayName,
        );
        if (ok != true || !mounted) return;
        unawaited(
          _persist([
            for (final x in _mixins)
              if (x.id != m.id) x,
          ]),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bottomPad = MediaQuery.of(context).padding.bottom + 88;
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        tooltip: getLocalText.s("Add mixin"),
        onPressed: () => unawaited(_open()),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.only(top: 12, bottom: bottomPad),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    getLocalText.s(
                      "Edits applied to the built config, top to bottom. They survive rebuilds.",
                    ),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
                const SizedBox(height: 8),
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: _mixins.length,
                  onReorderItem: _onReorder,
                  itemBuilder: (ctx, i) => KeyedSubtree(
                    key: ValueKey('mixin-${_mixins[i].id}'),
                    child: _MixinTile(
                      index: i,
                      mixin: _mixins[i],
                      issue: _issueOf(_mixins[i]),
                      onTap: () => unawaited(_open(initial: _mixins[i])),
                      onLongPressStart: (pos) =>
                          unawaited(_showContextMenu(i, pos)),
                      onToggle: (v) => _toggle(i, v),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// Строка миксина: ручка, имя, `target → op` вторичным текстом, тумблер
/// справа; `⚠` с причиной отказа последней сборки.
class _MixinTile extends StatelessWidget {
  const _MixinTile({
    required this.index,
    required this.mixin,
    required this.issue,
    required this.onTap,
    required this.onLongPressStart,
    required this.onToggle,
  });

  final int index;
  final Mixin mixin;
  final MixinIssue? issue;
  final VoidCallback onTap;
  final ValueChanged<Offset> onLongPressStart;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = mixin.enabled;
    final subtitleColor = active ? cs.primary : cs.onSurfaceVariant;
    final summary = '${mixin.target} → ${mixin.op}';
    final warning = issue;
    final content = GestureDetector(
      onTap: onTap,
      onLongPressStart: (d) => onLongPressStart(d.globalPosition),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 6, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mixin.displayName,
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      color: active ? null : cs.onSurfaceVariant,
                    ),
                  ),
                  if (mixin.name.isNotEmpty)
                    Text(
                      summary,
                      style: TextStyle(
                        fontSize: 12,
                        color: subtitleColor,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (warning != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '⚠ ${warning.detail}',
                        style: TextStyle(fontSize: 12, color: cs.error),
                      ),
                    ),
                ],
              ),
            ),
            Switch(value: mixin.enabled, onChanged: onToggle),
          ],
        ),
      ),
    );
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReorderGrabStrip(index: index),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [content, const Divider(height: 1)],
            ),
          ),
        ],
      ),
    );
  }
}
