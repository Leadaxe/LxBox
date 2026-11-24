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

/// §759 (ядро SPEC 138) — вторая строка слота: карантин и счётчики
/// «соединения / подтверждённые отказы» (коротко: попап шириной 320). `null`, когда показывать нечего —
/// строка слота тогда выглядит как до §759.
Widget? _slotNote(BuildContext context, CcPoolSlot slot) {
  final cs = Theme.of(context).colorScheme;
  final hasCounters = slot.connections > 0 || slot.confirmedFailures > 0;
  if (!slot.quarantined && !hasCounters) return null;
  final style = TextStyle(fontSize: 11, color: cs.onSurfaceVariant);
  return Text.rich(
    TextSpan(
      children: [
        if (slot.quarantined)
          TextSpan(
              text: getLocalText.s("quarantine"),
              style: TextStyle(color: cs.error)),
        if (slot.quarantined && hasCounters)
          const TextSpan(text: ' · '), // l10n-exempt: separator
        if (hasCounters)
          TextSpan(
              text: getLocalText.s("%d conn · %d fail",
                  slot.connections, slot.confirmedFailures)),
      ],
    ),
    style: style,
    overflow: TextOverflow.ellipsis,
  );
}

/// §759 (ядро SPEC 138) — части шапки пула: сдвинутые ключи закрепления,
/// «проблемы в адресе», заморозка. Нулевые части не попадают в список;
/// пустой список — у здорового пула, у least_test / failover и у ядра без
/// этих полей.
List<String> poolStateParts(CcPoolState state) => [
      if (state.shiftedKeys > 0)
        getLocalText.s("shifted keys: %d", state.shiftedKeys),
      if (state.markedKeys > 0)
        getLocalText.s("address problems: %d", state.markedKeys),
      if (state.frozen)
        state.frozenSeconds > 0
            ? getLocalText.s("frozen for %d s", state.frozenSeconds)
            : getLocalText.s("frozen until the network check ends"),
    ];

/// §759 — шапка пула одной строкой вторичного текста; `null` — показывать
/// нечего (см. [poolStateParts]).
Widget? poolStateHeader(BuildContext context, CcPoolState state) {
  final parts = poolStateParts(state);
  if (parts.isEmpty) return null;
  final cs = Theme.of(context).colorScheme;
  return Padding(
    key: const ValueKey('pool-state-header'),
    padding: const EdgeInsets.only(bottom: 6),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(parts.join(' · '), // l10n-exempt: separator
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
    ),
  );
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
  final delayText =
      slot.delay > 0 ? '${slot.delay} ms' : '—'; // l10n-exempt: unit
  final note = _slotNote(context, slot);
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(slot.tag,
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis),
              ?note,
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(delayText,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                // §759 — узел в карантине не в ротации: его задержка —
                // история, а не рабочее значение, поэтому без цвета.
                color: slot.quarantined
                    ? cs.onSurfaceVariant
                    : poolDelayColor(context, slot.delay))),
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
  required Future<CcPoolState?> Function(String autoTag) fetch,
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
  final Future<CcPoolState?> Function(String autoTag) fetch;

  @override
  State<_PoolDialog> createState() => _PoolDialogState();
}

class _PoolDialogState extends State<_PoolDialog> {
  late Future<CcPoolState?> _future;

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
        child: FutureBuilder<CcPoolState?>(
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
            final state = snap.data;
            if (state == null) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(getLocalText.s("Pool unavailable — tunnel not connected"),
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              );
            }
            final slots = state.slots;
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
                ?poolStateHeader(context, state),
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
