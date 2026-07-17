import 'package:flutter/material.dart';

import '../vpn/cc_channel.dart';
import '../services/l10n/l10n.dart';

/// §208 (SPEC 019 V2) — попап с текущим составом пула round_robin-группы.
/// Открывается из контекстного меню auto-ноды («View pool»). Снапшот тянется
/// через `getPool` (unary RPC ядра); пустой → «Pool not available».
///
/// Слоты фиксированы по `slot`; нода в слоте может меняться при дотесте.
/// `delay`==0 → нода мёртвая/не измерена («—»).
Future<void> showPoolDialog(
  BuildContext context, {
  required String autoTag,
  required String title,
  required Future<List<CcPoolSlot>?> Function(String autoTag) fetch,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _PoolDialog(autoTag: autoTag, title: title, fetch: fetch),
  );
}

class _PoolDialog extends StatefulWidget {
  const _PoolDialog({
    required this.autoTag,
    required this.title,
    required this.fetch,
  });

  final String autoTag;
  final String title;
  final Future<List<CcPoolSlot>?> Function(String autoTag) fetch;

  @override
  State<_PoolDialog> createState() => _PoolDialogState();
}

class _PoolDialogState extends State<_PoolDialog> {
  late Future<List<CcPoolSlot>?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.fetch(widget.autoTag);
  }

  void _refresh() => setState(() => _future = widget.fetch(widget.autoTag));

  /// Те же пороги, что у delay-бейджа node_row (200/500 мс).
  Color _delayColor(BuildContext context, int delay) {
    final cs = Theme.of(context).colorScheme;
    if (delay <= 0) return cs.onSurfaceVariant; // мёртвая/не измерена
    if (delay < 200) return Colors.green;
    if (delay < 500) return Colors.orange;
    return cs.error;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.hub_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(context.l.homePoolTitle(widget.title),
                style: const TextStyle(fontSize: 15),
                overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            tooltip: context.l.commonRefresh,
            icon: const Icon(Icons.refresh, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: _refresh,
          ),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      content: SizedBox(
        width: 320,
        child: FutureBuilder<List<CcPoolSlot>?>(
          future: _future,
          builder: (ctx, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                    child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2))),
              );
            }
            // §209 — null = CC-клиент недоступен (сервис/туннель down). НЕ
            // путать с пустым пулом ([] = пул пуст / не round_robin).
            final slots = snap.data;
            if (slots == null) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(ctx.l.homePoolUnavailable,
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              );
            }
            if (slots.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(ctx.l.homePoolEmpty,
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final s in slots) _slotRow(context, cs, s),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l.commonClose),
        ),
      ],
    );
  }

  Widget _slotRow(BuildContext context, ColorScheme cs, CcPoolSlot s) {
    final delayText = s.delay > 0 ? '${s.delay} ms' : '—';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          // фиксированный номер слота
          SizedBox(
            width: 48,
            child: Text(context.l.homePoolSlot(s.slot),
                style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(s.tag,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          Text(delayText,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _delayColor(context, s.delay))),
        ],
      ),
    );
  }
}
