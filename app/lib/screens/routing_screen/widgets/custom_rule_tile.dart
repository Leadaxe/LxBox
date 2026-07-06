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
    this.showOutbound = true,
    this.touchesDns = false,
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

  /// Рисовать ли outbound-picker. False для DNS-only пресетов (напр. FakeIP),
  /// которым нечего роутить — picker был бы мёртвым (см.
  /// [SelectableRule.hasOutboundAffordance]).
  final bool showOutbound;

  /// §231 — правило вносит изменения в DNS (DNS-сервер/правило). Рисует чип
  /// «DNS» рядом с именем: глядя на список, видно, что правило связано с DNS
  /// Settings. Пресет → `SelectableRule.touchesDns`; inline/srs →
  /// `CustomRule.dnsMirrorActive`.
  final bool touchesDns;

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
                if (!showOutbound)
                  const SizedBox.shrink()
                else if (pickerDisabled)
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
              padding: const EdgeInsets.only(left: 64, right: 8, bottom: 4),
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
                  // §247 — значок ✳: у правила resolve-опция (action сложнее
                  // простого outbound). Просто маркер, деталей в списке нет.
                  if (rule.resolveActive) ...[
                    const SizedBox(width: 6),
                    Text('✳',
                        style: TextStyle(
                            fontSize: 12,
                            color: rule.enabled
                                ? cs.primary
                                : cs.onSurfaceVariant)),
                  ],
                  // §231 — чип «DNS» справа на нижней строке, под outbound-пикером.
                  if (touchesDns) ...[
                    const SizedBox(width: 6),
                    _dnsChip(cs, rule.enabled),
                  ],
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

  /// §231 — компактный бейдж «DNS»: правило трогает DNS-настройки. Приглушён,
  /// когда правило выключено.
  Widget _dnsChip(ColorScheme cs, bool enabled) {
    final c = enabled ? cs.primary : cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: c.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dns_outlined, size: 12, color: c),
          const SizedBox(width: 3),
          Text('DNS',
              style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w600, color: c)),
        ],
      ),
    );
  }
}
