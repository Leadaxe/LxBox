import 'package:flutter/material.dart';

import '../services/l10n/locale_controller.dart';
import '../services/subscription/user_agent.dart';

/// §610 — общий диалог правки Custom User-Agent (глобальная идентичность §118
/// и слепок подписки §289). Поле редактируемое; кнопка у поля открывает
/// список [kUserAgentPresets], выбор пресета подставляет его строку в поле
/// (дальше её можно править руками), «LxBox (default)» очищает поле.
///
/// Результат: `null` — отмена; иначе обрезанная строка, пустая = дефолтный UA.
/// [hint] — подсказка в пустом поле, по умолчанию [resolveSubscriptionUserAgent].
Future<String?> showUserAgentDialog(
  BuildContext context, {
  required String initial,
  String? hint,
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => _UserAgentDialog(initial: initial, hint: hint),
  );
  return result?.trim();
}

/// Контроллер живёт в State диалога: dispose после выходной анимации, а не
/// сразу по возврату из [showDialog] (иначе ассерт «used after disposed»).
class _UserAgentDialog extends StatefulWidget {
  const _UserAgentDialog({required this.initial, this.hint});

  final String initial;
  final String? hint;

  @override
  State<_UserAgentDialog> createState() => _UserAgentDialogState();
}

class _UserAgentDialogState extends State<_UserAgentDialog> {
  late final TextEditingController _ctl = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(getLocalText.s('Custom User-Agent')),
      content: TextField(
        key: const ValueKey('user_agent_field'),
        controller: _ctl,
        autofocus: true,
        maxLines: null,
        decoration: InputDecoration(
          hintText: widget.hint ?? resolveSubscriptionUserAgent(),
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: PopupMenuButton<UserAgentPreset>(
            key: const ValueKey('user_agent_presets'),
            icon: const Icon(Icons.arrow_drop_down),
            tooltip: getLocalText.s('Client presets'),
            onSelected: (p) {
              _ctl.value = TextEditingValue(
                text: p.value,
                selection: TextSelection.collapsed(offset: p.value.length),
              );
            },
            itemBuilder: (_) => [
              for (final p in kUserAgentPresets)
                PopupMenuItem<UserAgentPreset>(
                  value: p,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: p.value.isEmpty
                        ? Text(getLocalText.s('LxBox (default)'))
                        // l10n-exempt: client brand name
                        : Text(p.label),
                    subtitle: p.value.isEmpty
                        ? null
                        // l10n-exempt: wire User-Agent string
                        : Text(
                            p.value,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(getLocalText.s('Cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctl.text),
          child: Text(getLocalText.s('Save')),
        ),
      ],
    );
  }
}
