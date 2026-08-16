import 'package:flutter/material.dart';

import '../../../services/l10n/locale_controller.dart';

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
          getLocalText.s("Enabled channels appear in the selector on the home screen. Tap a channel to edit its nodes, filter and auto twin."),
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
            label: Text(getLocalText.s("Add channel  (%1\$d/%2\$d)", channelCount, maxChannels)),
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
          getLocalText.s("Ready-made rules you can copy into Rules, then edit freely."),
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
    required this.onExport,
    required this.onImport,
  });

  final double bottomPad;
  final int itemCount;
  final ReorderCallback onReorder;
  final Key Function(int index) itemKey;
  final Widget Function(int index) itemBuilder;
  final VoidCallback onAdd;

  /// §396 — экспорт/импорт правил файлом (меню ⋮ в шапке таба).
  final VoidCallback onExport;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.only(top: 12, bottom: bottomPad),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 12, right: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  // Центр строки текста ~на оси кнопки ⋮ (48px hit-target).
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    getLocalText.s("Route or block by app / domain / IP / port / protocol, or remote .srs rule-set."),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 20),
                tooltip: getLocalText.s("Rules menu"),
                onSelected: (v) {
                  if (v == 'export') onExport();
                  if (v == 'import') onImport();
                },
                itemBuilder: (_) => [
                  PopupMenuItem<String>(
                    value: 'export',
                    // §396 — экспортировать нечего → пункт серый (не прячем:
                    // discoverability дороже).
                    enabled: itemCount > 0,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.upload_file_outlined, size: 20),
                      title: Text(getLocalText.s("Export rules...")),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'import',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading:
                          const Icon(Icons.file_open_outlined, size: 20),
                      title: Text(getLocalText.s("Import rules...")),
                    ),
                  ),
                ],
              ),
            ],
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
            label: Text(getLocalText.s("Add rule")),
          ),
        ),
      ],
    );
  }
}
