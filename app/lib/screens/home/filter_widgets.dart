import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// §048 — UI components для filter panel в node list header.
/// Все слим, compact, default collapsed (см. spec).

/// Slim TextField для regex pattern с двумя toggle:
///   • **слева**: `enabled` — on/off фильтра, не теряя pattern (как у Test ≤).
///     Auto-on при вводе валидного pattern.
///   • **внутри suffix**: `[!]` — invert/NOT. Default off (muted), tap →
///     bold red, regex matchает инвертно (`!hasMatch`). Виден только когда
///     поле не пустое (рядом с `✕ clear`).
///
/// `errorText` («Invalid regex») показывается всегда когда pattern сломан
/// (независимо от enabled — pattern всё равно битый и юзеру нужен фидбек).
class RegexFilterField extends StatelessWidget {
  const RegexFilterField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.valid,
    required this.enabled,
    required this.onEnabledChanged,
    required this.invert,
    required this.onInvertChanged,
    this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final bool valid;
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;
  final bool invert;
  final ValueChanged<bool> onInvertChanged;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // top:4 — иначе checkbox центрируется ОТ всей высоты row (включая
          // errorText) и съезжает вниз когда regex invalid.
          padding: const EdgeInsets.only(top: 4),
          child: SizedBox(
            width: 28,
            height: 28,
            child: Checkbox(
              value: enabled,
              onChanged: (v) => onEnabledChanged(v ?? false),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            decoration: InputDecoration(
              isDense: true,
              // Asymmetric padding: left 4 (prefix уже даёт визуальный
              // отступ от [!]), right 12 (привычный gap до ×).
              contentPadding:
                  const EdgeInsets.fromLTRB(4, 8, 12, 8),
              hintText: 'regex pattern',
              // [!] 🔍 — invert toggle первым, потом лупа. Discoverability:
              // [!] видно всегда. Голые SizedBox (без material tap-target),
              // чтобы row не распирал высоту поля. [!] узкий (20×28),
              // tight visual.
              prefixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    onTap: () => onInvertChanged(!invert),
                    borderRadius: BorderRadius.circular(4),
                    child: SizedBox(
                      width: 20,
                      height: 28,
                      child: Center(
                        child: Text(
                          '!',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: invert
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: invert
                                ? cs.error
                                : cs.onSurfaceVariant.withAlpha(140),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(
                    width: 20,
                    height: 28,
                    child: Center(child: Icon(Icons.search, size: 18)),
                  ),
                ],
              ),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 40, minHeight: 28),
              errorText: valid ? null : 'Invalid regex',
              errorStyle: const TextStyle(fontSize: 10),
              // ✕ — только когда есть text. Текстовый символ (не
              // Icons.clear) — голый SizedBox 28×28, без material 48dp
              // tap-target → suffix не прыгает в высоту.
              suffixIcon: controller.text.isEmpty
                  ? null
                  : InkWell(
                      onTap: onClear,
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: Center(
                          child: Text(
                            '×',
                            style: TextStyle(
                              fontSize: 18,
                              color: cs.onSurfaceVariant.withAlpha(180),
                            ),
                          ),
                        ),
                      ),
                    ),
              suffixIconConstraints:
                  const BoxConstraints(minWidth: 32, minHeight: 28),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
  }
}

/// Horizontal scroll row с emoji chips. Tap chip → callback вставляет emoji
/// в regex field (append).
class EmojiChipsRow extends StatelessWidget {
  const EmojiChipsRow({
    super.key,
    required this.emojis,
    required this.onTap,
  });

  final List<String> emojis;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    if (emojis.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: emojis.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (_, i) {
          final e = emojis[i];
          return ActionChip(
            label: Text(e, style: const TextStyle(fontSize: 14)),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onPressed: () => onTap(e),
          );
        },
      ),
    );
  }
}

/// Horizontal scroll row с `FilterChip`'ами. Multi-select: tap → toggle.
/// Empty set = no filter. Не переносит на следующую строку — все chips в
/// одной полоске со скроллом (как `EmojiChipsRow`).
class MultiSelectChipsRow extends StatelessWidget {
  const MultiSelectChipsRow({
    super.key,
    required this.options,
    required this.enabled,
    required this.onToggle,
  });

  /// Список `(id, label)` пар. `id` хранится в [enabled], `label` —
  /// текстовая подпись на chip.
  final List<(String id, String label)> options;
  final Set<String> enabled;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final (id, label) = options[i];
          return FilterChip(
            label: Text(label, style: const TextStyle(fontSize: 11)),
            selected: enabled.contains(id),
            onSelected: (_) => onToggle(id),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 6),
          );
        },
      ),
    );
  }
}

/// `[☐] Test ≤ [N] ms` numeric input с checkbox для on/off. Checkbox
/// позволяет временно выключить filter не теряя значение.
class PingFilterField extends StatelessWidget {
  const PingFilterField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.enabled,
    required this.onEnabledChanged,
    this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 28,
          height: 28,
          child: Checkbox(
            value: enabled,
            onChanged: (v) => onEnabledChanged(v ?? false),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        const SizedBox(width: 4),
        const Text('Test ≤', style: TextStyle(fontSize: 12)),
        const SizedBox(width: 8),
        SizedBox(
          width: 80,
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              hintText: '200',
              hintStyle: const TextStyle(fontSize: 12),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
            ),
            style: const TextStyle(fontSize: 13),
          ),
        ),
        const SizedBox(width: 6),
        const Text('ms', style: TextStyle(fontSize: 12)),
        if (controller.text.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear, size: 16),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            visualDensity: VisualDensity.compact,
            onPressed: onClear,
          ),
      ],
    );
  }
}

/// Compact checkbox-like switch row. Используется для `Show detour servers`
/// и `Show non-matching (dimmed)`.
class FilterCheckboxRow extends StatelessWidget {
  const FilterCheckboxRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: Checkbox(
                value: value,
                onChanged: (v) => onChanged(v ?? false),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
