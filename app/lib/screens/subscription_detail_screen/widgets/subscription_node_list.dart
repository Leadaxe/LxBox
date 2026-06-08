import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
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
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(error!, style: TextStyle(color: theme.colorScheme.error)),
        ),
      );
    }

    final nodes = this.nodes;
    if (nodes == null && !loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Update subscription to see nodes'),
        ),
      );
    }

    if (nodes == null || nodes.isEmpty) {
      if (loading) return const SizedBox.shrink();
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No nodes found'),
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
                    '$actionableCount node${actionableCount == 1 ? "" : "s"} with warnings (XHTTP fallback etc.)',
                    style: const TextStyle(fontSize: 12, color: Colors.orange),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12),
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
              title: const Text('Copy node info'),
              subtitle: Text(info, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
              onTap: () {
                Clipboard.setData(ClipboardData(text: info));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Node info copied')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: const Text('Copy tag'),
              subtitle: Text(node.tag, style: const TextStyle(fontSize: 11)),
              onTap: () {
                Clipboard.setData(ClipboardData(text: node.tag));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Tag copied')),
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
      _ => Icons.public,
    };
    return Icon(icon, size: 20);
  }
}
