import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
import '../../../models/ui_msg.dart';
import '../../../services/l10n/l10n.dart';
import 'node_warning_row.dart';

/// Nodes-tab list: actionable-warning banner + node rows with protocol icon,
/// label/tag, server:port, inline warning and a long-press copy menu.
/// Extracted verbatim from `_buildNodeList` / `_protocolIcon` / `_showNodeMenu`.
class SubscriptionNodeList extends StatelessWidget {
  const SubscriptionNodeList({
    super.key,
    required this.nodes,
    required this.loading,
    required this.error,
  });

  final List<NodeSpec>? nodes;
  final bool loading;
  final UiMsg? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(error!.render(context.l),
              style: TextStyle(color: theme.colorScheme.error)),
        ),
      );
    }

    final nodes = this.nodes;
    if (nodes == null && !loading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(context.l.subUpdateToSeeNodes),
        ),
      );
    }

    if (nodes == null || nodes.isEmpty) {
      if (loading) return const SizedBox.shrink();
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(context.l.subNoNodesFound),
        ),
      );
    }

    // Считаем только actionable (warning/error). Info (TLS-insecure) тут
    // не учитываем — это часто намеренный выбор провайдера, чтобы не пугать.
    final actionableCount = nodes
        .where((n) => n.warnings
            .any((w) => w.severity != WarningSeverity.info))
        .length;
    return Column(
      children: [
        if (actionableCount > 0)
          Container(
            width: double.infinity,
            color: Colors.orange.withValues(alpha: 0.15),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.warning_amber, size: 16, color: Colors.orange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l.subNodesWithWarnings(actionableCount),
                    style: const TextStyle(fontSize: 12, color: Colors.orange),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.separated(
      // Bottom safe-area: последняя нода не должна прятаться за системной
      // навигацией Android. Паттерн проекта — padding.bottom + 24.
      padding: EdgeInsets.fromLTRB(
          12, 0, 12, MediaQuery.of(context).padding.bottom + 24),
      itemCount: nodes.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final node = nodes[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _protocolIcon(node.protocol),
          title: Text(
            node.label.isNotEmpty ? node.label : node.tag,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${node.protocol}  ${node.server}:${node.port}',
                style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
              ),
              if (node.warnings.isNotEmpty) NodeWarningRow(node.warnings),
            ],
          ),
          dense: true,
          onLongPress: () => _showNodeMenu(context, node),
        );
      },
          ),
        ),
      ],
    );
  }

  void _showNodeMenu(BuildContext context, NodeSpec node) {
    final info = node.rawUri.isNotEmpty
        ? node.rawUri
        : '${node.protocol}://${node.server}:${node.port}';
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(ctx.l.subCopyNodeInfo),
              subtitle: Text(info, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
              onTap: () {
                Clipboard.setData(ClipboardData(text: info));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.l.subNodeInfoCopied)),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: Text(ctx.l.subCopyTag),
              subtitle: Text(node.tag, style: const TextStyle(fontSize: 11)),
              onTap: () {
                Clipboard.setData(ClipboardData(text: node.tag));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.l.subTagCopied)),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _protocolIcon(String scheme) {
    final icon = switch (scheme) {
      'vless' => Icons.security,
      'vmess' => Icons.vpn_key,
      'trojan' => Icons.shield_outlined,
      'ss' => Icons.lock_outline,
      'hysteria2' || 'hy2' => Icons.speed,
      'wireguard' => Icons.lan_outlined,
      'masque' => Icons.cloud_outlined, // §130 — WARP-транспорт
      'anytls' => Icons.enhanced_encryption, // §269
      _ => Icons.public,
    };
    return Icon(icon, size: 20);
  }
}
