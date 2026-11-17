import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/l10n/locale_controller.dart';

/// §048 — UI components для filter panel в node list header.
/// Все слим, compact, default collapsed (см. spec).

/// §096 — компактный `!`-тогл инверсии (negate). Серый = обычный фильтр,
/// bold-красный = инверсия (показать НЕ совпадающие/выбранные). Единый
/// визуальный язык для regex / protocol / subscriptions / detour.
class NegateToggle extends StatelessWidget {
  const NegateToggle({
    super.key,
    required this.active,
    required this.onToggle,
    this.tooltip,
  });

  final bool active;
  final VoidCallback onToggle;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final w = InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 30,
        height: 30,
        child: Center(
          child: Text(
            '!',
            style: TextStyle(
              fontSize: 17,
              fontWeight: active ? FontWeight.bold : FontWeight.normal,
              color: active ? cs.error : cs.onSurfaceVariant.withAlpha(140),
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? w : Tooltip(message: tooltip!, child: w);
  }
}

/// Slim TextField для regex pattern. Слева — `!`-negate ([NegateToggle], §096:
/// занял слот бывшей enable-галки); внутри prefix — лупа, suffix — `✕ clear`
/// (виден когда поле непустое). Regex активен пока поле непустое (выключение =
/// очистка). `errorText` («Invalid regex») — всегда при битом паттерне.
class RegexFilterField extends StatelessWidget {
  const RegexFilterField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.valid,
    required this.invert,
    required this.onInvertToggle,
    this.onClear,
    this.onSaveRegex,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final bool valid;
  final bool invert;
  final VoidCallback onInvertToggle;
  final VoidCallback? onClear;

  /// §195/§197 — сохранить текущий regex (+инверсию) в активное Направление.
  /// `null` → кнопка 💾 скрыта (нет активного Направления). Показывается только при
  /// непустом валидном паттерне.
  final void Function(String pattern, bool invert)? onSaveRegex;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // top:4 — иначе тогл центрируется ОТ всей высоты row (включая
          // errorText) и съезжает вниз когда regex invalid.
          padding: const EdgeInsets.only(top: 4),
          child: NegateToggle(
            active: invert,
            onToggle: onInvertToggle,
            tooltip: getLocalText.s("Show NON-matching"),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
              hintText: getLocalText.s("regex pattern"),
              // §096 — invert переехал в ведущий [!] (NegateToggle слева от
              // поля); внутри prefix остаётся только лупа.
              prefixIcon: const SizedBox(
                width: 30,
                height: 28,
                child: Center(child: Icon(Icons.search, size: 18)),
              ),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 34, minHeight: 28),
              errorText: valid ? null : 'Invalid regex',
              errorStyle: const TextStyle(fontSize: 10),
              // §195 — суффикс: [💾 save] + [× clear], оба только при непустом
              // тексте. 💾 — лишь если onSaveRegex задан (есть активное Направление) И
              // regex валиден (битый паттерн сохранять нельзя). Каждый — голый
              // SizedBox 28×28, без material 48dp tap-target → suffix не прыгает.
              suffixIcon: controller.text.isEmpty
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (onSaveRegex != null && valid)
                          InkWell(
                            onTap: () => onSaveRegex!(controller.text, invert),
                            borderRadius: BorderRadius.circular(4),
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: Icon(Icons.save_outlined,
                                  size: 17,
                                  color: cs.onSurfaceVariant.withAlpha(200)),
                            ),
                          ),
                        InkWell(
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
                      ],
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

/// Horizontal scroll row с emoji chips. Tap chip → toggle emoji в regex
/// OR-паттерне; выбранные (присутствующие в паттерне) — подсвечены
/// ([selected]), повторный tap снимает.
class EmojiChipsRow extends StatelessWidget {
  const EmojiChipsRow({
    super.key,
    required this.emojis,
    required this.onTap,
    this.selected = const <String>{},
  });

  final List<String> emojis;
  final ValueChanged<String> onTap;
  final Set<String> selected;

  @override
  Widget build(BuildContext context) {
    if (emojis.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: emojis.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (_, i) {
          final e = emojis[i];
          return FilterChip(
            label: Text(e, style: const TextStyle(fontSize: 14)),
            selected: selected.contains(e),
            showCheckmark: false,
            onSelected: (_) => onTap(e),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
    required this.invert,
    required this.onInvertToggle,
  });

  /// Список `(id, label)` пар. `id` хранится в [enabled], `label` —
  /// текстовая подпись на chip.
  final List<(String id, String label)> options;
  final Set<String> enabled;
  final ValueChanged<String> onToggle;

  /// §096 — invert (NOT) всей категории + тогл. Ведущий [NegateToggle].
  final bool invert;
  final VoidCallback onInvertToggle;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        NegateToggle(
          active: invert,
          onToggle: onInvertToggle,
          tooltip: getLocalText.s("Show NON-selected"),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: SizedBox(
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
          ),
        ),
      ],
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
        Text(getLocalText.s("Test ≤"), style: const TextStyle(fontSize: 12)),
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
        // l10n-exempt: 'ms' — латинская единица в обеих локалях (spec §5)
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
