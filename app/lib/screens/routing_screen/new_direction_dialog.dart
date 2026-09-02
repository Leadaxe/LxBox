import 'package:flutter/material.dart';

import '../../models/direction.dart';
import '../../services/l10n/locale_controller.dart';

/// §393 A3 — диалог создания Направления: один тег.
///
/// Контракт 0.9.0 — второго имени у Направления нет: тег И есть имя. Он же
/// цель правил, и после создания immutable, поэтому спросить его можно ровно
/// здесь и только здесь. Поле преднаполнено первым свободным
/// `vpn-N` ([nextDirectionTag]) — пользователь, которому имя тега безразлично,
/// жмёт Create и получает ровно прежнее поведение.
///
/// Валидация — [directionTagConflict] (единственный источник правды, тот же
/// зовёт storage): пустой / служебный / дубль / тёзка чьего-то `<tag>-auto`.
/// Проверяем на КАЖДЫЙ ввод, а не на Create: тег нельзя переименовать, и
/// узнать об ошибке после создания было бы поздно.
class NewDirectionRequest {
  const NewDirectionRequest({required this.tag});

  /// Системный id нового Направления — он же его имя (контракт 0.9.0).
  final String tag;
}

/// Открывает диалог создания. null — пользователь отменил.
///
/// [existingTags] — теги уже существующих Направлений (для проверки дублей
/// и коллизий с auto-двойниками).
Future<NewDirectionRequest?> showNewDirectionDialog(
  BuildContext context, {
  required List<String> existingTags,
}) {
  return showDialog<NewDirectionRequest>(
    context: context,
    builder: (ctx) => _NewDirectionDialog(existingTags: existingTags),
  );
}

class _NewDirectionDialog extends StatefulWidget {
  const _NewDirectionDialog({required this.existingTags});

  final List<String> existingTags;

  @override
  State<_NewDirectionDialog> createState() => _NewDirectionDialogState();
}

class _NewDirectionDialogState extends State<_NewDirectionDialog> {
  late final TextEditingController _tagCtrl;

  @override
  void initState() {
    super.initState();
    _tagCtrl = TextEditingController(text: nextDirectionTag(widget.existingTags))
      ..addListener(_onChange);
  }

  @override
  void dispose() {
    _tagCtrl.dispose();
    super.dispose();
  }

  void _onChange() => setState(() {});

  /// EN-текст причины отказа по машинному коду [directionTagConflict].
  String? _tagError() {
    final code = directionTagConflict(_tagCtrl.text, widget.existingTags);
    return switch (code) {
      null => null,
      'empty' => getLocalText.s("Tag cannot be empty"),
      'reserved' => getLocalText.s("This tag is reserved by the config"),
      'duplicate' => getLocalText.s("A direction with this tag already exists"),
      _ => getLocalText.s("This tag collides with an auto twin (<tag>-auto)"),
    };
  }

  @override
  Widget build(BuildContext context) {
    final error = _tagError();
    return AlertDialog(
      title: Text(getLocalText.s("New direction")),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _tagCtrl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: getLocalText.s("Tag"),
              helperText: getLocalText.s("System id, cannot be changed later"),
              helperMaxLines: 2,
              errorText: error,
              errorMaxLines: 2,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(getLocalText.s("Cancel")),
        ),
        TextButton(
          onPressed: error != null
              ? null
              : () => Navigator.pop(
                    context,
                    NewDirectionRequest(tag: _tagCtrl.text.trim()),
                  ),
          child: Text(getLocalText.s("Create")),
        ),
      ],
    );
  }
}
