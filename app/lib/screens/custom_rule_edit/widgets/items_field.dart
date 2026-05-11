import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../normalizers.dart' as norm;

/// §053 Stage 2 — multiline TextField + count badge + Paste/Clear actions.
///
/// `controller` — owned by parent (нужен для save flow). Виджет
/// подписывается через `addListener` для self-rebuild на каждом change
/// (показывать live count). На dispose снимает listener.
///
/// `validator` + `normalize` — для подсветки invalid count. Pure functions
/// из `validators.dart` / `normalizers.dart`.
class ItemsField extends StatefulWidget {
  const ItemsField({
    super.key,
    required this.label,
    required this.controller,
    required this.validator,
    this.normalize,
    this.minLines = 2,
    this.maxLines = 5,
    this.hint,
  });

  final String label;
  final TextEditingController controller;
  final bool Function(String) validator;
  final String Function(String)? normalize;
  final int minLines;
  final int maxLines;
  final String? hint;

  @override
  State<ItemsField> createState() => _ItemsFieldState();
}

class _ItemsFieldState extends State<ItemsField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(covariant ItemsField old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  int get _count => norm.splitRaw(widget.controller.text).length;

  int get _invalidCount {
    var n = 0;
    for (final raw in norm.splitRaw(widget.controller.text)) {
      final v = widget.normalize != null ? widget.normalize!(raw) : raw;
      if (!widget.validator(v)) n++;
    }
    return n;
  }

  Future<void> _pasteInto() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Clipboard is empty')),
      );
      return;
    }
    final existing = widget.controller.text.trim();
    widget.controller.text =
        existing.isEmpty ? text : '$existing\n$text';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final count = _count;
    final invalid = _invalidCount;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  style: t.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
              ),
              Text(
                invalid == 0
                    ? (count == 0 ? '' : '$count')
                    : '$count · $invalid invalid',
                style: TextStyle(
                  fontSize: 12,
                  color: invalid > 0
                      ? t.colorScheme.error
                      : t.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: widget.controller,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              hintText: widget.hint,
              hintStyle: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.content_paste, size: 14),
                label: const Text('Paste',
                    style: TextStyle(fontSize: 12)),
                onPressed: _pasteInto,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.clear, size: 14),
                label: const Text('Clear',
                    style: TextStyle(fontSize: 12)),
                onPressed: () => widget.controller.clear(),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
