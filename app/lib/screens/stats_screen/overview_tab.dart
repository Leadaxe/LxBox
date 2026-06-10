import 'package:flutter/material.dart';

import '../../services/app_info_cache.dart';
import '../../services/clash_api_client.dart';
import '../../services/format_utils.dart';
import 'overview_models.dart';

/// Overview tab of StatsScreen; receives data via props on each parent refresh.
/// `_expanded` is local state of this widget.
class OverviewTab extends StatefulWidget {
  const OverviewTab({
    super.key,
    required this.loading,
    required this.groups,
    required this.totalUp,
    required this.totalDown,
    required this.totalConns,
    required this.memory,
    required this.byRule,
    required this.byApp,
    required this.detourChain,
  });

  final bool loading;
  final Map<String, OutboundGroup> groups;
  final int totalUp;
  final int totalDown;
  final int totalConns;
  final int memory;
  final Map<String, int> byRule;
  final Map<String, AppStat> byApp;
  final List<String> Function(String tag) detourChain;

  @override
  State<OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<OverviewTab> {
  final _expanded = <String>{};

  List<String> _detourChain(String tag) => widget.detourChain(tag);

  @override
  Widget build(BuildContext context) {
    final sorted = widget.groups.values.toList()
      ..sort((a, b) => (b.upload + b.download).compareTo(a.upload + a.download));
    if (widget.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _totalChip(context, 'Upload', formatBytes(widget.totalUp, spaced: true), Icons.arrow_upward, Theme.of(context).colorScheme.primary),
                _totalChip(context, 'Download', formatBytes(widget.totalDown, spaced: true), Icons.arrow_downward, Theme.of(context).colorScheme.tertiary),
                _totalChip(context, 'Connections', '${widget.totalConns}', Icons.link, Theme.of(context).colorScheme.secondary),
                _totalChip(context, 'sing-box', formatBytes(widget.memory, spaced: true), Icons.memory, Theme.of(context).colorScheme.secondary),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Traffic by Outbound', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (sorted.isEmpty)
          const Center(child: Text('No active connections'))
        else
          ...sorted.map(_buildOutboundCard),
        const SizedBox(height: 8),
        _buildByRuleCard(context),
        _buildTopAppsCard(context),
      ],
    );
  }

  Widget _totalChip(BuildContext context, String label, String value, IconData icon, Color color) {
    return Column(
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color),
        ),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }

  Widget _buildOutboundCard(OutboundGroup group) {
    final isExpanded = _expanded.contains(group.name);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            onTap: () => setState(() {
              if (isExpanded) {
                _expanded.remove(group.name);
              } else {
                _expanded.add(group.name);
              }
            }),
            title: Text(group.name, style: const TextStyle(fontWeight: FontWeight.w500)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < _detourChain(group.name).length; i++)
                  Padding(
                    padding: EdgeInsets.only(left: 8.0 + i * 12.0, top: 2),
                    child: Text(
                      '↳ via ${_detourChain(group.name)[i]}',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${group.connections.length} connections',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('↑ ${formatBytes(group.upload, spaced: true)}', style: const TextStyle(fontSize: 12)),
                    Text('↓ ${formatBytes(group.download, spaced: true)}', style: const TextStyle(fontSize: 12)),
                  ],
                ),
                const SizedBox(width: 4),
                Icon(
                  isExpanded ? Icons.expand_less : Icons.expand_more,
                  color: cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
          if (isExpanded) ...[
            const Divider(height: 1),
            ...group.connections.map((c) => _buildConnectionTile(c, cs)),
          ],
        ],
      ),
    );
  }

  Widget _buildConnectionTile(Connection c, ColorScheme cs) {
    final hostPort = c.destPort.isNotEmpty ? '${c.host}:${c.destPort}' : c.host;
    final duration = _formatDuration(c.start);
    final ruleText = c.rulePayload.isNotEmpty
        ? '${c.rule} (${c.rulePayload})'
        : c.rule;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                c.network == 'udp' ? Icons.swap_horiz : Icons.arrow_forward,
                size: 14,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  hostPort,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '↑${formatBytes(c.upload, spaced: true)} ↓${formatBytes(c.download, spaced: true)}',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 20, top: 2),
            child: Text(
              '${c.network.toUpperCase()} · $ruleText · $duration',
              style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
            ),
          ),
          if (c.process.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Text(
                c.process,
                style: TextStyle(fontSize: 10, color: cs.primary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (c.chains.length > 1)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Text(
                'Chain: ${c.chains.join(" → ")}',
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildByRuleCard(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entries = widget.byRule.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<int>(0, (s, e) => s + e.value);
    return Card(
      child: ExpansionTile(
        initiallyExpanded: true,
        title: Text('By routing rule', style: theme.textTheme.titleSmall),
        subtitle: Text('$total conns', style: const TextStyle(fontSize: 11)),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: entries.isEmpty
            ? [
                Text('No rule data',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))
              ]
            : [
                for (final e in entries)
                  _distributionRow(cs, e.key, e.value, total),
              ],
      ),
    );
  }

  Widget _buildTopAppsCard(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entries = widget.byApp.entries.toList()
      ..sort((a, b) => b.value.totalBytes.compareTo(a.value.totalBytes));
    final top = entries.take(10).toList();
    // Kick info fetch для каждого видимого pkg'а — сразу при build'е.
    for (final e in top) {
      AppInfoCache.ensure(e.key);
    }
    return Card(
      child: ExpansionTile(
        initiallyExpanded: true,
        title: Text('Top apps', style: theme.textTheme.titleSmall),
        subtitle: Text('${widget.byApp.length} total',
            style: const TextStyle(fontSize: 11)),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: top.isEmpty
            ? [
                Text('No app data',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))
              ]
            : [
                // Пере-билдим каждую строку когда в cache подъехали данные.
                AnimatedBuilder(
                  animation: AppInfoCache.revision,
                  builder: (_, _) => Column(
                    children: [for (final e in top) _appRow(cs, e.key, e.value)],
                  ),
                ),
              ],
      ),
    );
  }

  Widget _distributionRow(ColorScheme cs, String label, int count, int total) {
    final pct = total == 0 ? 0.0 : count / total;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6,
              backgroundColor: cs.surfaceContainerHighest,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 60,
            child: Text(
              '$count (${(pct * 100).toStringAsFixed(0)}%)',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _appRow(ColorScheme cs, String pkg, AppStat s) {
    final info = AppInfoCache.of(pkg);
    final displayName = info?.appName ?? pkg;
    final Widget leading;
    if (info?.icon != null) {
      leading = ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.memory(info!.icon!, width: 28, height: 28, gaplessPlayback: true),
      );
    } else {
      final letter = displayName.isNotEmpty
          ? displayName.characters.first.toUpperCase()
          : '?';
      leading = SizedBox(
        width: 28,
        height: 28,
        child: CircleAvatar(
          backgroundColor: cs.surfaceContainerHighest,
          child: Text(letter,
              style: TextStyle(fontSize: 12, color: cs.onSurface)),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          leading,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500),
                ),
                Text(
                  pkg,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${s.count} conns',
                  style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
              Text('↑ ${formatBytes(s.upload, spaced: true)}',
                  style: const TextStyle(fontSize: 10)),
              Text('↓ ${formatBytes(s.download, spaced: true)}',
                  style: const TextStyle(fontSize: 10)),
            ],
          ),
        ],
      ),
    );
  }

  // §084 H4 — ISO-string → compact duration. Парсит timestamp + delta от
  // now, форматирование делегирует format_utils. Спецфичен для stats
  // (другие экраны принимают готовый Duration).
  String _formatDuration(String startIso) {
    if (startIso.isEmpty) return '';
    try {
      final diff = DateTime.now().difference(DateTime.parse(startIso));
      return formatDuration(diff);
    } catch (_) {
      return '';
    }
  }
}
