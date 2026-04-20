import 'dart:math';

import 'package:flutter/material.dart';

import '../models/parser_config.dart';

/// Рендерит список [WizardVar] с секция-заголовками и типизированными
/// контролами:
///
/// - `bool` → [SwitchListTile]
/// - `enum` → [DropdownButton]
/// - `secret` → text-input с обфускацией + eye-toggle + кнопка Generate
/// - `text` → text-input; при наличии `options` — combo с suffix-▾ popup'ом
///   пресетов. Юзер может и выбрать preset, и напечатать своё.
///
/// Stateful — держит локальную копию значений; parent получает коллбэк
/// `onChanged(name, value)` на каждое изменение и сам персистит.
///
/// Используется:
/// - `settings_screen.dart` — chapter: core (sing-box низкоуровневое)
/// - `routing_screen.dart` — chapter: routing (Auto Proxy)
class TemplateVarListView extends StatefulWidget {
  const TemplateVarListView({
    super.key,
    required this.vars,
    required this.initialValues,
    required this.onChanged,
    this.sectionDescriptions = const {},
    this.showSectionHeaders = true,
  });

  /// Переменные для рендеринга. Порядок и секции сохраняются.
  final List<WizardVar> vars;

  /// Стартовые значения (`{name: value}`). Отсутствующие → `v.defaultValue`.
  final Map<String, String> initialValues;

  /// Вызывается на каждое изменение. Parent ответственен за persist.
  final void Function(String name, String value) onChanged;

  /// Описания секций по title — для подзаголовков. Пусто → без описания.
  final Map<String, String> sectionDescriptions;

  /// Показывать ли section-заголовки. false — если parent сам рисует
  /// заголовок (например, routing_screen показывает одну секцию под своей
  /// шапкой).
  final bool showSectionHeaders;

  @override
  State<TemplateVarListView> createState() => _TemplateVarListViewState();
}

class _TemplateVarListViewState extends State<TemplateVarListView> {
  late final Map<String, String> _values;

  @override
  void initState() {
    super.initState();
    _values = {
      for (final v in widget.vars)
        v.name: widget.initialValues[v.name] ?? v.defaultValue,
    };
  }

  void _update(String name, String value) {
    setState(() => _values[name] = value);
    widget.onChanged(name, value);
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    String lastSection = '';

    for (final v in widget.vars) {
      if (widget.showSectionHeaders &&
          v.section.isNotEmpty &&
          v.section != lastSection) {
        lastSection = v.section;
        if (children.isNotEmpty) children.add(const SizedBox(height: 16));
        children.add(_buildSectionHeader(context, v.section));
      }
      children.add(_buildVarWidget(v));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    final desc = widget.sectionDescriptions[title] ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
          ),
          if (desc.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                desc,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          const Divider(),
        ],
      ),
    );
  }

  Widget _buildVarWidget(WizardVar v) {
    switch (v.type) {
      case 'bool':
        return SwitchListTile(
          title: Text(v.title.isNotEmpty ? v.title : v.name),
          subtitle: v.tooltip.isNotEmpty
              ? Text(v.tooltip, style: const TextStyle(fontSize: 12))
              : null,
          value: _values[v.name] == 'true',
          onChanged: (val) => _update(v.name, val.toString()),
        );

      case 'enum':
        return _LabelledField(
          label: v.title.isNotEmpty ? v.title : v.name,
          tooltip: v.tooltip,
          field: DropdownButton<String>(
            isExpanded: true,
            value: v.options.contains(_values[v.name])
                ? _values[v.name]
                : v.defaultValue,
            items: v.options
                .map((o) => DropdownMenuItem(value: o, child: Text(o)))
                .toList(),
            onChanged: (val) {
              if (val == null) return;
              _update(v.name, val);
            },
          ),
        );

      case 'secret':
        return _VarTextField(
          key: ValueKey('secret-${v.name}'),
          value: _values[v.name] ?? '',
          obscure: true,
          label: v.title.isNotEmpty ? v.title : v.name,
          tooltip: v.tooltip,
          onChanged: (val) => _update(v.name, val),
          trailing: IconButton(
            tooltip: 'Generate random',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: () {
              final rng = Random.secure();
              final bytes = List.generate(16, (_) => rng.nextInt(256));
              final hex =
                  bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
              _update(v.name, hex);
            },
          ),
        );

      default:
        // text: если есть options — добавляется combo-popup ▾ с пресетами.
        final hasSuggestions = v.options.isNotEmpty;
        return _VarTextField(
          key: ValueKey('text-${v.name}'),
          value: _values[v.name] ?? '',
          width: hasSuggestions ? 220 : 180,
          label: v.title.isNotEmpty ? v.title : v.name,
          tooltip: v.tooltip,
          suggestions: v.options,
          onChanged: (val) => _update(v.name, val),
        );
    }
  }
}

/// Self-contained text-input для template-переменных. Владеет
/// TextEditingController'ом — без leak'а при rebuild'ах parent'а.
///
/// Поддерживает:
/// - `obscure` — скрывает ввод + eye-toggle справа (для `secret`)
/// - `trailing` — внешний виджет справа от поля (например, Generate-кнопка)
/// - `suggestions` — список пресетов; suffix-▾ открывает popup с ✓ на
///   текущем значении. Совместим только с `!obscure` (для secrets
///   пресетов нет).
class _VarTextField extends StatefulWidget {
  const _VarTextField({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
    this.tooltip = '',
    this.obscure = false,
    this.width = 180,
    this.trailing,
    this.suggestions = const [],
  });

  final String value;
  final String label;
  final String tooltip;
  final void Function(String) onChanged;
  final bool obscure;
  final double width;
  final Widget? trailing;
  final List<String> suggestions;

  @override
  State<_VarTextField> createState() => _VarTextFieldState();
}

class _VarTextFieldState extends State<_VarTextField> {
  late final TextEditingController _ctrl;
  late bool _obscured;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
    _obscured = widget.obscure;
  }

  @override
  void didUpdateWidget(covariant _VarTextField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value && widget.value != _ctrl.text) {
      _ctrl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _applySuggestion(String v) {
    _ctrl.text = v;
    _ctrl.selection = TextSelection.collapsed(offset: v.length);
    widget.onChanged(v);
  }

  Widget? _buildSuffix() {
    if (widget.obscure) {
      return IconButton(
        icon: Icon(
          _obscured ? Icons.visibility_off : Icons.visibility,
          size: 18,
        ),
        onPressed: () => setState(() => _obscured = !_obscured),
      );
    }
    if (widget.suggestions.isEmpty) return null;
    return PopupMenuButton<String>(
      tooltip: 'Presets',
      icon: const Icon(Icons.arrow_drop_down),
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: _applySuggestion,
      itemBuilder: (ctx) => [
        for (final s in widget.suggestions)
          PopupMenuItem<String>(
            value: s,
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  child: s == _ctrl.text
                      ? const Icon(Icons.check, size: 18)
                      : null,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    s,
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: _ctrl,
      obscureText: _obscured,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        suffixIcon: _buildSuffix(),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 32,
          minHeight: 32,
        ),
      ),
      onChanged: widget.onChanged,
    );

    return _LabelledField(
      label: widget.label,
      tooltip: widget.tooltip,
      field: widget.trailing != null
          ? Row(children: [
              Expanded(child: field),
              widget.trailing!,
            ])
          : field,
    );
  }
}

/// Layout-helper для form-полей в template_var_list:
/// label сверху, описание под ним, контрол на отдельной строке слева.
/// Без `ListTile` — тот зажимал label/описание в боковую колонку, на узких
/// экранах "Test URL" разваливалось на "Test"/"URL", а описания читались
/// в 13-символьных строках.
class _LabelledField extends StatelessWidget {
  const _LabelledField({
    required this.label,
    required this.tooltip,
    required this.field,
  });

  final String label;
  final String tooltip;
  final Widget field;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: theme.textTheme.bodyLarge),
          if (tooltip.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              tooltip,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          field,
        ],
      ),
    );
  }
}
