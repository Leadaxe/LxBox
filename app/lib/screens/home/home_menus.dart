import 'package:flutter/material.dart';

import '../../controllers/home_controller.dart';

/// §070 — modal bottom sheet опций сортировки нод (long-press по sort-кнопке
/// в [NodesHeader]). Sheet остаётся открытым — можно тоггнуть несколько опций
/// подряд; `StatefulBuilder` перерисовывает чекбоксы локально. Изменения сразу
/// пишутся в [controller] (его `state` читается свежим на каждый rebuild —
/// между нашими `setSheetState` контроллер мог emit'нуть).
Future<void> showSortOptionsMenu(
  BuildContext context,
  HomeController controller,
) async {
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheetState) {
        final s = controller.state;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Sort options',
                    style: Theme.of(sheetCtx).textTheme.titleMedium),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: s.pinDirect,
                  onChanged: (v) {
                    controller.setPinDirect(v ?? false);
                    setSheetState(() {});
                  },
                  title: const Text('Pin DIRECT to top'),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                CheckboxListTile(
                  value: s.pinAuto,
                  onChanged: (v) {
                    controller.setPinAuto(v ?? false);
                    setSheetState(() {});
                  },
                  title: const Text('Pin AUTO to top'),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                CheckboxListTile(
                  value: s.resortOnManualPing,
                  onChanged: (v) {
                    controller.setResortOnManualPing(v ?? false);
                    setSheetState(() {});
                  },
                  title: const Text('Re-sort on manual ping'),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
