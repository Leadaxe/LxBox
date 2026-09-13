import 'package:flutter/material.dart';

import '../../../services/dns/node_dns_records.dart';
import '../../../services/l10n/locale_controller.dart';
import 'dns_badge.dart';
import 'dns_mirror_group_card.dart';

/// §435 — read-only тайл DNS-сервера узла (секции, спека §9.2). Вид по
/// образцу [MergedServerTile]: title/subtitle `tag · type · адрес`, плашка
/// «Node» — но без свитча, тапа и меню: запись живёт в узле, правится в
/// редакторе узла. Подпись «from node <тег>» — display-тег после
/// подстановки `@self`. Выключенный узел/запись — приглушённая строка с
/// подсказкой (паритет с лаунчером): в конфиг не попадает, но видно, что
/// появится после включения.
class NodeDnsServerTile extends StatelessWidget {
  const NodeDnsServerTile({super.key, required this.record});

  final NodeDnsServerRecord record;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = record.server;
    final type = s.body['type']?.toString() ?? '';
    final addr = s.body['server']?.toString() ?? '';
    // У сервера `tailscale` вместо адреса — endpoint (тег узла tailnet).
    final endpoint = s.body['endpoint']?.toString() ?? '';
    final active = record.nodeEnabled && s.enabled;
    final subtitleLine = [
      s.tag,
      if (type.isNotEmpty) type,
      if (addr.isNotEmpty) addr,
      if (endpoint.isNotEmpty) endpoint,
    ].join(' · ');
    final description = s.description ?? '';

    return Card(
      child: ListTile(
        // Ширина как у Switch соседних тайлов — колонка заголовков ровная.
        leading: SizedBox(
          width: 40,
          child: Center(
            child: Icon(Icons.dns_outlined,
                size: 22, color: active ? cs.primary : cs.onSurfaceVariant),
          ),
        ),
        title: Text(
          description.isNotEmpty ? description : s.tag,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: active ? null : cs.onSurfaceVariant,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              subtitleLine,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            NodeSourceLine(
              nodeTag: record.nodeTag,
              nodeEnabled: record.nodeEnabled,
              recordEnabled: s.enabled,
            ),
          ],
        ),
        trailing: DnsBadge(getLocalText.s("Node"), cs.tertiary),
      ),
    );
  }
}

/// §435 — строка-источник «from node <тег>» + подсказки о выключенном узле /
/// записи. Общая для тайла сервера и подписи правила.
class NodeSourceLine extends StatelessWidget {
  const NodeSourceLine({
    super.key,
    required this.nodeTag,
    required this.nodeEnabled,
    required this.recordEnabled,
  });

  final String nodeTag;
  final bool nodeEnabled;
  final bool recordEnabled;

  /// Текст подписи без виджета — для `note` в [DnsMirrorTile].
  static String text({
    required String nodeTag,
    required bool nodeEnabled,
    required bool recordEnabled,
  }) =>
      [
        getLocalText.s("from node %s", nodeTag),
        if (!nodeEnabled) getLocalText.s("node is disabled"),
        if (!recordEnabled) getLocalText.s("disabled"),
      ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = !nodeEnabled || !recordEnabled;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.hub_outlined,
          size: 12,
          color: muted ? cs.onSurfaceVariant : cs.tertiary,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text(
              nodeTag: nodeTag,
              nodeEnabled: nodeEnabled,
              recordEnabled: recordEnabled,
            ),
            style: TextStyle(
              fontSize: 11,
              color: muted ? cs.onSurfaceVariant : cs.tertiary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// §435 — карточка DNS-правил узлов внизу списка DNS Rules (спека §9.2).
/// По образцу [DnsMirrorGroupCard]: заголовок «From nodes», строки —
/// [DnsMirrorTile] с `sourceKind: 'node'` без свитча (`onToggle: null`),
/// превью тела после подстановки, `note` — тег узла. Карточка стоит ПОСЛЕ
/// `ReorderableListView` и в reorder не участвует: при сборке секции узлов
/// инжектятся в конец `dns.rules` (спека §4 п. 3), порядок здесь и есть
/// порядок эмиссии.
class NodeDnsRulesCard extends StatelessWidget {
  const NodeDnsRulesCard({super.key, required this.records});

  final List<NodeDnsRuleRecord> records;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Icon(Icons.hub_outlined, size: 14, color: cs.tertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    getLocalText.s("From nodes · read-only, edited in the node"),
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          for (var i = 0; i < records.length; i++)
            DnsMirrorTile(
              key: ValueKey('dns-rule-node-$i-${records[i].nodeTag}'),
              title: records[i].rule.name.isNotEmpty
                  ? records[i].rule.name
                  : records[i].nodeTag,
              previewBodies: [records[i].rule.rule],
              sourceKind: 'node',
              enabled: records[i].nodeEnabled && records[i].rule.enabled,
              onToggle: null,
              note: NodeSourceLine.text(
                nodeTag: records[i].nodeTag,
                nodeEnabled: records[i].nodeEnabled,
                recordEnabled: records[i].rule.enabled,
              ),
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
