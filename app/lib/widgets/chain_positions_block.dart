// §394 — блок «Chain positions» во вкладке Diagnostics узла типа `chain`.
//
// Паритет с окном Info лаунчера (`ui/servers_node_info_chain.go`): строка на
// позицию, справа НАКОПИТЕЛЬНАЯ задержка и цена хопа «(+X)», под списком —
// текст ошибки ядра, ниже кнопка повторного прогона.
//
// Почему накопительная И дельта, а не что-то одно: накопительная отвечает
// «сколько всего стоит путь досюда», дельта — «кто именно это добавил». По
// одной первой не видно виновника, по одной второй — не видно, во что
// обошёлся маршрут целиком.

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/l10n/locale_controller.dart';
import '../services/probe/chain_layer_probe.dart';

/// Состояние блока — отдельно от вёрстки, чтобы логика («что показать при
/// таком отчёте») проверялась тестом без построения дерева виджетов.
class ChainPositionsBlock extends StatefulWidget {
  const ChainPositionsBlock({
    super.key,
    required this.chainTag,
    required this.hops,
    this.probeFactory,
  });

  final String chainTag;

  /// Позиции В ПОРЯДКЕ ПАКЕТА из собранного конфига.
  final List<String> hops;

  /// Подмена прогона в тестах. В проде — `ChainLayerProbe.new`.
  final ChainLayerProbe Function()? probeFactory;

  @override
  State<ChainPositionsBlock> createState() => _ChainPositionsBlockState();
}

class _ChainPositionsBlockState extends State<ChainPositionsBlock> {
  ChainLayerProbe? _probe;
  bool _running = false;
  ChainProbeReport? _report;

  /// Причина, по которой прогон не состоялся (туннель выключен, узел не
  /// цепочка). Отличается от слоя с ошибкой — тот лежит в [_report] и
  /// сбоем прогона не является.
  String _error = '';

  @override
  void dispose() {
    // §286 — уход с экрана во время прогона: результат уже не нужен, а
    // последовательный обход слоёв не должен продолжаться в пустоту.
    _probe?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _error = '';
      _report = null;
    });
    final probe = (widget.probeFactory ?? ChainLayerProbe.new)();
    _probe = probe;
    try {
      final report =
          await probe.run(widget.chainTag, hops: widget.hops);
      if (!mounted) return;
      setState(() => _report = report);
    } on ChainProbeUnavailable catch (e) {
      if (!mounted) return;
      setState(() => _error = switch (e.reason) {
            'vpn_down' => getLocalText.s(
                "Start the VPN to probe this chain — its hops exist only in the running core."),
            'no_positions' =>
              getLocalText.s("This chain has no positions to probe."),
            _ => e.reason,
          });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _running = false);
      _probe = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final report = _report;
    // Текст ошибки ядра — под списком и с переносом: сообщение длинное и в
    // колонку задержки не помещается. Показываем ПЕРВУЮ: следующие слои
    // помечены «not reached», своей ошибки у них нет.
    final layerError = report?.layers
        .where((l) => l.error.isNotEmpty)
        .map((l) => l.error)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          getLocalText.plural("Chain positions (%d)", widget.hops.length),
          style: theme.textTheme.titleSmall?.copyWith(
            color: cs.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          getLocalText.s(
              "Cumulative delay to each hop; (+X) is what that hop added."),
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        const Divider(),
        for (var i = 0; i < widget.hops.length; i++)
          _positionRow(context, i, report),
        if (layerError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              layerError,
              style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
            ),
          ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error,
              style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: OutlinedButton.icon(
            onPressed: _running ? null : () => unawaited(_run()),
            icon: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh, size: 18),
            label: Text(_running
                ? getLocalText.s("Measuring…")
                : report == null
                    ? getLocalText.s("Probe by position")
                    : getLocalText.s("Probe again")),
          ),
        ),
      ],
    );
  }

  Widget _positionRow(BuildContext context, int i, ChainProbeReport? report) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final layer =
        (report != null && i < report.layers.length) ? report.layers[i] : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            // l10n-exempt: position number
            child: Text('${i + 1}.',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(widget.hops[i],
                style: const TextStyle(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          Text(
            _measureText(i, layer, report),
            style: TextStyle(
              fontSize: 13,
              fontFamily: 'monospace',
              color: layer == null
                  ? cs.onSurfaceVariant
                  : layer.ok
                      ? cs.onSurface
                      : cs.error,
            ),
          ),
        ],
      ),
    );
  }

  /// Правая колонка строки: «— » до прогона, «123 ms  (+45)» при успехе,
  /// «error» / «not reached» иначе.
  ///
  /// Ошибка помечается СЛОВОМ, а не цифрой: ноль миллисекунд читался бы как
  /// «бесплатный хоп», хотя он попросту не ответил.
  String _measureText(int i, ChainLayerResult? layer, ChainProbeReport? report) {
    // l10n-exempt: em dash placeholder
    if (layer == null) return '—';
    if (layer.notReached) return getLocalText.s("not reached");
    if (layer.error.isNotEmpty) return getLocalText.s("error");
    final delta = report?.deltaAt(i);
    // l10n-exempt: milliseconds + signed delta, no words
    return delta == null
        ? '${layer.cumulativeMs} ms'
        : '${layer.cumulativeMs} ms  (+$delta)';
  }
}
