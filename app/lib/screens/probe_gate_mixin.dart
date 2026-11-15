import 'package:flutter/material.dart';

import '../models/tunnel_status.dart';
import '../services/l10n/locale_controller.dart';
import '../vpn/box_vpn_client.dart';

/// §296 — общий VPN-гейт для probe. Probe-сессия — временный CommandServer без
/// tun; два CommandServer на процесс невозможны, поэтому тест недоступен, пока
/// VPN активен. Раньше гейт жил в folder_detail_screen; вынесен, чтобы экраны
/// подписок/серверов делили тот же попап и логику Stop VPN.
///
/// Использование: `if (await ensureVpnStoppedForProbe()) { ...прогон... }`.
/// Экран сам решает, что запускать после успешной остановки — mixin про
/// конкретный прогон не знает.
mixin ProbeGateMixin<T extends StatefulWidget> on State<T> {
  /// Возвращает `true`, если тестировать можно: VPN уже выключен, либо юзер
  /// нажал Stop VPN и остановка удалась. `false` — VPN активен и юзер отменил,
  /// либо остановить не удалось (в этом случае показан SnackBar).
  Future<bool> ensureVpnStoppedForProbe() async {
    if ((await BoxVpnClient().getVpnStatus()) == TunnelStatus.disconnected) {
      return true;
    }
    if (!mounted) return false;
    return _showGateAndStop();
  }

  /// §236-гонка: probe-сессия вернула маркер «VPN is running» (VPN стартовал
  /// между pre-check и probeStart). Показывает тот же гейт; при успешном Stop
  /// возвращает `true`, чтобы экран перезапустил прогон.
  Future<bool> onProbeVpnRaceGate() => _showGateAndStop();

  Future<bool> _showGateAndStop() async {
    // §738 — VPN могут остановить мимо диалога (шторка, плитка, Automation,
    // обрыв туннеля): диалог тогда закрывается сам и тест идёт дальше, вторая
    // остановка не нужна.
    var stoppedOutside = false;
    var closed = false;
    BuildContext? dialogCtx;
    final statusSub = BoxVpnClient().onStatusChanged.listen((e) {
      final ctx = dialogCtx;
      if (e.status != TunnelStatus.disconnected ||
          closed ||
          ctx == null ||
          !ctx.mounted) {
        return;
      }
      closed = true;
      stoppedOutside = true;
      Navigator.pop(ctx, true);
    });
    final bool? stop;
    try {
      stop = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          dialogCtx = ctx;
          return _gateDialog(ctx, (stop) {
            if (closed) return;
            closed = true;
            Navigator.pop(ctx, stop);
          });
        },
      );
    } finally {
      await statusSub.cancel();
    }
    if (stop != true) return false;
    if (stoppedOutside) return mounted;
    final ok = await BoxVpnClient().stopVPN();
    if (!mounted) return false;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(getLocalText.s("Couldn't stop the VPN — try again.")),
        ),
      );
      return false;
    }
    return true;
  }

  Widget _gateDialog(
    BuildContext ctx,
    void Function(bool stop) close,
  ) => AlertDialog(
    title: Text(getLocalText.s("VPN is running")),
    content: Text(
      getLocalText.s(
        "Servers can't be tested while the VPN is on — the test needs its own core session, which can't run alongside the active tunnel. Stop the VPN to test the servers.",
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => close(false),
        child: Text(getLocalText.s("Cancel")),
      ),
      FilledButton(
        onPressed: () => close(true),
        child: Text(getLocalText.s("Stop VPN")),
      ),
    ],
  );
}
