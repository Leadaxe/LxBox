import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/memory_limit_setting.dart';
import '../../services/format_utils.dart';
import '../../services/settings_storage.dart';
import '../../vpn/box_vpn_client.dart';
import '../../services/l10n/locale_controller.dart';
import '../../widgets/app_bottom_sheet.dart';

/// Bottom-sheet с детализацией памяти процесса приложения.
///
/// Ядро sing-box работает в этом же процессе (VpnService без `android:process`),
/// поэтому «память» на карточке Stats — это RSS всего процесса, а не только
/// ядра. Sheet разбивает её на категории: суммарный RSS/PSS из
/// CommandClient-статуса + native `getMemoryInfo` (§507, AMS PSS-разбивка:
/// native heap с Go-буферами ядра, Dalvik/ART, graphics, code, stack, system)
/// + runtime-показатели ядра (goroutines, connections). §705 (ядро lx.29,
/// SPEC 148): [coreRuntime] — память Go-рантайма ядра из статуса
/// (`memoryRuntime`), именно с ней ядро сравнивает порог Memory limit;
/// 0 у старого ядра — строка скрыта.
Future<void> showMemoryDetailSheet(
  BuildContext context, {
  required int rss,
  int coreRuntime = 0,
  required int goroutines,
  required int connectionsIn,
  required int connectionsOut,
}) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _MemoryDetailSheet(
      rss: rss,
      coreRuntime: coreRuntime,
      goroutines: goroutines,
      connectionsIn: connectionsIn,
      connectionsOut: connectionsOut,
    ),
  );
}

class _MemoryDetailSheet extends StatefulWidget {
  const _MemoryDetailSheet({
    required this.rss,
    this.coreRuntime = 0,
    required this.goroutines,
    required this.connectionsIn,
    required this.connectionsOut,
  });

  final int rss;
  final int coreRuntime;
  final int goroutines;
  final int connectionsIn;
  final int connectionsOut;

  @override
  State<_MemoryDetailSheet> createState() => _MemoryDetailSheetState();
}

class _MemoryDetailSheetState extends State<_MemoryDetailSheet> {
  MemoryInfo? _info;
  bool _loading = true;

  /// Memory limit из VPN Settings (wire-значение [MemoryLimitSetting]):
  /// пресет в MB даёт дробь `/ N MB` у Core memory, `auto` — без неё.
  String _memoryLimit = MemoryLimitSetting.auto;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final limitF = SettingsStorage.getNativeMemoryLimit();
    final info = await BoxVpnClient().getMemoryInfo();
    final limit = await limitF;
    if (!mounted) return;
    setState(() {
      _info = info;
      _memoryLimit = limit;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) => Column(
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Icon(Icons.memory, size: 20, color: cs.secondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    getLocalText.s("Memory"),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  formatBytes(widget.rss, spaced: true),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: cs.secondary,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: _sections(context),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _sections(BuildContext context) {
    final out = <Widget>[];
    final info = _info;

    // Process — суммарные цифры процесса.
    out.addAll(_group(context, 'Process', [
      _row(context, 'RSS', formatBytes(widget.rss, spaced: true)),
      if (widget.coreRuntime > 0) ...[
        _row(context, getLocalText.s("Core memory"), _coreRuntimeValue()),
        _caption(context, getLocalText.s("Memory of the VPN core itself (Go runtime); the limit from VPN Settings applies to this figure. RSS is the whole app process.")),
      ],
      if (info != null && info.totalPss > 0)
        _row(context, 'Total PSS', formatBytes(info.totalPss, spaced: true)),
      if (info != null && info.totalSwap > 0)
        _row(context, 'Swap', formatBytes(info.totalSwap, spaced: true)),
    ]));

    // Breakdown — категории PSS из Debug.MemoryInfo. Native heap несёт
    // Go-память ядра (буферы WireGuard, хипы sing-box).
    if (info != null) {
      out.addAll(_group(context, 'Breakdown', [
        _row(context, 'Native heap', formatBytes(info.nativeHeap, spaced: true)),
        _row(context, 'Java/Dalvik heap', formatBytes(info.javaHeap, spaced: true)),
        _row(context, 'Graphics', formatBytes(info.graphics, spaced: true)),
        _row(context, 'Code', formatBytes(info.code, spaced: true)),
        _row(context, 'Stack', formatBytes(info.stack, spaced: true)),
        _row(context, 'System', formatBytes(info.system, spaced: true)),
        _row(context, 'Other', formatBytes(info.privateOther, spaced: true)),
      ]));

      // Native heap — прямые malloc-счётчики (не PSS).
      out.addAll(_group(context, 'Native heap', [
        _row(context, 'Allocated',
            formatBytes(info.nativeHeapAllocated, spaced: true)),
        _row(context, 'Reserved',
            formatBytes(info.nativeHeapSize, spaced: true)),
      ]));
    }

    // Core runtime — из CommandClient-статуса.
    out.addAll(_group(context, 'Core runtime', [
      _row(context, 'Goroutines', '${widget.goroutines}'),
      _row(context, 'Connections in', '${widget.connectionsIn}'),
      _row(context, 'Connections out', '${widget.connectionsOut}'),
    ]));

    if (_loading) {
      out.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ));
    }

    return out;
  }

  /// `42.1 MB / 200 MB` при пресетном лимите, без дроби при `auto`.
  String _coreRuntimeValue() {
    final used = formatBytes(widget.coreRuntime, spaced: true);
    final mb = int.tryParse(_memoryLimit);
    return mb == null ? used : '$used / $mb MB';
  }

  /// Пояснение под строкой — стиль подсказок настроек (bodySmall,
  /// onSurfaceVariant).
  Widget _caption(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  List<Widget> _group(BuildContext context, String title, List<Widget?> rows) {
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

  Widget _row(BuildContext context, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () {
        Clipboard.setData(ClipboardData(text: value));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(getLocalText.s("Copied: %s", value)),
              duration: const Duration(seconds: 1)),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 128,
              child: Text(
                label,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  height: 1.3,
                ),
                softWrap: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
