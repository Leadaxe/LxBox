import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/l10n/locale_controller.dart';
import 'update_status_row.dart';

/// General tab для App Settings.
///
/// Stateless — все значения и callback'и приходят от
/// `_AppSettingsScreenState`, который остаётся source-of-truth и делает
/// setState + side-effect внутри каждого callback'а. Поведение идентично
/// инлайн-версии (parent rebuild'ит этот widget на каждый setState).
class GeneralTab extends StatelessWidget {
  const GeneralTab({
    super.key,
    required this.loaded,
    required this.autoStart,
    required this.autoCheckUpdates,
    required this.autoPing,
    required this.haptic,
    required this.autoReloadOnChange,
    required this.padding,
    required this.onAutoStartChanged,
    required this.onAutoCheckUpdatesChanged,
    required this.onAutoPingChanged,
    required this.onHapticChanged,
    required this.onAutoReloadOnChangeChanged,
    required this.onAddQuickSettingsTile,
    required this.onOpenBackup,
    required this.region,
    required this.detectedRegion,
    required this.onEditRegion,
  });

  final bool loaded;
  final bool autoStart;
  final bool autoCheckUpdates;
  final bool autoPing;
  final bool haptic;

  /// §338 — автоперезапуск VPN при любом изменении конфига (жизнь без плашек).
  final bool autoReloadOnChange;
  final EdgeInsets padding;

  final ValueChanged<bool> onAutoStartChanged;
  final ValueChanged<bool> onAutoCheckUpdatesChanged;
  final ValueChanged<bool> onAutoPingChanged;
  final ValueChanged<bool> onHapticChanged;
  final ValueChanged<bool> onAutoReloadOnChangeChanged;
  final VoidCallback onAddQuickSettingsTile;
  final VoidCallback onOpenBackup;

  /// §425 — регион использования: `auto` | `none` | код страны.
  final String region;

  /// §425 — автоопределённая страна (`''` — не определилась).
  final String detectedRegion;
  final VoidCallback onEditRegion;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: padding,
      children: [
        // §425 — регион использования: общая настройка, потребители — пулы
        // WARP (loc.<cc>), дальше региональные дефолты правил.
        Text(getLocalText.s("Region"),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.public_outlined),
          title: Text(getLocalText.s("Usage region")),
          subtitle: Text(regionLabel(region, detectedRegion)),
          trailing: const Icon(Icons.edit_outlined),
          onTap: loaded ? onEditRegion : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            getLocalText.s("The country you use the app in. Drives region-specific defaults: today the WARP SNI pool, later routing rule presets. Auto = country of the mobile network, then of the device locale."),
            style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        const Divider(height: 32),
        Text(getLocalText.s("Behavior"),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(getLocalText.s("Auto-start on boot")),
          subtitle: Text(getLocalText.s("Start VPN when device turns on")),
          secondary: const Icon(Icons.power_settings_new),
          value: autoStart,
          onChanged: loaded ? onAutoStartChanged : null,
        ),
        // §338 — автоприменение изменений конфига к живому туннелю. Настройка
        // не про подписки: источник изменения любой (узел, detour, DNS,
        // routing, per-app), поэтому живёт в Behavior, а не в Subscriptions.
        SwitchListTile(
          title: Text(getLocalText.s("Auto-restart VPN on settings change")),
          subtitle: Text(getLocalText.s("Apply every config change to the running tunnel by itself, so no banner is left to tap. Each apply drops the tunnel for about 3 seconds and kills open connections.")),
          secondary: const Icon(Icons.restart_alt),
          value: autoReloadOnChange,
          onChanged: loaded ? onAutoReloadOnChangeChanged : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            getLocalText.s("While this is on, the per-subscription \"On update\" setting is hidden — everything is applied immediately. Turning it off brings each subscription's own choice back."),
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const Divider(height: 32),
        Text(getLocalText.s("Quick connect"),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.dashboard_customize_outlined),
          title: Text(getLocalText.s("Quick Settings tile")),
          subtitle: Text(getLocalText.s("Add to status-bar shade for one-tap toggle. Android 13+ shows a system prompt; on older versions edit the shade manually.")),
          trailing: TextButton(
            onPressed: onAddQuickSettingsTile,
            child: Text(getLocalText.s("Add")),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.touch_app_outlined),
          title: Text(getLocalText.s("Home-screen shortcut")),
          subtitle: Text(getLocalText.s("Long-press the L×Box icon on your home screen → choose \"Toggle VPN\".")),
        ),
        const Divider(height: 32),
        Text(getLocalText.s("Updates"),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(getLocalText.s("Check for updates on launch")),
          subtitle: Text(getLocalText.s("Pings github.com once a day to check for new releases. \"View\" opens the release page in browser; install is manual.")),
          secondary: const Icon(Icons.system_update_alt),
          value: autoCheckUpdates,
          onChanged: loaded ? onAutoCheckUpdatesChanged : null,
        ),
        const UpdateStatusRow(),
        const Divider(height: 32),
        Text(getLocalText.s("Feedback"),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(getLocalText.s("Auto-ping after connect")),
          subtitle: Text(getLocalText.s("Ping nodes of active group 5s after VPN starts (once per connect)")),
          secondary: const Icon(Icons.network_ping),
          value: autoPing,
          onChanged: loaded ? onAutoPingChanged : null,
        ),
        SwitchListTile(
          title: Text(getLocalText.s("Haptic feedback")),
          subtitle: Text(getLocalText.s("Vibrate on connect, disconnect and errors. Respects system \"Touch feedback\" setting")),
          secondary: const Icon(Icons.vibration),
          value: haptic,
          onChanged: loaded ? onHapticChanged : null,
        ),
        const Divider(height: 32),
        Text(getLocalText.s("Backup & restore"),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.import_export),
          title: Text(getLocalText.s("Backup & restore")),
          subtitle: Text(getLocalText.s("Export subscriptions, routing setup and preferences as JSON.")),
          trailing: const Icon(Icons.chevron_right),
          contentPadding: EdgeInsets.zero,
          onTap: onOpenBackup,
        ),
      ],
    );
  }

  /// §425 — подпись значения региона для плитки и диалога.
  static String regionLabel(String region, String detected) {
    if (region == 'none') return getLocalText.s("Not set");
    if (region == 'auto') {
      return detected.isEmpty
          ? getLocalText.s("Auto · country not detected")
          : getLocalText.s("Auto · %s", detected.toUpperCase());
    }
    return region.toUpperCase();
  }
}

class KeepUiOnBackTile extends StatefulWidget {
  const KeepUiOnBackTile({super.key});

  @override
  State<KeepUiOnBackTile> createState() => _KeepUiOnBackTileState();
}

class _KeepUiOnBackTileState extends State<KeepUiOnBackTile> {
  static const _prefsKey = 'keep_ui_on_back';
  static const _timerPrefsKey = 'keep_ui_on_back_close_after_minutes';
  static const _minimizeTimerPrefsKey = 'keep_ui_on_back_close_on_minimize';
  bool _enabled = false;
  bool _startTimerOnMinimize = false;
  int _minutes = 0;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _enabled = prefs.getBool(_prefsKey) ?? false;
      _startTimerOnMinimize = prefs.getBool(_minimizeTimerPrefsKey) ?? false;
      _minutes = prefs.getInt(_timerPrefsKey) ?? 0;
      _loaded = true;
    });
  }

  Future<void> _setEnabled(bool value) async {
    setState(() => _enabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, value);
  }

  Future<void> _editTimer() async {
    final hoursController = TextEditingController(
      text: _minutes <= 0 ? '0' : (_minutes ~/ 60).toString(),
    );
    final minutesController = TextEditingController(
      text: _minutes <= 0 ? '0' : (_minutes % 60).toString().padLeft(2, '0'),
    );
    String? error;

    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          scrollable: false,
          title: Row(
            children: [
              Expanded(
                child: Text(getLocalText.s("Close interface")),
              ),
              IconButton(
                tooltip: getLocalText.s("Help"),
                onPressed: () => showDialog<void>(
                  context: dialogContext,
                  builder: (helpContext) => AlertDialog(
                    title: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 22,
                          color: Theme.of(helpContext)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(getLocalText.s("How the timer works"))),
                      ],
                    ),
                    content: Text(
                      getLocalText.s("• The timer starts after leaving the app with the Back button or gesture.\n• When ‘Timer on minimize’ is enabled, it also starts when the app goes to the background.\n• Returning to the app before the countdown ends cancels the timer.\n• When the timer expires, the app closes completely."),
                    ),
                    actions: [
                      FilledButton(
                        onPressed: () => Navigator.pop(helpContext),
                        child: Text(getLocalText.s("Got it")),
                      ),
                    ],
                  ),
                ),
                icon: Icon(
                  Icons.error_outline,
                  color: Theme.of(dialogContext)
                      .colorScheme
                      .onSurfaceVariant,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                visualDensity: VisualDensity.compact,
                value: _startTimerOnMinimize,
                onChanged: (value) async {
                  final enabled = value ?? false;
                  setDialogState(() => _startTimerOnMinimize = enabled);
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool(_minimizeTimerPrefsKey, enabled);
                },
                title: Text(getLocalText.s("Timer on minimize")),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: TextField(
                    controller: hoursController,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                    maxLength: 2,
                    onTap: () {
                      hoursController.selection = TextSelection(
                        baseOffset: 0,
                        extentOffset: hoursController.text.length,
                      );
                    },
                    onChanged: (text) {
                      if (text.isEmpty) {
                        hoursController.value = const TextEditingValue(
                          text: '0',
                          selection: TextSelection.collapsed(offset: 1),
                        );
                      } else if (text.length > 1 && text.startsWith('0')) {
                        final normalized = text.replaceFirst(RegExp(r'^0+'), '');
                        hoursController.value = TextEditingValue(
                          text: normalized,
                          selection: TextSelection.collapsed(offset: normalized.length),
                        );
                      }
                    },
                    decoration: InputDecoration(labelText: getLocalText.s("Hours"), hintText: '0', counterText: ''),
                  )),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text(':', style: TextStyle(fontSize: 24)),
                  ),
                  Expanded(child: TextField(
                    controller: minutesController,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    maxLength: 2,
                    onTap: () {
                      minutesController.selection = TextSelection(
                        baseOffset: 0,
                        extentOffset: minutesController.text.length,
                      );
                    },
                    onChanged: (text) {
                      if (text.isEmpty) {
                        minutesController.value = const TextEditingValue(
                          text: '0',
                          selection: TextSelection.collapsed(offset: 1),
                        );
                      } else if (text.length > 1 && text.startsWith('0')) {
                        final normalized = text.replaceFirst(RegExp(r'^0+'), '');
                        minutesController.value = TextEditingValue(
                          text: normalized,
                          selection: TextSelection.collapsed(offset: normalized.length),
                        );
                      }
                    },
                    decoration: InputDecoration(labelText: getLocalText.s("Minutes"), hintText: '0', counterText: ''),
                  )),
                ],
              ),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(error!, style: TextStyle(color: Theme.of(dialogContext).colorScheme.error)),
              ],
            ],
          ),
          actions: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, 0),
                  child: Text(getLocalText.s("No timer")),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () {
                    final hours = int.tryParse(hoursController.text.trim());
                    final minutes = int.tryParse(minutesController.text.trim());
                    if (hours == null || hours < 0 || hours > 99) {
                      setDialogState(() => error = getLocalText.s("Enter hours from 0 to 99."));
                      return;
                    }
                    if (minutes == null || minutes < 0 || minutes > 59) {
                      setDialogState(() => error = getLocalText.s("Minutes must be from 0 to 59."));
                      return;
                    }
                    if (hours == 0 && minutes == 0) {
                      setDialogState(() => error = getLocalText.s("Set a time greater than 00:00."));
                      return;
                    }
                    Navigator.pop(dialogContext, hours * 60 + minutes);
                  },
                  child: Text(getLocalText.s("Apply")),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    hoursController.dispose();
    minutesController.dispose();
    if (value == null || !mounted) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_timerPrefsKey, value);
    setState(() => _minutes = value);
  }

  String get _timerDisplay {
    final h = _minutes ~/ 60;
    final m = _minutes % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.exit_to_app),
      title: Text(getLocalText.s("Keep interface on exit")),
      subtitle: Text(
        getLocalText.s("The Back button/gesture minimizes the app instead of closing its interface."),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_minutes > 0)
            SizedBox(
              width: 64,
              height: 40,
              child: TextButton(
                onPressed: _loaded && _enabled ? _editTimer : null,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  _timerDisplay,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                ),
              ),
            )
          else
            IconButton(
              tooltip: getLocalText.s("Timer"),
              onPressed: _loaded && _enabled ? _editTimer : null,
              icon: const Icon(Icons.schedule),
            ),
          Switch(
            value: _enabled,
            onChanged: _loaded ? _setEnabled : null,
          ),
        ],
      ),
      isThreeLine: _minutes > 0,
    );
  }
}
