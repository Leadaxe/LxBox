import 'package:flutter/material.dart';

import '../edit_controller.dart';
import '../sections/dns_resolve_section.dart';
import '../../../services/l10n/locale_controller.dart';

/// §757 — вкладка DNS окна своего правила (как вкладка DNS окна правила
/// лаунчера): блок «DNS & Resolve» без изменений. Блок недоступен (нет
/// условия, видимого DNS-слою, или правило — только JSON) — вкладка
/// остаётся и объясняет почему.
class DnsTab extends StatelessWidget {
  const DnsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = CustomRuleEditScope.of(context);
    final theme = Theme.of(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
      children: [
        if (c.dnsSectionVisible)
          DnsResolveSection(controller: c)
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  c.jsonMode
                      ? getLocalText.s(
                          "DNS options are set in the form. This rule can only be edited as JSON.")
                      : getLocalText.s(
                          "DNS options do not apply to this rule: it has no condition DNS queries can match, such as domains, apps or a rule set."),
                  style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
