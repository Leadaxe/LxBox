import 'dart:async';

import 'package:flutter/material.dart';

import '../models/custom_rule.dart';
import '../models/parser_config.dart';
import '../services/settings_storage.dart';
import '../services/ui_helpers.dart';
import '../services/url_launcher.dart' as ul;
import '../widgets/outbound_picker.dart';
import '../widgets/wifi_entry.dart';
import '../widgets/wifi_manual_add_dialog.dart';
import '../widgets/wifi_permission_dialog.dart';
import '../widgets/wifi_saved_picker_sheet.dart';
import 'app_picker_screen.dart';
import 'app_settings_screen.dart';
import 'custom_rule_edit/action_resolve_sheet.dart';
import 'custom_rule_edit/edit_controller.dart';
import 'custom_rule_edit/tabs/params_tab.dart';
import 'custom_rule_edit/tabs/view_tab.dart';

/// Редактор `CustomRule` (spec §030).
///
/// Все match-поля заполняются параллельно — sing-box внутри категории
/// (domain-family, port-family) матчит OR, между категориями AND. Правило
/// вида `domain_suffix=[.ru] & port=[443]` = "любой .ru домен И порт 443".
/// Протокол — отдельно, всегда AND (на routing rule level).
///
/// `kind=srs` — remote `.srs` rule_set по URL. Port/protocol всё равно
/// применяются (на routing rule level).
///
/// §053 Stage 3 — state живёт в [CustomRuleEditController]; tab'ы /
/// sections подписываются через [CustomRuleEditScope]. Screen State
/// держит только owner-ship controller'а + UI-actions требующие
/// BuildContext (save/back/delete dialog'и, picker'ы, snackbar'ы).
class CustomRuleEditScreen extends StatefulWidget {
  const CustomRuleEditScreen({
    super.key,
    required this.initial,
    required this.outboundOptions,
    required this.existingNames,
    this.preset,
  });

  final CustomRule initial;
  final List<OutboundOption> outboundOptions;
  final Set<String> existingNames;

  /// Bundle-пресет (spec §033). Обязателен когда `initial.kind == preset` —
  /// форма рендерит его `vars` для юзер-ввода. Null для preset-правила =
  /// broken-preset (пресет удалён/переименован в шаблоне) — показываем
  /// fallback-экран с Delete.
  final SelectableRule? preset;

  @override
  State<CustomRuleEditScreen> createState() => _CustomRuleEditScreenState();
}

class _CustomRuleEditScreenState extends State<CustomRuleEditScreen> {
  late final CustomRuleEditController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = CustomRuleEditController(
      initial: widget.initial,
      preset: widget.preset,
      existingNames: widget.existingNames,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // ─── Save / delete / back ────────────────────────────────────────────

  Future<void> _save() async {
    final name = _ctrl.nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name is required')),
      );
      return;
    }
    String finalName = name;
    if (widget.existingNames.contains(name)) {
      var i = 2;
      while (widget.existingNames.contains('$name ($i)')) {
        i++;
      }
      finalName = '$name ($i)';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Name in use — renamed to "$finalName"')),
      );
    }

    // §051 Phase 2 — preflight permission check если у правила есть wifi
    // условия. Без NEARBY_WIFI_DEVICES + ACCESS_BACKGROUND_LOCATION sing-box
    // не сможет прочитать SSID и rule не сматчится. Лучше предупредить
    // СЕЙЧАС чем юзер удивится «правило сохранил а не работает».
    if (_ctrl.wifiNetworks.isNotEmpty) {
      final missing = <String>[];
      if (!await ul.UrlLauncher.checkBackgroundLocationPermission()) {
        missing.add('android.permission.ACCESS_BACKGROUND_LOCATION');
      }
      if (!await ul.UrlLauncher.checkNearbyWifiPermission()) {
        missing.add('android.permission.NEARBY_WIFI_DEVICES');
      }
      if (missing.isNotEmpty && mounted) {
        await WifiPermissionDialog.show(context, missing: missing);
        // Не блокируем save — юзер мог нажать «Allow Wi-Fi info» и нам
        // надо сохранить правило в любом случае. Permission'ы прорастут
        // при следующем connect (или сразу если runtime grant прошёл).
      }
    }

    if (!mounted) return;
    final saved = _ctrl.snapshot().withName(finalName);
    Navigator.pop(context, _CustomRuleEditResult.saved(saved));
  }

  Future<void> _delete() async {
    final confirmed = await showDeleteConfirmDialog(
      context,
      title: 'Delete rule?',
      message: 'Remove "${widget.initial.name}" permanently?',
    ); // §219
    if (confirmed == true && mounted) {
      Navigator.pop(context, _CustomRuleEditResult.deleted());
    }
  }

  /// Обработчик back (system + AppBar leading). Если unsaved — confirm
  /// с тремя опциями: Save / Keep editing / Discard.
  Future<void> _handleBack() async {
    if (!_ctrl.isDirty()) {
      Navigator.pop(context);
      return;
    }
    final action = await showUnsavedChangesDialog(context); // §219
    if (!mounted) return;
    if (action == 'save') {
      _save(); // сам сделает Navigator.pop при успехе
    } else if (action == 'discard') {
      Navigator.pop(context);
    }
    // 'keep' / null — остаёмся на экране
  }

  // ─── SRS cloud menu (long-press на ☁) ────────────────────────────────

  /// Контекстное меню для cloud-иконки URL'а (long-press).
  /// - Refresh SRS = тот же `downloadSrs` что и tap
  /// - Clear cache = удалить локальный `.srs` файл, не трогая правило.
  ///   После очистки `_enabled` сбрасывается в false — без cache правило
  ///   не может работать, switch в UI тоже заблокируется.
  Future<void> _showCloudMenu(Offset pos) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy,
        overlay.size.width - pos.dx,
        overlay.size.height - pos.dy,
      ),
      items: [
        const PopupMenuItem<String>(
          value: 'refresh',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.refresh, size: 20),
            title: Text('Refresh SRS'),
          ),
        ),
        PopupMenuItem<String>(
          value: 'clear',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.cloud_off_outlined,
                size: 20, color: Theme.of(context).colorScheme.error),
            title: Text('Clear cached file',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'refresh':
        unawaited(_ctrl.downloadSrs());
      case 'clear':
        await _ctrl.clearSrsCache();
    }
  }

  // ─── Wi-Fi pickers (§051 Phase 2) ────────────────────────────────────

  Future<void> _addCurrentWifi() async {
    final result = await ul.UrlLauncher.getCurrentWifiInfo();
    if (!mounted) return;
    switch (result) {
      case ul.WifiInfoSuccess(:final ssid, :final bssid):
        _ctrl.addWifiEntry(WifiEntry(ssid, bssid));
        await SettingsStorage.addToWifiHistory(ssid, bssid);
      case ul.WifiInfoError(:final reason):
        if (reason == 'permission_missing') {
          await WifiPermissionDialog.show(
            context,
            missing: const [
              'android.permission.ACCESS_BACKGROUND_LOCATION',
              'android.permission.NEARBY_WIFI_DEVICES',
            ],
          );
          return;
        }
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 3),
            content: Text(switch (reason) {
              'no_wifi' => 'Not connected to Wi-Fi.',
              'unknown_ssid' =>
                'Cannot read Wi-Fi info — try toggling Wi-Fi off/on.',
              _ => 'Could not read current Wi-Fi ($reason).',
            }),
          ),
        );
    }
  }

  Future<void> _pickSavedWifi() async {
    final result = await showWifiSavedPickerSheet(
      context,
      excludeRuleId: widget.initial.id,
    );
    if (result == null || result.isEmpty || !mounted) return;
    _ctrl.addWifiEntries(result);
  }

  Future<void> _manualAddWifi() async {
    final result = await showWifiManualAddDialog(context);
    if (result == null || !mounted) return;
    _ctrl.addWifiEntry(result);
    await SettingsStorage.addToWifiHistory(result.ssid, result.bssid);
  }

  Future<void> _openWifiPermissionsScreen() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const AppSettingsScreen(initialTab: 2),
    ));
  }

  Future<void> _openAppPicker() async {
    final result = await Navigator.push<AppPickerResult>(
      context,
      MaterialPageRoute(
        builder: (_) => AppPickerScreen(selected: _ctrl.packages.toSet()),
      ),
    );
    if (result == null || !mounted) return;
    _ctrl.setPackages(result.packages);
  }

  /// §247 — окно «Action & Resolve» (⚙ у Action-пикера).
  void _openActionResolve() {
    showActionResolveSheet(
      context,
      controller: _ctrl,
      outboundOptions: widget.outboundOptions,
    );
  }

  void _onBoolVarFailed(String varDisplay) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            'Failed to download SRS for "$varDisplay". Check internet and try again.'),
      ),
    );
  }

  // ─── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final actions = ParamsTabActions(
      onSave: _save,
      onDelete: _delete,
      onPickApps: _openAppPicker,
      onAddCurrentWifi: _addCurrentWifi,
      onPickSavedWifi: _pickSavedWifi,
      onManualAddWifi: _manualAddWifi,
      onOpenWifiPermissions: _openWifiPermissionsScreen,
      onShowCloudMenu: _showCloudMenu,
      onBoolVarFailed: _onBoolVarFailed,
      onOpenActionResolve: _openActionResolve,
    );

    return CustomRuleEditScope(
      notifier: _ctrl,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          unawaited(_handleBack());
        },
        child: DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Edit rule'),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _handleBack,
              ),
              actions: [
                // §264 — locked-пресет (traffic-processing) нельзя удалить:
                // delete-иконку скрываем.
                if (!(_ctrl.preset?.locked ?? false))
                  IconButton(
                    tooltip: 'Delete rule',
                    icon: Icon(Icons.delete_outline,
                        color: Theme.of(context).colorScheme.error),
                    onPressed: _delete,
                  ),
                _SaveIconButton(controller: _ctrl, onPressed: _save),
              ],
              bottom: const TabBar(
                tabs: [Tab(text: 'Params'), Tab(text: 'View')],
              ),
            ),
            body: TabBarView(
              children: [
                ParamsTab(
                  outboundOptions: widget.outboundOptions,
                  actions: actions,
                ),
                const ViewTab(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Save-icon в AppBar: подсвечивается primary-цветом если `isDirty()`.
/// Вынесено в отдельный widget чтобы rebuild ограничивался только этой
/// кнопкой (а не всем AppBar'ом) когда controller notify'ит.
class _SaveIconButton extends StatelessWidget {
  const _SaveIconButton({required this.controller, required this.onPressed});

  final CustomRuleEditController controller;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (ctx, _) {
        final dirty = controller.isDirty();
        return IconButton(
          tooltip: 'Save',
          icon: Icon(Icons.save,
              color: dirty ? Theme.of(ctx).colorScheme.primary : null),
          onPressed: onPressed,
        );
      },
    );
  }
}

/// Результат редактора — либо сохранение, либо удаление.
class _CustomRuleEditResult {
  const _CustomRuleEditResult._({this.saved, this.wasDeleted = false});
  final CustomRule? saved;
  final bool wasDeleted;

  factory _CustomRuleEditResult.saved(CustomRule rule) =>
      _CustomRuleEditResult._(saved: rule);
  factory _CustomRuleEditResult.deleted() =>
      const _CustomRuleEditResult._(wasDeleted: true);
}

/// Публичный wrapper для использования в RoutingScreen.
class CustomRuleEditResult {
  const CustomRuleEditResult._internal(this._inner);
  final _CustomRuleEditResult _inner;

  CustomRule? get saved => _inner.saved;
  bool get wasDeleted => _inner.wasDeleted;
}

Future<CustomRuleEditResult?> openCustomRuleEditor(
  BuildContext context, {
  required CustomRule initial,
  required List<OutboundOption> outboundOptions,
  required Set<String> existingNames,
  SelectableRule? preset,
}) async {
  final result = await Navigator.push<_CustomRuleEditResult>(
    context,
    MaterialPageRoute(
      builder: (_) => CustomRuleEditScreen(
        initial: initial,
        outboundOptions: outboundOptions,
        existingNames: existingNames,
        preset: preset,
      ),
    ),
  );
  if (result == null) return null;
  return CustomRuleEditResult._internal(result);
}
