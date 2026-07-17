import 'package:flutter/material.dart';

import '../../../services/l10n/l10n.dart';
import '../../../services/settings_storage.dart';
import '../../../vpn/pprof_profile.dart';

/// Diagnostics tab для App Settings.
///
/// Stateless — state-снимок и callback'и приходят от
/// `_AppSettingsScreenState` (source-of-truth). Каждый callback внутри
/// делает setState + side-effect, parent rebuild'ит этот widget. Поведение
/// идентично инлайн-версии.
class DiagnosticsTab extends StatelessWidget {
  const DiagnosticsTab({
    super.key,
    required this.loaded,
    required this.padding,
    required this.batteryWhitelisted,
    required this.notificationsEnabled,
    required this.backgroundLocationGranted,
    required this.nearbyWifiGranted,
    required this.debugEnabled,
    required this.debugPort,
    required this.debugToken,
    required this.debugPortError,
    required this.debugPortCtl,
    required this.configLocked,
    required this.coreLogsEnabled,
    required this.coreLogsHighlighted,
    required this.coreLogsTileKey,
    required this.autoRecordWifi,
    required this.onBatteryTap,
    required this.onNotificationsTap,
    required this.onBackgroundLocationTap,
    required this.onNearbyWifiTap,
    required this.onAppInfoTap,
    required this.onDebugApiChanged,
    required this.onCopyDebugToken,
    required this.onRegenerateDebugToken,
    required this.onDebugPortSubmitted,
    required this.onConfigLockedChanged,
    required this.onCoreLogsChanged,
    required this.onQuitApp,
    required this.onAutoRecordWifiChanged,
    required this.capturing,
    required this.onCaptureProfile,
  });

  final bool loaded;
  final EdgeInsets padding;

  final bool batteryWhitelisted;
  final bool notificationsEnabled;
  final bool backgroundLocationGranted;
  final bool nearbyWifiGranted;

  final bool debugEnabled;
  final int debugPort;
  final String debugToken;
  final String debugPortError;
  final TextEditingController debugPortCtl;
  final bool configLocked;

  final bool coreLogsEnabled;
  final bool coreLogsHighlighted;
  final GlobalKey coreLogsTileKey;

  final bool autoRecordWifi;

  final VoidCallback onBatteryTap;
  final VoidCallback onNotificationsTap;
  final VoidCallback onBackgroundLocationTap;
  final VoidCallback onNearbyWifiTap;
  final VoidCallback onAppInfoTap;
  final ValueChanged<bool> onDebugApiChanged;
  final VoidCallback? onCopyDebugToken;
  final VoidCallback onRegenerateDebugToken;
  final ValueChanged<String> onDebugPortSubmitted;
  final ValueChanged<bool> onConfigLockedChanged;
  final ValueChanged<bool> onCoreLogsChanged;
  final VoidCallback onQuitApp;
  final ValueChanged<bool> onAutoRecordWifiChanged;

  /// §207 — снять pprof-слепок (libbox PProfServer); аргумент = дескриптор
  /// профиля ([PprofProfile]).
  /// `capturing` = захват в процессе → все кнопки disabled (один сервер/порт).
  final bool capturing;
  final ValueChanged<PprofProfile> onCaptureProfile;

  /// §207 — иконка кнопки по id профиля.
  static IconData _iconFor(String id) => switch (id) {
        'goroutine' => Icons.account_tree_outlined,
        'profile' => Icons.speed_outlined,
        'heap' => Icons.memory_outlined,
        'allocs' => Icons.dataset_outlined,
        _ => Icons.bug_report_outlined,
      };

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: padding,
      children: [
        Text(context.l.appSettingsDiagSystemSetupHeader,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: Icon(
            batteryWhitelisted ? Icons.battery_full : Icons.battery_alert,
            color: batteryWhitelisted
                ? Colors.green
                : Theme.of(context).colorScheme.error,
          ),
          title: Text(context.l.appSettingsDiagBatteryTitle),
          subtitle: Text(batteryWhitelisted
              ? 'Whitelisted — VPN can run in background'
              : 'Restricted — Android may pause VPN in idle. Tap to grant.'),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: onBatteryTap,
        ),
        ListTile(
          leading: Icon(
            notificationsEnabled
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined,
            color: notificationsEnabled
                ? Colors.green
                : Theme.of(context).colorScheme.error,
          ),
          title: Text(context.l.appSettingsDiagNotificationsTitle),
          subtitle: Text(notificationsEnabled
              ? 'Allowed — foreground service shows VPN status'
              : 'Blocked — Android may throttle the VPN service. Tap to allow.'),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: onNotificationsTap,
        ),
        // §051 — Wi-Fi rules permissions: BACKGROUND_LOCATION (API 29+) и
        // NEARBY_WIFI_DEVICES (API 33+). Без них sing-box `wifi_ssid` /
        // `wifi_bssid` правила не сматчатся (`WifiInfo.ssid` возвращает
        // `<unknown ssid>`). См. spec/050 findings + spec/051.
        ListTile(
          leading: Icon(
            backgroundLocationGranted
                ? Icons.location_on_outlined
                : Icons.location_off_outlined,
            color: backgroundLocationGranted
                ? Colors.green
                : Theme.of(context).colorScheme.error,
          ),
          title: Text(context.l.appSettingsDiagLocationTitle),
          subtitle: Text(backgroundLocationGranted
              ? 'Granted — sing-box can read Wi-Fi state for routing rules'
              : 'Required for Wi-Fi-based routing rules. Tap to grant.'),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: onBackgroundLocationTap,
        ),
        ListTile(
          leading: Icon(
            nearbyWifiGranted
                ? Icons.wifi_outlined
                : Icons.wifi_off_outlined,
            color: nearbyWifiGranted
                ? Colors.green
                : Theme.of(context).colorScheme.error,
          ),
          title: Text(context.l.appSettingsDiagNearbyWifiTitle),
          subtitle: Text(nearbyWifiGranted
              ? 'Granted — real SSID/BSSID accessible'
              : 'Android 13+ requires this for SSID. Tap to grant.'),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: onNearbyWifiTap,
        ),
        ListTile(
          leading: const Icon(Icons.settings_applications_outlined),
          title: Text(context.l.appSettingsDiagAppInfoTitle),
          subtitle: Text(context.l.appSettingsDiagAppInfoSubtitle),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: onAppInfoTap,
        ),
        const Divider(height: 32),
        Text(context.l.appSettingsDiagDeveloperHeader,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(context.l.appSettingsDiagDebugApiTitle),
          subtitle: Text(
            debugEnabled
                ? 'Exposed on http://127.0.0.1:$debugPort (adb forward only)'
                : 'Runtime HTTP server for adb-forwarded debugging.',
          ),
          secondary: const Icon(Icons.bug_report),
          value: debugEnabled,
          onChanged: loaded ? onDebugApiChanged : null,
        ),
        if (debugEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l.appSettingsDiagTokenLabel,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        debugToken.isEmpty ? '(not set)' : debugToken,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: context.l.commonCopy,
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed:
                          debugToken.isEmpty ? null : onCopyDebugToken,
                    ),
                    IconButton(
                      tooltip: context.l.commonRegenerate,
                      icon: const Icon(Icons.refresh, size: 18),
                      onPressed: onRegenerateDebugToken,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: debugPortCtl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: context.l.appSettingsDiagPortLabel,
                    helperText: context.l.appSettingsDiagPortRange(
                        SettingsStorage.debugPortMin,
                        SettingsStorage.debugPortMax),
                    errorText: debugPortError.isEmpty
                        ? null
                        : debugPortError,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: onDebugPortSubmitted,
                ),
                const SizedBox(height: 8),
                Text(
                  context.l.appSettingsDiagTokenNote,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        // §037 — config_locked_for_debug. Видим только когда Debug API ON,
        // чтобы lock не висел сиротой без UI-возврата к разблокировке (его
        // снимают через Debug API `PUT /settings/config_locked` или этим
        // toggle'ом). При выключении Debug API toggle выше — lock auto-снимется.
        if (debugEnabled)
          SwitchListTile(
            title: Text(context.l.appSettingsDiagLockConfigTitle),
            subtitle: Text(
              configLocked
                  ? 'Pinned. UI actions skip config rebuild — useful when testing PUT /config overrides.'
                  : 'Off — UI actions rebuild config from settings as usual.',
            ),
            secondary: const Icon(Icons.lock_outline),
            value: configLocked,
            onChanged: loaded ? onConfigLockedChanged : null,
          ),
        // §043: forwarding sing-box internal logs into our AppLog (Debug
        // screen → Core tab + /logs/core endpoint). Off by default — sing-box
        // на busy traffic эмитит сотни строк/минуту; opt-in для диагностики.
        // Subtitle короткий и timeless — без «after restart» (показывался бы
        // и после самого рестарта, misleading); пояснялка про process-restart
        // вынесена в полноширинный блок ниже.
        AnimatedContainer(
          key: coreLogsTileKey,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
          color: coreLogsHighlighted
              ? Theme.of(context).colorScheme.tertiaryContainer
              : Colors.transparent,
          child: SwitchListTile(
            title: Text(context.l.appSettingsDiagForwardLogsTitle),
            subtitle: Text(
              coreLogsEnabled
                  ? 'Visible in Debug → Core.'
                  : 'Off.',
            ),
            secondary: const Icon(Icons.terminal),
            value: coreLogsEnabled,
            onChanged: loaded ? onCoreLogsChanged : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l.appSettingsDiagForwardLogsNote,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: loaded ? onQuitApp : null,
                icon: const Icon(Icons.logout, size: 18),
                label: Text(context.l.appSettingsDiagQuitButton),
              ),
            ],
          ),
        ),
        // §207 — on-device profiling. Snapshots the running core via libbox
        // PProfServer (goroutines / CPU / heap / allocs) — VPN must be
        // running. Captured file opens the system Share sheet.
        const Divider(height: 8),
        Text(context.l.appSettingsDiagProfilingHeader,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l.appSettingsDiagProfilingBody,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              for (final p in PprofProfile.all) ...[
                OutlinedButton.icon(
                  onPressed: (loaded && !capturing)
                      ? () => onCaptureProfile(p)
                      : null,
                  icon: (capturing && p.blockingSeconds > 0)
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(_iconFor(p.id), size: 18),
                  label: Text(context.l.appSettingsDiagCaptureButton(p.label)),
                ),
                const SizedBox(height: 6),
              ],
              Text(
                context.l.appSettingsDiagPprofHint,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        // §051 Phase 3 — auto-record visited Wi-Fi networks. Default ON:
        // без auto-record «Pick saved» picker почти всегда пустой,
        // фича теряет смысл. 5-минутный stickiness отсекает drive-by
        // сети (магазин/проход). Toggle для тех кто не хочет logging.
        const Divider(height: 8),
        SwitchListTile(
          title: Text(context.l.appSettingsDiagAutoRecordTitle),
          subtitle: Text(
            autoRecordWifi
                ? 'Networks where you stay ≥ 5 minutes appear in routing rule editor → Pick saved.'
                : 'Off. Pick saved is populated only by Add current / Manual.',
          ),
          secondary: const Icon(Icons.history),
          value: autoRecordWifi,
          onChanged: loaded ? onAutoRecordWifiChanged : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
          child: Text(
            context.l.appSettingsDiagAutoRecordNote,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
