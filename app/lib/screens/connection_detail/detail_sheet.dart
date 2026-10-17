import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/app_info_cache.dart';
import '../../services/format_utils.dart';
import '../../services/l10n/locale_controller.dart';
import '../../services/traffic_profiler.dart';
import '../../vpn/cc_channel.dart';
import '../../widgets/app_bottom_sheet.dart';
import '../stats_screen/routing_section.dart';
import 'detail_data.dart';

/// §662 — единая карточка соединения (бывш. §152 Conns + §160 профайлер).
///
/// Каркас (ручка, заголовок с иконкой приложения и бейджем протокола, футер
/// Copy JSON) и общие группы в одном порядке: App → Source → Destination →
/// (DNS) → Network → Routing → Traffic → Timing → (Issues) → ID. Свои секции
/// экраны передают слотами — общий код о них не знает:
/// - Conns: плашка One-way сверху, бейдж One-way, кнопка Close в футере;
/// - профайлер: строки Confidence/Matched via/Shown because в App, группа
///   DNS после Destination, Issues после Timing.
///
/// Строки Host / Address / App при [onSearchKey] кладут значение в поиск
/// экрана и закрывают карточку, без него копируют (в Conns поиска нет).
/// Остальные строки копируют. Пустые строки и группы скрыты.

/// Карточка соединения из Conns (`CcConnection`, снимок на момент тапа).
/// [onClose] — закрыть соединение через CommandClient.
Future<void> showConnectionDetailSheet(
  BuildContext context,
  CcConnection conn, {
  required bool closed,
  bool oneWay = false,
  required void Function(String id) onClose,
}) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => ConnectionDetailSheet(
      data: ConnectionDetailData.fromConnection(conn, closed: closed),
      onClose: onClose,
      headerBadge: oneWay ? const _OneWayBadge() : null,
      topBanner: oneWay ? _OneWayBanner(conn: conn) : null,
    ),
  );
}

/// Карточка события ленты профайлера (`TrafficEvent`, исторический снимок).
Future<void> showTrafficEventDetailSheet(
  BuildContext context,
  TrafficEvent event, {
  required void Function(String key) onSearchKey,
}) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => ConnectionDetailSheet(
      data: ConnectionDetailData.fromEvent(event),
      onSearchKey: onSearchKey,
      appExtraRows: (ctx) => [
        _confidenceRow(ctx, event),
        detailRow(ctx, 'Matched via', event.matchedVia ?? ''),
        detailRow(ctx, 'Shown because', event.shownBecause ?? ''),
      ],
      afterDestination: (ctx) => _dnsGroup(ctx, event),
      afterTiming: (ctx) => event.issues.isEmpty
          ? const []
          : detailGroup(ctx, 'Issues', [
              for (final a in event.issues) _issueRow(ctx, a),
            ]),
    ),
  );
}

typedef DetailSlot = List<Widget?> Function(BuildContext context);

class ConnectionDetailSheet extends StatelessWidget {
  const ConnectionDetailSheet({
    super.key,
    required this.data,
    this.onSearchKey,
    this.onClose,
    this.headerBadge,
    this.topBanner,
    this.appExtraRows,
    this.afterDestination,
    this.afterTiming,
  });

  final ConnectionDetailData data;
  final void Function(String key)? onSearchKey;

  /// Есть → в футере кнопка Close (доступна, если соединение живое и есть id).
  final void Function(String id)? onClose;

  final Widget? headerBadge;
  final Widget? topBanner;

  /// Строки в конце группы App.
  final DetailSlot? appExtraRows;

  /// Готовые группы (через [detailGroup]) после Destination / после Timing.
  final DetailSlot? afterDestination;
  final DetailSlot? afterTiming;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = data.title.isNotEmpty
        ? data.title
        : (data.origin == DetailOrigin.event
              ? getLocalText.s("(event)")
              : getLocalText.s("(connection)"));

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) => Column(
        children: [
          // Grabber
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                _AppIcon(pkg: data.package, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                    softWrap: true,
                  ),
                ),
                if (headerBadge != null) ...[
                  headerBadge!,
                  const SizedBox(width: 6),
                ],
                if (data.badgeLabel.isNotEmpty) _protocolBadge(context),
                // Точка в `TCP·` — наше обозначение закрытого (лента
                // профайлера); в карточке рядом словами, чтобы его выучили.
                if (data.closed && data.badgeLabel.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    '${data.badgeLabel.replaceAll('·', '')} '
                    '${getLocalText.s("closed")}',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                ?topBanner,
                ..._sections(context),
              ],
            ),
          ),
          _footer(context),
        ],
      ),
    );
  }

  List<Widget> _sections(BuildContext context) {
    final d = data;
    final out = <Widget>[];

    // App (§044): иконка + имя + package; путь процесса, если отличается.
    out.addAll(
      detailGroup(context, 'App', [
        _appRow(context, d.package),
        detailRow(context, 'Process', d.processPath),
        ...?appExtraRows?.call(context),
      ]),
    );

    // Source (§661): откуда и через какой вход.
    out.addAll(
      detailGroup(context, 'Source', [
        detailRow(context, 'Source', d.source),
        detailRow(context, 'Inbound', d.inbound),
        detailRow(context, 'Inbound type', d.inboundType),
      ]),
    );

    out.addAll(
      detailGroup(context, 'Destination', [
        _searchableRow(context, 'Host', d.host),
        _searchableRow(context, 'Address', d.address),
        detailRow(context, 'Port', d.port),
      ]),
    );

    out.addAll(
      (afterDestination?.call(context) ?? const []).whereType<Widget>(),
    );

    out.addAll(
      detailGroup(context, 'Network', [
        detailRow(context, 'Network', d.network),
        detailRow(context, 'Protocol', d.protocol),
        detailRow(context, 'Kind', d.kind),
      ]),
    );

    // Routing (§204) — общий набор строк.
    out.addAll(
      detailGroup(
        context,
        'Routing',
        routingRows(
          route: d.route,
          rule: d.rule,
          chain: d.chain,
          detour: d.detour,
          outbound: d.outbound,
          outboundType: d.outboundType,
        ).map((r) => detailRow(context, r.label, r.value)).toList(),
      ),
    );

    if (d.upBytes != null || d.downBytes != null) {
      final up = d.upBytes ?? 0;
      final down = d.downBytes ?? 0;
      out.addAll(
        detailGroup(context, 'Traffic', [
          detailRow(context, 'Upload', '${formatBytes(up)} ($up B)'),
          detailRow(context, 'Download', '${formatBytes(down)} ($down B)'),
        ]),
      );
    }

    out.addAll(
      detailGroup(context, 'Timing', [
        detailRow(
          context,
          'Started',
          d.started != null ? formatDateTime(d.started!.toLocal()) : '',
        ),
        detailRow(
          context,
          'Duration',
          d.duration != null
              ? formatDuration(d.duration!, daysRollup: true)
              : '',
        ),
      ]),
    );

    out.addAll((afterTiming?.call(context) ?? const []).whereType<Widget>());

    out.addAll(detailGroup(context, 'ID', [detailRow(context, 'ID', d.id)]));

    return out;
  }

  Widget _protocolBadge(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = switch (data.badgeTone) {
      DetailBadgeTone.primary => cs.primary,
      DetailBadgeTone.secondary => cs.secondary,
      DetailBadgeTone.tertiary => cs.tertiary,
      DetailBadgeTone.error => cs.error,
      DetailBadgeTone.outline => cs.outline,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        data.badgeLabel,
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  /// Host / Address: поиск, если экран его даёт, иначе копирование.
  Widget? _searchableRow(BuildContext context, String label, String value) {
    final v = value.trim();
    if (v.isEmpty) return null;
    final search = onSearchKey;
    if (search == null) return detailRow(context, label, v);
    final cs = Theme.of(context).colorScheme;
    return detailRow(
      context,
      label,
      v,
      valueColor: cs.primary,
      trailing: Icon(Icons.search, size: 14, color: cs.primary),
      onTap: () {
        Navigator.of(context).pop();
        search(v);
      },
    );
  }

  /// §044 — иконка + имя приложения (AppInfoCache) + package мелким. Тап —
  /// поиск по package, без поиска — копирует package.
  Widget? _appRow(BuildContext context, String pkg) {
    if (pkg.isEmpty) return null;
    final cs = Theme.of(context).colorScheme;
    final search = onSearchKey;
    AppInfoCache.ensure(pkg);
    return InkWell(
      onTap: search != null
          ? () {
              Navigator.of(context).pop();
              search(pkg);
            }
          : () => detailCopy(context, pkg),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: AnimatedBuilder(
          animation: AppInfoCache.revision,
          builder: (context, _) {
            final info = AppInfoCache.of(pkg);
            final name = (info?.appName.isNotEmpty ?? false)
                ? info!.appName
                : pkg.split('.').last;
            return Row(
              children: [
                _AppIcon(pkg: pkg, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        pkg,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (search != null)
                  Icon(Icons.search, size: 16, color: cs.onSurfaceVariant),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final close = onClose;
    final canClose = close != null && !data.closed && data.id.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        8 + MediaQuery.of(context).padding.bottom,
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: Text(getLocalText.s("Copy JSON")),
              onPressed: () => detailCopy(
                context,
                const JsonEncoder.withIndent('  ').convert(data.json),
                message: 'JSON copied',
              ),
            ),
          ),
          if (close != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.close, size: 16),
                label: Text(getLocalText.s("Close")),
                onPressed: canClose
                    ? () {
                        close(data.id);
                        Navigator.of(context).pop();
                      }
                    : null,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Заголовок группы + непустые строки, либо `[]`, если все пусты.
List<Widget> detailGroup(
  BuildContext context,
  String title,
  List<Widget?> rows,
) {
  final visible = rows.whereType<Widget>().toList();
  if (visible.isEmpty) return const [];
  final cs = Theme.of(context).colorScheme;
  return [
    Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: cs.primary,
        ),
      ),
    ),
    ...visible,
  ];
}

/// `label : value`; тап по умолчанию копирует value. `null`, если пусто.
Widget? detailRow(
  BuildContext context,
  String label,
  String value, {
  VoidCallback? onTap,
  Color? valueColor,
  Widget? trailing,
}) {
  if (value.isEmpty) return null;
  final cs = Theme.of(context).colorScheme;
  return InkWell(
    onTap: onTap ?? () => detailCopy(context, value),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                height: 1.3,
                color: valueColor,
              ),
              softWrap: true,
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 4), trailing],
        ],
      ),
    ),
  );
}

void detailCopy(
  BuildContext context,
  String value, {
  String message = 'Copied',
}) {
  Clipboard.setData(ClipboardData(text: value));
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
  );
}

/// §154 — launcher-иконка приложения; без package/иконки — `Icons.apps`.
class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.pkg, required this.size});

  final String pkg;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final placeholder = Icon(
      Icons.apps,
      size: size,
      color: cs.onSurfaceVariant,
    );
    if (pkg.isEmpty) return placeholder;
    AppInfoCache.ensure(pkg);
    return AnimatedBuilder(
      animation: AppInfoCache.revision,
      builder: (context, _) {
        final icon = AppInfoCache.of(pkg)?.icon;
        if (icon == null) return placeholder;
        return ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: Image.memory(
            icon,
            width: size,
            height: size,
            gaplessPlayback: true,
          ),
        );
      },
    );
  }
}

// ── Conns: однобокое соединение (§153) ──────────────────────────────────────

class _OneWayBadge extends StatelessWidget {
  const _OneWayBadge();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          Colors.pink.withValues(alpha: 0.22),
          cs.surface,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        getLocalText.s("One-way"),
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _OneWayBanner extends StatelessWidget {
  const _OneWayBanner({required this.conn});

  final CcConnection conn;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final detail = conn.uplink > 0 && conn.downlink == 0
        ? getLocalText.s(
            "Data sent (↑), no reply (↓0) — the stream looks stuck.",
          )
        : getLocalText.s(
            "Data received (↓), nothing sent (↑0) — the stream looks stuck.",
          );
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          Colors.pink.withValues(alpha: 0.14),
          cs.surface,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  getLocalText.s("One-way traffic"),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Профайлер: атрибуция, DNS, Issues ───────────────────────────────────────

Widget? _confidenceRow(BuildContext context, TrafficEvent e) {
  final cs = Theme.of(context).colorScheme;
  final color = switch (e.confidence) {
    ConfidenceLevel.verified => cs.onSurface,
    ConfidenceLevel.secondary => cs.tertiary,
    ConfidenceLevel.inferred => cs.secondary,
    ConfidenceLevel.unattributed => cs.error,
  };
  return detailRow(context, 'Confidence', e.confidence.name, valueColor: color);
}

/// DNS-группа события: запись, CNAME, сервер (rc.10), трасса DNS-группы
/// (§315), источник ответа. На не-DNS событиях все строки пусты — группы нет.
List<Widget?> _dnsGroup(BuildContext context, TrafficEvent e) {
  final dnsServer = e.extra?['dns_server']?.toString() ?? '';
  final dnsServerType = e.extra?['dns_server_type']?.toString() ?? '';
  final dnsServerLabel = dnsServer.isEmpty
      ? ''
      : (dnsServerType.isEmpty ? dnsServer : '$dnsServer ($dnsServerType)');
  // fanned = в запросе был веер, survival = чистых членов не осталось.
  final groupMode = [
    if (e.extra?['dns_fanned'] == 'true') 'fanned',
    if (e.extra?['dns_survival'] == 'true') 'survival',
  ].join(' · ');
  return detailGroup(context, 'DNS', [
    detailRow(context, 'Record', e.dnsRecordType ?? ''),
    detailRow(context, 'CNAME', e.cnameChain.join(' → ')),
    detailRow(context, 'DNS server', dnsServerLabel),
    detailRow(context, 'Group', e.extra?['dns_group_path']?.toString() ?? ''),
    detailRow(context, 'Attempts', e.extra?['dns_attempts']?.toString() ?? ''),
    detailRow(context, 'Group mode', groupMode),
    // источник ответа: exchanged / cached / …
    detailRow(context, 'Source', e.extra?['source']?.toString() ?? ''),
  ]);
}

Widget _issueRow(BuildContext context, ConnectionIssue a) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.warning_amber, size: 14, color: cs.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            a.description,
            style: TextStyle(fontSize: 13, color: cs.error),
          ),
        ),
      ],
    ),
  );
}
