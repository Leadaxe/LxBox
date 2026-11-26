import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/custom_rule.dart';
import '../../../widgets/outbound_picker.dart';
import '../edit_controller.dart';
import '../sections/json_section.dart';
import '../sections/srs_section.dart';
import '../sections/conditions_section.dart';
import 'preset_params_tab.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../../widgets/dpad_radio_group.dart';

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
          // §683 — Resolve only — пункт Action (⚙ и окно «Action & Resolve»
          // сняты; настройки резолва — в секции DNS & Resolve).
          OutboundPicker(
            value: c.resolveOnly ? kResolveOnlyAction : c.outbound,
            options: outboundOptions,
            onChanged: (v) {
              if (v == kResolveOnlyAction) {
                c.setResolveOnly(true);
              } else {
                c.setResolveOnly(false);
                c.setOutbound(v);
              }
            },
            allowResolveOnly: c.resolveEligible,
            dense: false,
            label: 'Action',
          ),
          const SizedBox(height: 8),
        ],
        const Divider(),
        // §757 — правило правится условиями формы либо телом JSON. Уход из
        // JSON раскладывает тело в форму (цель — в Action); не раскладывается
        // — вопрос Discard / Keep editing.
        DpadRadioGroup<bool>(
          groupValue: c.jsonMode,
          onChanged: (v) {
            if (v == null) return;
            if (v) {
              c.enterJsonMode();
            } else {
              unawaited(leaveJsonMode(context, c));
            }
          },
          child: Row(
            children: [
              Expanded(
                child: RadioListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: false,
                  title: Text(getLocalText.s("Conditions")),
                ),
              ),
              Expanded(
                child: RadioListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: true,
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
        if (c.kind != CustomRuleKind.json) ...[
          ConditionsSection(stack: c.stack, assist: actions.assist),
          // §757 — наборы всего дерева: скачивание, период проверки.
          if (c.kind == CustomRuleKind.srs) ...[
            const Divider(),
            SrsSection(
              urls: c.allRefs,
              state: c.srsState,
              onDownload: c.downloadSrs,
              onShowCloudMenu: actions.onShowCloudMenu,
              // §366 — TTL кэша и время последней проверки.
              ttlHours: c.srsTtlHours,
              onTtlChanged: (v) => c.srsTtlHours = v,
              lastUpdatedText: c.srsLastUpdatedText,
            ),
          ],
          // §757 — DNS & Resolve — на своей вкладке DNS (DnsTab).
        ],
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
        // §757 — почему Save недоступен (как у окна правила лаунчера).
        if (c.saveBlockReason case final reason?)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_outlined,
                    size: 16, color: theme.colorScheme.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(reason,
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
              ],
            ),
          ),
        FilledButton.icon(
          icon: const Icon(Icons.save, size: 18),
          label: Text(getLocalText.s("Save")),
          // §225/§447 — блокировка по той же проверке, что у Save в AppBar.
          onPressed: c.saveBlockReason == null ? actions.onSave : null,
        ),
      ],
    );
  }
}

/// §757 — уход из JSON-вида в форму условий. Тело не раскладывается —
/// вопрос: Discard (в форму без правок JSON) / Keep editing. У json-правила
/// без формы — только причина.
Future<void> leaveJsonMode(
    BuildContext context, CustomRuleEditController c) async {
  final reason = c.applyJsonToForm();
  if (reason == null) return;
  if (!c.formAvailable) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(reason)));
    return;
  }
  if (await askDiscardJson(context, reason)) c.discardJson();
}

/// §757 — вопрос при уходе из JSON-вида, тело которого не раскладывается в
/// форму (смена режима или переход на вкладку DNS / View): true — Discard.
Future<bool> askDiscardJson(BuildContext context, String reason) async {
  final discard = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(getLocalText.s("Leave JSON?")),
      content: Text(getLocalText.s(
          "%s Discard returns to the form without the JSON changes.",
          reason)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error),
          child: Text(getLocalText.s("Discard")),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(getLocalText.s("Keep editing")),
        ),
      ],
    ),
  );
  return discard == true;
}

/// Бундл UI-actions для Params/Preset tab'ов. Эти действия требуют
/// BuildContext (dialog'и, navigation, snackbar'ы) — живут на screen
/// State и передаются вниз как props.
class ParamsTabActions {
  const ParamsTabActions({
    required this.onSave,
    required this.onDelete,
    required this.assist,
    required this.onShowCloudMenu,
    required this.onBoolVarFailed,
  });

  final VoidCallback onSave;
  final VoidCallback onDelete;

  /// §757 — действия полей условий (приложения, Wi-Fi, подсказка
  /// разрешений): нужны и экранам под-правил.
  final ConditionAssist assist;
  final void Function(Offset globalPos) onShowCloudMenu;

  /// Bool-var toggle закончился ошибкой — caller показывает snackbar.
  /// Параметр — display-имя var'а ("title or name") для текста сообщения.
  final void Function(String varDisplay) onBoolVarFailed;
}
