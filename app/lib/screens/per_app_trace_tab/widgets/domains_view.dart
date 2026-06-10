import 'package:flutter/material.dart';

import '../../../services/traffic_profiler.dart';
import '../../../services/format_utils.dart';
import 'empty_view.dart';
import 'ip_chip.dart';

/// Domains tab — aggregated unique domains with CNAME chain & IPs.
///
/// Stateful, потому что:
/// - Search field (matches domain || ip || cname target) — folded роль
///   ушедшей IPs tab'ы. Юзер вбивает IP → видит все домены, что резолвились
///   на него (cross-domain CDN-аудит).
/// - Auto-expand при focus-навигации из Connections («View in Domains →»)
///   через `widget.focusDomain` + `widget.onFocusConsumed`.
class DomainsView extends StatefulWidget {
  const DomainsView({
    super.key,
    required this.session,
    required this.onViewInDomains,
    this.focusDomain,
    this.onFocusConsumed,
  });
  final Session? session;
  final ValueChanged<String> onViewInDomains;
  final String? focusDomain;
  final VoidCallback? onFocusConsumed;

  @override
  State<DomainsView> createState() => _DomainsViewState();
}

class _DomainsViewState extends State<DomainsView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _search = '';
  // Domain'ы которые юзер «expand'нул» (в т.ч. через focus-jump). PageStorageKey
  // не используем потому что ExpansionTile state живёт внутри tile'а — нам надо
  // программно открывать.
  final Set<String> _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    _applyFocusIfAny(initial: true);
  }

  @override
  void didUpdateWidget(DomainsView old) {
    super.didUpdateWidget(old);
    if (widget.focusDomain != null &&
        widget.focusDomain != old.focusDomain) {
      _applyFocusIfAny();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _applyFocusIfAny({bool initial = false}) {
    final focus = widget.focusDomain;
    if (focus == null) return;
    _searchCtrl.text = focus;
    _search = focus;
    _expanded.add(focus);
    if (!initial) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onFocusConsumed?.call();
        if (mounted) setState(() {});
      });
    } else {
      // initState path — onFocusConsumed зовём после первого build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onFocusConsumed?.call();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    if (s == null) {
      return const EmptyView(text: 'Start recording to see domains.');
    }
    final all = s.byDomain.values.toList()
      ..sort((a, b) =>
          (b.upBytes + b.downBytes).compareTo(a.upBytes + a.downBytes));
    final filtered = _search.isEmpty
        ? all
        : all.where((d) => _matchesSearch(d, _search)).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search domain or IP…',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _search.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _search = '');
                      },
                    ),
              isDense: true,
              border: const OutlineInputBorder(),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            style: const TextStyle(fontSize: 13),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        Expanded(
          child: all.isEmpty
              ? const EmptyView(text: 'No domains yet.')
              : (filtered.isEmpty
                  ? const EmptyView(text: 'No matches.')
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) => _row(context, filtered[i]),
                    )),
        ),
      ],
    );
  }

  static bool _matchesSearch(DomainStats d, String q) {
    final lq = q.toLowerCase();
    if (d.domain.toLowerCase().contains(lq)) return true;
    if (d.ips.any((ip) => ip.contains(q))) return true;
    if (d.cnameTargets.any((c) => c.toLowerCase().contains(lq))) return true;
    return false;
  }

  Widget _row(BuildContext context, DomainStats d) {
    final cs = Theme.of(context).colorScheme;
    return ExpansionTile(
      // PageStorageKey стабильно идентифицирует tile в списке — иначе
      // expand-state теряется при rebuild'ах от ChangeNotifier'а.
      key: PageStorageKey<String>('domain:${d.domain}'),
      initiallyExpanded: _expanded.contains(d.domain),
      onExpansionChanged: (open) {
        if (open) {
          _expanded.add(d.domain);
        } else {
          _expanded.remove(d.domain);
        }
      },
      title: Text(d.domain,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
      subtitle: Row(
        children: [
          Text('${d.connections} conns',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          const SizedBox(width: 8),
          Text('↑${formatBytes(d.upBytes)} ↓${formatBytes(d.downBytes)}',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          if (d.issues.isNotEmpty) ...[
            const SizedBox(width: 6),
            Icon(Icons.warning_amber, size: 12, color: cs.error),
          ],
        ],
      ),
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      childrenPadding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
      children: [
        if (d.cnameTargets.isNotEmpty)
          _kv(cs, 'CNAME', d.cnameTargets.join(' → ')),
        if (d.ips.isNotEmpty) _kvIps(context, cs, 'IPs', d.ips),
        if (d.outbounds.isNotEmpty)
          _kv(cs, 'Outbound', d.outbounds.join(' / ')),
        if (d.firstSeen != null)
          _kv(cs, 'First', formatTime(d.firstSeen!)),
        if (d.lastSeen != null) _kv(cs, 'Last', formatTime(d.lastSeen!)),
        for (final a in d.issues)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Icon(Icons.warning_amber, size: 12, color: cs.error),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(a.description,
                      style: TextStyle(fontSize: 11, color: cs.error)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// IP-вариант [_kv]: вместо строки рендерит [ipChipList] — каждый IP
  /// со своей ↗-иконкой перехода на Domains tab. В Domains tab
  /// `onViewInDomains` обновит search-фильтр на этот IP, что эквивалентно
  /// «refocus»: видны все домены резолвящиеся на него (cross-domain CDN).
  Widget _kvIps(BuildContext context, ColorScheme cs, String k,
          Iterable<String> ips) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 70,
              child: Text(k,
                  style:
                      TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ),
            Expanded(
              child: ipChipList(context, ips, widget.onViewInDomains),
            ),
          ],
        ),
      );

  Widget _kv(ColorScheme cs, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 70,
                child: Text(k,
                    style: TextStyle(
                        fontSize: 11, color: cs.onSurfaceVariant))),
            Expanded(
              child: Text(v,
                  style: const TextStyle(
                      fontSize: 11, fontFamily: 'monospace')),
            ),
          ],
        ),
      );
}
