import 'package:flutter/material.dart';

import '../../../widgets/outbound_picker.dart';
import '../../../widgets/template_var_list.dart';
import '../../dns_settings_screen/resolved_server.dart';
import '../edit_controller.dart';
import '../sections/server_form_section.dart';

/// §117 задача 4 — Params tab редактора DNS-сервера. Состав по `kind`:
///
/// - общее: Description + Enabled (при locked — disabled, показан ON,
///   пометка «used by <пресет/правило>»);
/// - `template` → [TemplateVarListView] (vars: outbound/enum/dns_servers/…) —
///   перенос инлайн-тюнера с тайла, логика `varValues` без изменений;
/// - `inline` → Tag (locked при edit existing) + Outbound (detour)
///   [OutboundPicker] → пишет/стирает `body['detour']` (inline-detour,
///   locked decision №10);
/// - `preset` → read-only пометка (параметры живут в редакторе пресета).
class DnsServerParamsTab extends StatelessWidget {
  const DnsServerParamsTab({super.key, required this.onSave});

  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final c = DnsServerEditScope.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return ListView(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).padding.bottom + 24),
      children: [
        if (c.kind == ServerKind.inline) ...[
          TextField(
            controller: c.tagCtrl,
            decoration: InputDecoration(
              labelText: 'Tag',
              border: const OutlineInputBorder(),
              isDense: true,
              prefixIcon: const Icon(Icons.tag, size: 18),
              helperText: c.isNew
                  ? 'Unique id — referenced by DNS rules / resolvers'
                  // §117 задача 4b: rename каскадно обновляет все ссылки
                  // (DNS-правила, resolvers, domain_resolver'ы).
                  : 'Renaming updates all references automatically',
            ),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: c.descCtrl,
          decoration: const InputDecoration(
            labelText: 'Description',
            border: OutlineInputBorder(),
            isDense: true,
            prefixIcon: Icon(Icons.label_outline, size: 18),
          ),
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Enabled'),
          // §117 lifecycle (locked №7): реферимый сервер force-include'ится
          // build'ом — показываем ON, тоггл заблокирован.
          subtitle: c.locked
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline, size: 14, color: cs.primary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text('used by ${c.lockedByLabel}',
                          style: TextStyle(fontSize: 12, color: cs.primary)),
                    ),
                  ],
                )
              : null,
          value: c.enabled || c.locked,
          onChanged: c.locked ? null : c.setEnabled,
        ),
        const Divider(),
        switch (c.kind) {
          ServerKind.template => TemplateVarListView(
              key: ValueKey('dns-edit-vars-${c.resolved?.tag ?? ''}'),
              vars: c.vars,
              initialValues: c.varValues,
              showSectionHeaders: false,
              outboundOptions: c.outboundOptions,
              dnsServerTags: c.dnsServerTags,
              onChanged: c.setVarValue,
            ),
          // §117 задача 4b: структурная форма (UDP/DoT/DoH + адрес/порт/
          // path/SNI/domain_resolver) + detour-пикер.
          ServerKind.inline => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ServerFormSection(c: c),
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Outbound (detour)',
                          style: theme.textTheme.bodyLarge),
                      const SizedBox(height: 2),
                      Text(
                        'Which channel carries DNS queries to this server. '
                        'Direct — no detour key in the config.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(height: 8),
                      OutboundPicker(
                        value: c.inlineDetour,
                        options: c.outboundOptions,
                        allowReject: false,
                        onChanged: c.setInlineDetour,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ServerKind.preset => Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.push_pin_outlined, size: 16, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Registered by preset '
                      '"${c.resolved?.presetLabel ?? ''}". Parameters are '
                      'edited in the preset rule (Routing → Rules).',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
        },
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.save, size: 18),
          label: const Text('Save'),
          onPressed: onSave,
        ),
      ],
    );
  }
}
