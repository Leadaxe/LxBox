import 'package:flutter/material.dart';

/// Таб "Channels": proxy-groups + default-fallback + Auto tuning. Все тайлы
/// собираются в экране и приходят сюда готовыми списками — поведение
/// идентично исходному inline-ListView.
class RoutingChannelsTab extends StatelessWidget {
  const RoutingChannelsTab({
    super.key,
    required this.bottomPad,
    required this.groupTiles,
    required this.routeFinalTile,
    required this.varSections,
  });

  final double bottomPad;
  final List<Widget> groupTiles;
  final Widget routeFinalTile;
  final List<Widget> varSections;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPad),
      children: [
        Text(
          'Enabled groups appear in the selector on the home screen.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 8),
        ...groupTiles,
        const Divider(height: 24),
        routeFinalTile,
        ...varSections,
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
          'Ready-made rules you can copy into Rules, then edit freely.',
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
            'Route or block by app / domain / IP / port / protocol, or remote .srs rule-set.',
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
            label: const Text('Add rule'),
          ),
        ),
      ],
    );
  }
}
