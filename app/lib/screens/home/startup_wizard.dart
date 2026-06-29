import 'package:flutter/widgets.dart';

import '../../vpn/box_vpn_client.dart';
import 'home_dialogs.dart';

/// Единый last-mile движок first-run-онбординга. Прогоняет шаги
/// **последовательно** (await каждый) — следующий показывается только после
/// закрытия предыдущего. Это и упорядочивает онбординг в одном месте, и чинит
/// гонку, когда несколько barrier-диалогов запускались параллельно через
/// `unawaited` и наезжали друг на друга.
///
/// Каждый шаг идемпотентен и сам хранит свой persist-флаг (показывается один
/// раз) — движок не дублирует эту логику. Порядок: от «нужно для работы»
/// (notification / battery) к «приятно иметь» (add-tile).
///
/// НЕ включает событийные промпты (support-message по факту подключения,
/// update-snackbar по приходу новой версии) — они не онбординг.
class StartupWizard {
  StartupWizard(this.context, this.vpn);

  final BuildContext context;
  final BoxVpnClient vpn;

  Future<void> run() async {
    // 1. Notification permission (Android 13+ runtime perm) — сам гейтит
    //    по persist-флагу и наличию разрешения.
    if (!context.mounted) return;
    await maybeShowNotificationPermissionDialog(context);

    // 2. Battery optimization — сам гейтит по whitelist + persist-флагу.
    if (!context.mounted) return;
    await maybeShowBatteryOptimizationDialog(context, vpn);

    // 3. Add QS tile — на API 33+ системный промпт, на старых тихо no-op.
    if (!context.mounted) return;
    await maybeShowAddTilePrompt(context, vpn);
  }
}
