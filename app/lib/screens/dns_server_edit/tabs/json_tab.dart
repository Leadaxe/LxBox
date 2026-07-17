import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/builder/post_steps.dart'
    show resolveTemplateDnsServerBody;
import '../../../services/builder/preset_expand.dart' show normalizeDnsDetour;
import '../../../services/l10n/l10n.dart';
import '../../dns_settings_screen/resolved_server.dart';
import '../edit_controller.dart';

/// §117 задача 4 — JSON tab редактора DNS-сервера (locked decision №9):
///
/// - `inline` → **редактируемое** тело (sing-box JSON без tag/description/
///   enabled — они на ref-level). Тело — источник правды inline-сервера;
///   парс/strip на каждый edit живёт в контроллере, невалидный JSON
///   блокирует save;
/// - `template`/`preset` → **read-only** превью отрезолвленного тела
///   (с текущими varValues, detour нормализован — display = emit) +
///   storage-shape ref-записи + Copy (паттерн `ViewTab`).
class DnsServerJsonTab extends StatelessWidget {
  const DnsServerJsonTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = DnsServerEditScope.of(context);
    if (c.kind == ServerKind.inline) return _InlineBodyEditor(c: c);
    return _ReadOnlyPreview(c: c);
  }
}

class _InlineBodyEditor extends StatelessWidget {
  const _InlineBodyEditor({required this.c});
  final DnsServerEditController c;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          12, 12, 12, MediaQuery.of(context).padding.bottom + 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            c.isNew ? context.l.dnsJsonHeaderNew : context.l.dnsJsonHeaderEdit,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: TextField(
              controller: c.bodyCtrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                isDense: true,
                errorText: c.jsonError,
              ),
              onChanged: c.onBodyTextChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadOnlyPreview extends StatelessWidget {
  const _ReadOnlyPreview({required this.c});
  final DnsServerEditController c;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Отрезолвленное тело с ТЕКУЩИМИ значениями формы (live: поменял var в
    // Params → превью обновилось). Display = emit-форма (detour normalized).
    String resolvedJson;
    final wrapper = c.templateWrapper;
    if (c.kind == ServerKind.template && wrapper != null) {
      final body = resolveTemplateDnsServerBody(wrapper, varValues: c.varValues);
      if (body == null) {
        resolvedJson = '// malformed template wrapper';
      } else {
        normalizeDnsDetour(body);
        body['tag'] = c.resolved?.tag ?? '';
        resolvedJson = const JsonEncoder.withIndent('  ').convert(body);
      }
    } else {
      resolvedJson = const JsonEncoder.withIndent('  ')
          .convert(c.resolved?.body ?? const {});
    }

    final storageJson =
        const JsonEncoder.withIndent('  ').convert(c.snapshot());

    return Padding(
      padding: EdgeInsets.fromLTRB(
          12, 12, 12, MediaQuery.of(context).padding.bottom + 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ─── Storage shape ───
          Row(
            children: [
              Expanded(
                child: Text(context.l.ruleEditViewStorageShape,
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
              _CopyButton(text: storageJson),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            constraints: const BoxConstraints(maxHeight: 180),
            child: SingleChildScrollView(
              child: SelectableText(
                storageJson,
                style:
                    const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // ─── Resolved sing-box body ───
          Row(
            children: [
              Expanded(
                child: Text(context.l.dnsJsonPreviewLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
              _CopyButton(text: resolvedJson),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  resolvedJson,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      icon: const Icon(Icons.content_copy, size: 14),
      label: Text(context.l.commonCopy, style: const TextStyle(fontSize: 12)),
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        final copied = context.l.commonCopied;
        await Clipboard.setData(ClipboardData(text: text));
        messenger.showSnackBar(
          SnackBar(content: Text(copied)),
        );
      },
    );
  }
}
