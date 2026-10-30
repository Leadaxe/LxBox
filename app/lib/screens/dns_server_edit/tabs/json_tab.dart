import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/codec/dns_record.dart' show dnsServerToRecord;
import '../../../services/builder/post_steps.dart'
    show previewDnsGroupMembers;
import '../../../services/builder/preset_expand.dart' show normalizeDnsDetour;
import '../../dns_settings_screen/resolved_server.dart';
import '../edit_controller.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../../widgets/lx_code_editor.dart';

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
      // §614/§624 — редактор JSON с подсветкой и поиском; подпись — слева
      // в строке кнопок поля (поиск, Format).
      child: LxTextCodeField(
        controller: c.bodyCtrl,
        errorText: c.jsonError,
        onChanged: c.onBodyTextChanged,
        header: Text(
          c.isNew ? getLocalText.s("sing-box server JSON — tag editable here or in Params; description/enabled live on the list entry") : getLocalText.s("sing-box server JSON — tag locked while editing; description/enabled live on the list entry"),
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
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
    // Params → превью обновилось). Display = emit-форма (detour normalized,
    // §671 — у группы выключенные члены сняты тем же критерием, что у сборки).
    var skipped = const <String>[];
    final wrapper = c.templateWrapper;
    final Map<String, dynamic> body;
    if (c.kind == ServerKind.template && wrapper != null) {
      // §695 — тело формы: vars подставлены, правки формы поверх.
      body = c.currentResolvedBody();
      normalizeDnsDetour(body);
      body['tag'] = c.resolved?.tag ?? '';
    } else {
      body = Map<String, dynamic>.from(c.resolved?.body ?? const {});
    }
    if (body['type'] == 'group' && body['servers'] is List) {
      final members = previewDnsGroupMembers(
        [for (final m in body['servers'] as List) m?.toString() ?? ''],
        selfTag: c.resolved?.tag ?? body['tag']?.toString() ?? '',
        emittedByTag: {
          for (final o in c.dnsMemberOptions) o.tag: o.enabled,
        },
      );
      body['servers'] = members.kept;
      skipped = members.disabled;
    }
    final resolvedJson = const JsonEncoder.withIndent('  ').convert(body);

    // Запись хранения — кодеком (§439: у DnsServerRef нет toJson; модель в
    // JsonEncoder напрямую — «Converting object to an encodable object
    // failed», #143).
    final storageJson = const JsonEncoder.withIndent('  ')
        .convert(dnsServerToRecord(c.snapshot()));

    return Padding(
      padding: EdgeInsets.fromLTRB(
          12, 12, 12, MediaQuery.of(context).padding.bottom + 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ─── Storage shape ───
          // Подпись и Copy — в строке над рамкой просмотрщика; JSON с
          // подсветкой, как у остальных JSON-полей (§624).
          LxJsonView(
            text: storageJson,
            height: 180,
            header: Text(getLocalText.s("storage shape (lxbox_settings.json)"),
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
            actions: [_CopyButton(text: storageJson)],
          ),
          const SizedBox(height: 12),
          // ─── Resolved sing-box body ───
          Expanded(
            child: LxJsonView(
              text: resolvedJson,
              header: Text(getLocalText.s("sing-box server preview (read-only)"),
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
              actions: [_CopyButton(text: resolvedJson)],
            ),
          ),
          if (skipped.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              getLocalText.s(
                  "Disabled, skipped at build: %s", skipped.join(', ')),
              style: TextStyle(fontSize: 11, color: theme.colorScheme.error),
            ),
          ],
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
      label: Text(getLocalText.s("Copy"), style: const TextStyle(fontSize: 12)),
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        final copied = getLocalText.s("Copied");
        await Clipboard.setData(ClipboardData(text: text));
        messenger.showSnackBar(
          SnackBar(content: Text(copied)),
        );
      },
    );
  }
}
