import 'package:flutter/material.dart';

import '../../../models/custom_rule.dart';
import '../../../widgets/outbound_picker.dart';
import '../../../widgets/reorder_grab_strip.dart';
import '../routing_screen_helpers.dart';

/// Один tile custom-rule на табе Rules (spec §030): drag-handle, switch,
/// имя, ☁-статус (опционально), outbound-picker и subtitle. Вся state-логика
/// (download/enable/reorder/edit/delete) живёт в экране и приходит сюда
/// колбэками — поведение идентично исходному `_buildCustomRuleTile`.
class CustomRuleTile extends StatelessWidget {
  const CustomRuleTile({
    super.key,
    required this.index,
    required this.rule,
    required this.options,
    required this.subtitle,
    required this.pickerValue,
    required this.pickerDisabled,
    required this.statusButton,
    required this.onTap,
    required this.onLongPressStart,
    required this.onSwitchChanged,
    required this.onOutboundChanged,
  });

  final int index;
  final CustomRule rule;
  final List<RoutingOutboundOption> options;
  final String subtitle;
  final String pickerValue;
  final bool pickerDisabled;

  /// ☁-кнопка статуса (SRS либо preset) — null если правилу не нужен SRS.
  final Widget? statusButton;

  final VoidCallback onTap;
  final ValueChanged<Offset> onLongPressStart;
  final ValueChanged<bool> onSwitchChanged;
  final ValueChanged<String> onOutboundChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final subtitleColor = rule.enabled ? cs.primary : cs.onSurfaceVariant;

    final content = GestureDetector(
      onTap: onTap,
      onLongPressStart: (d) => onLongPressStart(d.globalPosition),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Switch(
                  value: rule.enabled,
                  onChanged: onSwitchChanged,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(rule.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: rule.enabled ? null : cs.onSurfaceVariant,
                      )),
                ),
                ?statusButton,
                if (pickerDisabled)
                  Icon(Icons.warning_amber_outlined,
                      color: cs.error, size: 18)
                else
                  OutboundPicker(
                    value: pickerValue,
                    options: options
                        .map((o) =>
                            OutboundOption(value: o.tag, label: o.label))
                        .toList(),
                    onChanged: onOutboundChanged,
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 64, bottom: 4),
              child: Row(
                children: [
                  if (rule.kind == CustomRuleKind.preset) ...[
                    Icon(Icons.lock_outline,
                        size: 12, color: subtitleColor),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(subtitle,
                        style:
                            TextStyle(fontSize: 12, color: subtitleColor),
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReorderGrabStrip(index: index),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                content,
                const Divider(height: 1),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
