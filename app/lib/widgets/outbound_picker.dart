import 'package:flutter/material.dart';

import '../models/custom_rule.dart' show kOutboundReject;
import '../services/l10n/locale_controller.dart';

/// §683 — служебное значение пункта «Resolve only» в [OutboundPicker]
/// (не тег outbound; редактор правила переводит его в `resolve.only`).
const String kResolveOnlyAction = '__resolve_only__';

/// Опция в [OutboundPicker] — либо outbound tag, либо sentinel "reject".
class OutboundOption {
  const OutboundOption({required this.value, required this.label});
  final String value;  // tag (e.g. "vpn-1", "direct-out") или `kOutboundReject`
  final String label;  // human-readable: "vpn-1", "direct-out", "Reject"

  static const reject =
      OutboundOption(value: kOutboundReject, label: 'Reject');
}

/// Унифицированный dropdown для выбора **куда маршрутизировать** правило
/// (App Rule / Custom Rule). Выбор — либо outbound tag, либо "Reject (block)".
///
/// Reject обозначается иконкой `Icons.block` + `colorScheme.error` цветом,
/// отделяется divider'ом от обычных outbound'ов. Включается флагом
/// [allowReject]; для мест где reject не применим (selectable preset rules)
/// — передай `false`.
class OutboundPicker extends StatelessWidget {
  const OutboundPicker({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.allowReject = true,
    this.allowResolveOnly = false,
    this.dense = true,
    this.label = 'Action',
    this.width,
  });

  final String value;
  final List<OutboundOption> options;
  final ValueChanged<String> onChanged;
  final bool allowReject;

  /// §683 — пункт «Resolve only» после Reject (редактор правила, только
  /// правила с доменами / srs).
  final bool allowResolveOnly;

  /// `true` — compact underline-style для inline использования в строках
  /// списка (App Routing row, Domain/IP Routing row). `false` — full form
  /// field с outline border + labelText + нормальный шрифт для edit-экранов.
  final bool dense;

  /// Label для form-field варианта (`dense: false`). Игнорируется при dense.
  final String label;

  /// Фиксированная ширина для compact варианта. Для non-dense — Expanded рядом.
  final double? width;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fontSize = dense ? 13.0 : 15.0;
    final iconSize = dense ? 14.0 : 18.0;

    final items = <DropdownMenuItem<String>>[];
    for (final o in options) {
      items.add(DropdownMenuItem(
        value: o.value,
        child: Text(o.label, style: TextStyle(fontSize: fontSize)),
      ));
    }
    if (allowReject) {
      items.add(DropdownMenuItem(
        value: kOutboundReject,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, size: iconSize, color: cs.error),
            const SizedBox(width: 6),
            Text(getLocalText.s("Reject"),
                style: TextStyle(fontSize: fontSize, color: cs.error)),
          ],
        ),
      ));
    }

    if (allowResolveOnly) {
      items.add(DropdownMenuItem(
        value: kResolveOnlyAction,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.travel_explore, size: iconSize, color: cs.primary),
            const SizedBox(width: 6),
            Text(getLocalText.s("Resolve only"),
                style: TextStyle(fontSize: fontSize)),
          ],
        ),
      ));
    }

    // Fallback: если текущее value отсутствует в options (удалили group),
    // показываем первый вариант чтобы dropdown не сломался. §219 — это ТОЛЬКО
    // визуальная защита от краша: хранимое value здесь НЕ меняется (виджет
    // презентационный, onChanged дёргается лишь на явный выбор юзера). Целостность
    // висячих ссылок на удалённое Направление обеспечивается проактивно на
    // storage-уровне: `_healDirectionRefs` (§202) переводит route_final / custom-rule
    // outbound на vpn-1 при удалении Направления.
    final effectiveValue = items.any((i) => i.value == value)
        ? value
        : (options.isNotEmpty ? options.first.value : kOutboundReject);

    if (!dense) {
      return DropdownButtonFormField<String>(
        initialValue: effectiveValue,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: false,
        ),
        items: items,
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      );
    }

    final widget = DropdownButton<String>(
      value: effectiveValue,
      isDense: true,
      isExpanded: width != null,
      items: items,
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
    return width != null ? SizedBox(width: width, child: widget) : widget;
  }
}
