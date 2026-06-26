import 'package:flutter/material.dart';

/// §030/new_fields — INBOUND section: фильтр по inbound'у, через который
/// пришёл пакет (`tun-in` — VpnService, `mixed-in` — локальный SOCKS/HTTP
/// прокси, §119). AND с остальным правилом; эмитится на routing-rule level
/// (headless rule_set `inbound` не поддерживает).
///
/// **UX (решение юзера):** секция СВЁРНУТА по умолчанию — одна строка-
/// заголовок с summary справа. Клик раскрывает галочки. Лейблы
/// человекочитаемые, значение = тег билдера ([choices]).
///
/// `mixed-in` появляется в [choices] только когда vpn_mode даёт его реально
/// (proxy/vpn_proxy) — гейт делает контроллер ([CustomRuleEditController.
/// inboundChoices]). В tun-only режиме доступен один `TUN`.
class InboundSection extends StatefulWidget {
  const InboundSection({
    super.key,
    required this.selected,
    required this.choices,
    required this.onToggle,
  });

  /// Выбранные теги (`tun-in`/`mixed-in`).
  final Set<String> selected;

  /// Доступные варианты (`tag` → `label`), уже отфильтрованы по vpn_mode.
  final List<({String tag, String label})> choices;

  final void Function(String tag, bool checked) onToggle;

  @override
  State<InboundSection> createState() => _InboundSectionState();
}

class _InboundSectionState extends State<InboundSection> {
  bool _expanded = false;

  /// Summary свёрнутого заголовка: `any` / лейблы выбранных через запятую.
  /// Для краткости берём первое слово лейбла (TUN / Proxy).
  String get _summary {
    if (widget.selected.isEmpty) return 'any';
    final labels = widget.choices
        .where((c) => widget.selected.contains(c.tag))
        .map((c) => c.label.split(' ').first)
        .toList();
    // Выбранный тег, которого нет в choices (стейл `mixed-in` в tun-only) —
    // показываем сырой тег, чтобы юзер видел что фильтр есть.
    for (final tag in widget.selected) {
      if (!widget.choices.any((c) => c.tag == tag)) labels.add(tag);
    }
    return labels.isEmpty ? 'any' : labels.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'INBOUND',
                        style: t.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: t.colorScheme.primary,
                        ),
                      ),
                      Text(
                        'AND. Which interface the packet came in on.',
                        style: TextStyle(
                          fontSize: 12,
                          color: t.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  _summary,
                  style: TextStyle(
                    fontSize: 13,
                    color: t.colorScheme.onSurfaceVariant,
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: t.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          ...widget.choices.map((c) {
            final checked = widget.selected.contains(c.tag);
            return CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              visualDensity: VisualDensity.compact,
              value: checked,
              onChanged: (v) => widget.onToggle(c.tag, v ?? false),
              title: Text(c.label, style: const TextStyle(fontSize: 14)),
            );
          }),
      ],
    );
  }
}
