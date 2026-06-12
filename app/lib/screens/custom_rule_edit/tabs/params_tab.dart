import 'package:flutter/material.dart';

import '../../../models/custom_rule.dart';
import '../../../widgets/outbound_picker.dart';
import '../edit_controller.dart';
import '../sections/apps_section.dart';
import '../sections/dns_section.dart';
import '../sections/match_section.dart';
import '../sections/port_section.dart';
import '../sections/protocol_section.dart';
import '../sections/srs_section.dart';
import '../sections/wifi_section.dart';
import 'preset_params_tab.dart';

/// §053 Stage 3 — Params tab для inline/srs ветки.
///
/// Подписывается на `CustomRuleEditController` через `CustomRuleEditScope`.
/// Делегирует UI-actions (picker'ы, dialog'и) caller'у через [actions].
/// Если `controller.kind == preset` — рендерит [PresetParamsTab].
class ParamsTab extends StatelessWidget {
  const ParamsTab({
    super.key,
    required this.outboundOptions,
    required this.actions,
  });

  final List<OutboundOption> outboundOptions;
  final ParamsTabActions actions;

  @override
  Widget build(BuildContext context) {
    final c = CustomRuleEditScope.of(context);
    if (c.kind == CustomRuleKind.preset) {
      return PresetParamsTab(
        outboundOptions: outboundOptions,
        actions: actions,
      );
    }
    final theme = Theme.of(context);
    final canEnable = !(c.kind == CustomRuleKind.srs &&
        c.srsState != SrsDownloadState.cached);

    return ListView(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: c.nameCtrl,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Name',
                  isDense: true,
                  prefixIcon: Icon(Icons.label_outline, size: 18),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Switch(
              value: c.enabled,
              // srs без кэша — нельзя включить, сначала Download.
              onChanged: canEnable ? c.setEnabled : null,
            ),
          ],
        ),
        const SizedBox(height: 12),
        OutboundPicker(
          value: c.outbound,
          options: outboundOptions,
          onChanged: c.setOutbound,
          dense: false,
          label: 'Action',
        ),
        const SizedBox(height: 16),
        const Divider(),
        AppsSection(
          packages: c.packages,
          onTap: actions.onPickApps,
          onClear: () => c.setPackages(const []),
        ),
        const SizedBox(height: 8),
        const Divider(),
        Text('Source', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        RadioGroup<CustomRuleKind>(
          groupValue: c.kind,
          onChanged: (v) {
            if (v == null) return;
            c.setKind(v);
          },
          child: const Row(
            children: [
              Expanded(
                child: RadioListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: CustomRuleKind.inline,
                  title: Text('Inline'),
                ),
              ),
              Expanded(
                child: RadioListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: CustomRuleKind.srs,
                  title: Text('Remote (.srs)'),
                ),
              ),
            ],
          ),
        ),
        const Divider(),
        if (c.kind == CustomRuleKind.inline)
          MatchSection(
            domainCtrl: c.domainCtrl,
            domainSuffixCtrl: c.domainSuffixCtrl,
            domainKeywordCtrl: c.domainKeywordCtrl,
            ipCidrCtrl: c.ipCidrCtrl,
            ipIsPrivate: c.ipIsPrivate,
            onIpIsPrivateChanged: c.setIpIsPrivate,
          ),
        if (c.kind == CustomRuleKind.srs)
          SrsSection(
            urlCtrl: c.srsUrlCtrl,
            state: c.srsState,
            onDownload: c.downloadSrs,
            onShowCloudMenu: actions.onShowCloudMenu,
            onUrlChanged: c.resetSrsErrorIfAny,
          ),
        PortSection(
          portCtrl: c.portCtrl,
          portRangeCtrl: c.portRangeCtrl,
        ),
        ProtocolSection(
          selected: c.protocols,
          onToggle: c.toggleProtocol,
        ),
        if (c.kind == CustomRuleKind.inline ||
            c.kind == CustomRuleKind.srs)
          WifiSection(
            networks: c.wifiNetworks,
            onRemoveAt: c.removeWifiAt,
            onAddCurrent: actions.onAddCurrentWifi,
            onPickSaved: actions.onPickSavedWifi,
            onManual: actions.onManualAddWifi,
            onTapPermissionsHint: actions.onOpenWifiPermissions,
          ),
        // §117 задача 3 — DNS follows the rule (только inline/srs).
        DnsSection(
          dns: c.dns,
          serverTags: c.dnsServerTags,
          gateBlocked: c.dnsGateBlocked,
          isSrs: c.kind == CustomRuleKind.srs,
          onEnabledChanged: c.setDnsEnabled,
          onServerTagChanged: c.setDnsServerTag,
        ),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.save, size: 18),
          label: const Text('Save'),
          onPressed: actions.onSave,
        ),
      ],
    );
  }
}

/// Бундл UI-actions для Params/Preset tab'ов. Эти действия требуют
/// BuildContext (dialog'и, navigation, snackbar'ы) — живут на screen
/// State и передаются вниз как props.
class ParamsTabActions {
  const ParamsTabActions({
    required this.onSave,
    required this.onDelete,
    required this.onPickApps,
    required this.onAddCurrentWifi,
    required this.onPickSavedWifi,
    required this.onManualAddWifi,
    required this.onOpenWifiPermissions,
    required this.onShowCloudMenu,
    required this.onBoolVarFailed,
  });

  final VoidCallback onSave;
  final VoidCallback onDelete;
  final VoidCallback onPickApps;
  final VoidCallback onAddCurrentWifi;
  final VoidCallback onPickSavedWifi;
  final VoidCallback onManualAddWifi;
  final VoidCallback onOpenWifiPermissions;
  final void Function(Offset globalPos) onShowCloudMenu;

  /// Bool-var toggle закончился ошибкой — caller показывает snackbar.
  /// Параметр — display-имя var'а ("title or name") для текста сообщения.
  final void Function(String varDisplay) onBoolVarFailed;
}
