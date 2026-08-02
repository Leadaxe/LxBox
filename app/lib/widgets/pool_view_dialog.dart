import 'package:flutter/material.dart';

import '../vpn/cc_channel.dart';
import '../services/l10n/locale_controller.dart';

/// §208 (SPEC 019 V2) — попап с текущим составом пула round_robin-группы.
/// Открывается из контекстного меню auto-ноды («View pool»). Снапшот тянется
/// через `getPool` (unary RPC ядра); пустой → «Pool not available».
///
/// Слоты фиксированы по `slot`; нода в слоте может меняться при дотесте.
/// `delay`==0 → нода мёртвая/не измерена («—»).
/// §208 — цвет delay-бейджа: те же пороги, что у node_row (200/500 мс).
/// `delay <= 0` — мёртвая/не измеренная нода.
Color poolDelayColor(BuildContext context, int delay) {
  final cs = Theme.of(context).colorScheme;
  if (delay <= 0) return cs.onSurfaceVariant;
  if (delay < 200) return Colors.green;
  if (delay < 500) return Colors.orange;
  return cs.error;
}

/// §208/§344 — строка слота пула (`slot N · тег · delay`). Общий рендер для
/// попапа «View pool» и раздела Members/Route экрана деталей (§344): формат
/// слотов один, второй копии не заводим.
///
/// [onTap] — §344: в списке экрана слот кликабелен (→ экран владельца);
/// в попапе навигации нет, там null.
Widget poolSlotRow(
  BuildContext context,
  CcPoolSlot slot, {
  VoidCallback? onTap,
}) {
  final cs = Theme.of(context).colorScheme;
  final delayText = slot.delay > 0 ? '${slot.delay} ms' : '—';
  final row = Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        // фиксированный номер слота
        SizedBox(
          width: 48,
          child: Text(getLocalText.s("slot %d", slot.slot),
              style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: cs.onSurfaceVariant)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(slot.tag,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 8),
        Text(delayText,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: poolDelayColor(context, slot.delay))),
      ],
    ),
  );
  if (onTap == null) return row;
  return InkWell(onTap: onTap, child: row);
}

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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.hub_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(getLocalText.s("Pool · %s", widget.title),
                style: const TextStyle(fontSize: 15),
                overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            tooltip: getLocalText.s("Refresh"),
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
                child: Text(getLocalText.s("Pool unavailable — tunnel not connected"),
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              );
            }
            if (slots.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(getLocalText.s("Pool is empty (not a load-balance group)"),
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final s in slots) poolSlotRow(context, s),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(getLocalText.s("Close")),
        ),
      ],
    );
  }

}
