import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/custom_rule.dart';
import '../../../services/builder/post_steps.dart';
import '../../../services/builder/preset_expand.dart';
import '../../../services/builder/rule_set_registry.dart';
import '../edit_controller.dart';

/// §053 Stage 3 — View tab: showcase storage JSON + sing-box config preview.
///
/// Подписан на `CustomRuleEditController`. Storage shape = raw `initial`
/// JSON (то что лежит в `lxbox_settings.json`). Sing-box preview =
/// результат `applyCustomRules` или `expandPreset` от `snapshot()`.
class ViewTab extends StatelessWidget {
  const ViewTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = CustomRuleEditScope.of(context);
    final theme = Theme.of(context);

    String json;
    List<String> warnings = const [];
    try {
      if (c.kind == CustomRuleKind.preset) {
        final preset = c.preset;
        if (preset == null) {
          json =
              '// broken preset: "${c.initial.presetId}" — no definition in template';
        } else {
          final snap = c.snapshot();
          // _snapshot() в preset-ветке возвращает CustomRulePreset — cast OK.
          final fragments = expandPreset(
            snap as CustomRulePreset,
            preset,
            srsPaths: c.presetSrsPaths,
          );
          warnings = fragments.warnings;
          json = const JsonEncoder.withIndent('  ').convert({
            'dns_options': {
              'servers': fragments.dnsServers,
              if (fragments.dnsRule != null) 'rules': [fragments.dnsRule],
            },
            'route': {
              'rule_set': fragments.ruleSets,
              if (fragments.routingRule != null)
                'rules': [fragments.routingRule],
            },
          });
        }
      } else {
        final reg = RuleSetRegistry();
        // Всегда подставляем плейсхолдер — чтобы preview отображал
        // структуру даже для не-скачанных srs-правил (юзер видит «что
        // будет» после download'а). Реальный путь живёт в build_config'е
        // runtime'а.
        final srsPaths = <String, String>{};
        if (c.kind == CustomRuleKind.srs) {
          srsPaths[c.initial.id] = c.srsState == SrsDownloadState.cached
              ? '<cached file path>'
              : '<download first>';
        }
        warnings = applyCustomRules(reg, [c.snapshot()], srsPaths: srsPaths);
        json = const JsonEncoder.withIndent('  ').convert({
          'rule_set': reg.getRuleSets(),
          'rules': reg.getRules(),
        });
      }
    } catch (e) {
      json = '// error: $e';
    }

    // Storage shape — raw JSON как лежит в lxbox_settings.json для этого
    // правила (поля initial, не snapshot). Полезно когда юзер хочет
    // видеть что реально сохранено — все поля включая wifi_ssids /
    // wifi_bssids которые могут быть только partially exposed в Params
    // tab UI.
    final storageJson =
        const JsonEncoder.withIndent('  ').convert(c.initial.toJson());

    return Padding(
      padding: EdgeInsets.fromLTRB(
          12, 12, 12, MediaQuery.of(context).padding.bottom + 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ─── Storage shape ───
          Row(
            children: [
              Expanded(
                child: Text('storage shape (lxbox_settings.json)',
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
          // ─── Sing-box config preview ───
          Row(
            children: [
              Expanded(
                child: Text('sing-box config preview',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
              _CopyButton(text: json),
            ],
          ),
          const SizedBox(height: 4),
          if (warnings.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer
                    .withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(warnings.join('\n'),
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.error)),
            ),
            const SizedBox(height: 8),
          ],
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  json,
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
      label: const Text('Copy', style: TextStyle(fontSize: 12)),
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        await Clipboard.setData(ClipboardData(text: text));
        messenger.showSnackBar(
          const SnackBar(content: Text('Copied')),
        );
      },
    );
  }
}
