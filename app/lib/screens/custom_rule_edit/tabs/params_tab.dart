import 'package:flutter/material.dart';

import '../../../models/custom_rule.dart';
import '../../../widgets/outbound_picker.dart';
import '../edit_controller.dart';
import '../sections/apps_section.dart';
import '../sections/dns_section.dart';
import '../sections/inbound_section.dart';
import '../sections/json_section.dart';
import '../sections/match_section.dart';
import '../sections/network_protocol_section.dart';
import '../sections/port_section.dart';
import '../sections/srs_section.dart';
import '../sections/wifi_section.dart';
import 'preset_params_tab.dart';
import '../../../services/l10n/locale_controller.dart';

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
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: getLocalText.s("Name"),
                  isDense: true,
                  prefixIcon: const Icon(Icons.label_outline, size: 18),
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
        // §225 — у json-правила действие внутри тела, OutboundPicker скрыт.
        if (c.kind != CustomRuleKind.json) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: OutboundPicker(
                  value: c.outbound,
                  options: outboundOptions,
                  onChanged: c.setOutbound,
                  dense: false,
                  label: 'Action',
                ),
              ),
              // §247 — шестерёнка «Action & Resolve». Видна только когда
              // правилу есть что резолвить (inline с доменами / srs).
              if (c.resolveEligible) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: getLocalText.s("Action & Resolve"),
                  icon: Icon(
                    Icons.settings_outlined,
                    color: c.resolve != null
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  onPressed: actions.onOpenActionResolve,
                ),
              ],
            ],
          ),
          // §247 — inline-статус текущего режима (виден без открытия окна).
          if (c.resolve != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(
                c.resolve!.only
                    ? getLocalText.s("✳ Resolve only%s", c.resolve!.strategy.isNotEmpty
                            ? ' · ${c.resolve!.strategy}'
                            : '')
                    : getLocalText.s("✳ Resolve first%s", c.resolve!.strategy.isNotEmpty
                            ? ' · ${c.resolve!.strategy}'
                            : ''),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary),
              ),
            ),
          const SizedBox(height: 16),
          const Divider(),
          AppsSection(
            packages: c.packages,
            onTap: actions.onPickApps,
            onClear: () => c.setPackages(const []),
          ),
          const SizedBox(height: 8),
        ],
        const Divider(),
        Text(getLocalText.s("Source"), style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        RadioGroup<CustomRuleKind>(
          groupValue: c.kind,
          onChanged: (v) {
            if (v == null) return;
            c.setKind(v);
          },
          child: Row(
            children: [
              Expanded(
                child: RadioListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: CustomRuleKind.inline,
                  title: Text(getLocalText.s("Inline")),
                ),
              ),
              Expanded(
                child: RadioListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: CustomRuleKind.srs,
                  title: Text(getLocalText.s("Remote (.srs)")),
                ),
              ),
              Expanded(
                child: RadioListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: CustomRuleKind.json,
                  title: Text(getLocalText.s("Raw JSON")),
                ),
              ),
            ],
          ),
        ),
        const Divider(),
        // §225 — json-режим: только тело правила, остальные секции скрыты.
        if (c.kind == CustomRuleKind.json)
          JsonSection(
            controller: c.jsonCtrl,
            errorText: c.jsonError,
            onChanged: c.notifyJsonChanged,
          ),
        if (c.kind == CustomRuleKind.inline)
          MatchSection(
            domainCtrl: c.domainCtrl,
            domainSuffixCtrl: c.domainSuffixCtrl,
            domainKeywordCtrl: c.domainKeywordCtrl,
            ipCidrCtrl: c.ipCidrCtrl,
            ipIsPrivate: c.ipIsPrivate,
            onIpIsPrivateChanged: c.setIpIsPrivate,
            sourceIpCidrCtrl: c.sourceIpCidrCtrl,
            sourceIpIsPrivate: c.sourceIpIsPrivate,
            onSourceIpIsPrivateChanged: c.setSourceIpIsPrivate,
          ),
        if (c.kind == CustomRuleKind.srs)
          SrsSection(
            urlCtrl: c.srsUrlCtrl,
            state: c.srsState,
            onDownload: c.downloadSrs,
            onShowCloudMenu: actions.onShowCloudMenu,
            onUrlChanged: c.resetSrsErrorIfAny,
            // §366 — TTL кэша и время последней проверки.
            ttlHours: c.srsTtlHours,
            onTtlChanged: (v) => c.srsTtlHours = v,
            lastUpdatedText: c.srsLastUpdatedText,
          ),
        // §225 — match-фильтры (port/protocol/wifi/inbound/dns) не применимы
        // к raw-JSON правилу: всё выражается в самом теле.
        if (c.kind != CustomRuleKind.json) ...[
          PortSection(
            portCtrl: c.portCtrl,
            portRangeCtrl: c.portRangeCtrl,
          ),
          NetworkProtocolSection(
            networks: c.network,
            protocols: c.protocols,
            onToggleNetwork: c.toggleNetwork,
            onToggleProtocol: c.toggleProtocol,
            onClearAll: c.clearNetworkAndProtocol,
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
          // §030/new_fields — INBOUND фильтр (tun-in / mixed-in). inline + srs.
          if (c.kind == CustomRuleKind.inline ||
              c.kind == CustomRuleKind.srs)
            InboundSection(
              selected: c.inbounds,
              choices: c.inboundChoices,
              onToggle: c.toggleInbound,
            ),
          // §117 задача 3 — DNS follows the rule (только inline/srs).
          DnsSection(
            dns: c.dns,
            serverTags: c.dnsServerTags,
            gateBlocked: c.dnsGateBlocked,
            isSrs: c.kind == CustomRuleKind.srs,
            onEnabledChanged: c.setDnsEnabled,
            onServerTagChanged: c.setDnsServerTag,
            onForceIpv4Changed: c.setForceIpv4,
          ),
        ],
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.save, size: 18),
          label: Text(getLocalText.s("Save")),
          // §225 — json-режим: блокируем Save на невалидном/пустом теле.
          onPressed: c.jsonError == null ? actions.onSave : null,
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
    required this.onOpenActionResolve,
  });

  final VoidCallback onSave;
  final VoidCallback onDelete;
  final VoidCallback onPickApps;
  final VoidCallback onAddCurrentWifi;
  final VoidCallback onPickSavedWifi;
  final VoidCallback onManualAddWifi;
  final VoidCallback onOpenWifiPermissions;
  final void Function(Offset globalPos) onShowCloudMenu;

  /// §247 — открыть окно «Action & Resolve» (⚙ у Action-пикера).
  final VoidCallback onOpenActionResolve;

  /// Bool-var toggle закончился ошибкой — caller показывает snackbar.
  /// Параметр — display-имя var'а ("title or name") для текста сообщения.
  final void Function(String varDisplay) onBoolVarFailed;
}
