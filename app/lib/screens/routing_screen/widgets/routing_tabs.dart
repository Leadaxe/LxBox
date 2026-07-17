import 'package:flutter/material.dart';

import '../../../services/l10n/l10n.dart';

/// Таб "Channels": proxy-groups + default-fallback + Auto tuning. Все тайлы
/// собираются в экране и приходят сюда готовыми списками — поведение
/// идентично исходному inline-ListView.
class RoutingChannelsTab extends StatelessWidget {
  const RoutingChannelsTab({
    super.key,
    required this.bottomPad,
    required this.groupTiles,
    required this.channelCount,
    required this.maxChannels,
    required this.onAddChannel,
    required this.routeFinalTile,
  });

  final double bottomPad;
  final List<Widget> groupTiles;
  final int channelCount;
  final int maxChannels;

  /// null = лимит достигнут (Add disabled).
  final VoidCallback? onAddChannel;

  final Widget routeFinalTile;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPad),
      children: [
        Text(
          context.l.routingChannelsIntro,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 8),
        ...groupTiles,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: TextButton.icon(
            onPressed: onAddChannel,
            icon: const Icon(Icons.add, size: 18),
            label: Text(context.l.routingAddChannel(channelCount, maxChannels)),
          ),
        ),
        const Divider(height: 24),
        routeFinalTile,
      ],
    );
  }
}

/// Таб "Presets": каталог готовых правил.
class RoutingPresetsTab extends StatelessWidget {
  const RoutingPresetsTab({
    super.key,
    required this.bottomPad,
    required this.catalogTiles,
  });

  final double bottomPad;
  final List<Widget> catalogTiles;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPad),
      children: [
        Text(
          context.l.routingPresetsIntro,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 8),
        ...catalogTiles,
      ],
    );
  }
}

/// Таб "Rules": unified custom routing (spec §030).
///
/// NB: ListView с горизонтальными paddings'ами 0 — чтобы тайлы растягивались
/// edge-to-edge. Интро и Add-button сами дают себе 12px через Padding.
class RoutingRulesTab extends StatelessWidget {
  const RoutingRulesTab({
    super.key,
    required this.bottomPad,
    required this.itemCount,
    required this.onReorder,
    required this.itemKey,
    required this.itemBuilder,
    required this.onAdd,
  });

  final double bottomPad;
  final int itemCount;
  final ReorderCallback onReorder;
  final Key Function(int index) itemKey;
  final Widget Function(int index) itemBuilder;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.only(top: 12, bottom: bottomPad),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            context.l.routingRulesIntro,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
        const SizedBox(height: 8),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: itemCount,
          onReorder: onReorder,
          itemBuilder: (ctx, i) => KeyedSubtree(
            key: itemKey(i),
            child: itemBuilder(i),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: Text(context.l.routingAddRule),
          ),
        ),
      ],
    );
  }
}
