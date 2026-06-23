import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/parser_config.dart';
import 'outbound_picker.dart';

/// Рендерит список [WizardVar] с секция-заголовками и типизированными
/// контролами:
///
/// - `bool` → [SwitchListTile]
/// - `enum` → [DropdownButton]
/// - `secret` → text-input с обфускацией + eye-toggle + кнопка Generate
/// - `outbound` → [OutboundPicker] из [outboundOptions] (§117); без options —
///   fallback в text-input
/// - `dns_servers` → dropdown из [dnsServerTags] (§117); без tags — fallback
///   в text-input
/// - `text` → text-input; при наличии `options` — combo с suffix-▾ popup'ом
///   пресетов. Юзер может и выбрать preset, и напечатать своё.
///
/// Stateful — держит локальную копию значений; parent получает коллбэк
/// `onChanged(name, value)` на каждое изменение и сам персистит.
///
/// Используется:
/// - `settings_screen.dart` — chapter: core (sing-box низкоуровневое)
/// - `routing_screen.dart` — chapter: routing (Auto Proxy)
/// - `dns_settings_screen` — vars DNS-сервера (§117)
class TemplateVarListView extends StatefulWidget {
  const TemplateVarListView({
    super.key,
    required this.vars,
    required this.initialValues,
    required this.onChanged,
    this.sectionDescriptions = const {},
    this.showSectionHeaders = true,
    this.outboundOptions = const [],
    this.dnsServerTags = const [],
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

  /// §117: каналы для `type: outbound` vars (Direct + активные каналы).
  /// Пусто → outbound-var рендерится текстовым полем (fallback).
  final List<OutboundOption> outboundOptions;

  /// §117: DNS-сервер-теги для `type: dns_servers` vars (domain_resolver).
  /// Пусто → var рендерится текстовым полем (fallback).
  final List<String> dnsServerTags;

  @override
  State<TemplateVarListView> createState() => _TemplateVarListViewState();
}

class _TemplateVarListViewState extends State<TemplateVarListView> {
  late final Map<String, String> _values;
  late final Map<String, WizardVar> _byName;

  /// §161: имена required-полей, которые сейчас пусты — для errorText. Persist
  /// для них заблокирован (см. [_update]), сборка конфига backstop'ом подставит
  /// default — но юзер видит, что поле обязательно.
  final Set<String> _emptyRequired = {};

  @override
  void initState() {
    super.initState();
    _byName = {for (final v in widget.vars) v.name: v};
    // §161 «UI сам чинит»: при загрузке пустое required-поле с непустым
    // default → подставляем default прямо в точке чтения. Накопившиеся битые
    // значения (напр. стёртый раньше tolerance) исправляются при открытии
    // экрана. optional-vars (§033, required:false) НЕ трогаем — для них пусто
    // легитимно (поле выпадает из конфига через Dropped).
    final repaired = <String, String>{};
    _values = {
      for (final v in widget.vars)
        v.name: () {
          final raw = widget.initialValues[v.name] ?? v.defaultValue;
          if (raw.isEmpty && _backfillDefaultOnEmpty(v)) {
            repaired[v.name] = v.defaultValue;
            return v.defaultValue;
          }
          return raw;
        }(),
    };
    // Персистим самочинение в storage ПОСЛЕ первого кадра — onChanged в
    // initState небезопасен (parent ещё не смонтирован для колбэка).
    if (repaired.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        repaired.forEach(widget.onChanged);
      });
    }
  }

  /// §161: правило «пусто → default». Только required-vars с непустым default;
  /// secret исключён (намеренно стёртый пароль не воскрешаем). optional §033
  /// (required:false) и vars без default — не трогаются.
  bool _backfillDefaultOnEmpty(WizardVar v) =>
      v.required && v.defaultValue.isNotEmpty && v.type != 'secret';

  void _update(String name, String value) {
    final v = _byName[name];
    // §161: пустое required-поле — НЕ персистим (значение в storage не
    // меняется), подсвечиваем errorText. Backstop в build_config подставит
    // default при сборке; здесь же не даём «сохранить пустоту».
    if (value.isEmpty && v != null && v.required && v.type != 'secret') {
      setState(() {
        _values[name] = value;
        _emptyRequired.add(name);
      });
      return; // onChanged НЕ вызываем — persist заблокирован
    }
    setState(() {
      _values[name] = value;
      _emptyRequired.remove(name);
    });
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
        final current = _values[v.name] ?? v.defaultValue;
        final hasCurrent = v.options.any((o) => o.value == current);
        return _LabelledField(
          label: v.title.isNotEmpty ? v.title : v.name,
          tooltip: v.tooltip,
          field: DropdownButton<String>(
            isExpanded: true,
            value: hasCurrent ? current : v.defaultValue,
            items: v.options
                .map((o) => DropdownMenuItem(
                      value: o.value,
                      child: Text(o.title),
                    ))
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

      case 'outbound':
        // §117: пикер канала (Direct + активные каналы). Без options —
        // fallback в text-input (экраны, не передающие каналы).
        if (widget.outboundOptions.isEmpty) return _buildTextField(v);
        final current = _values[v.name] ?? v.defaultValue;
        return _LabelledField(
          label: v.title.isNotEmpty ? v.title : v.name,
          tooltip: v.tooltip,
          field: OutboundPicker(
            value: current,
            options: widget.outboundOptions,
            allowReject: false,
            onChanged: (val) => _update(v.name, val),
          ),
        );

      case 'dns_servers':
        // §117: dropdown DNS-сервер-тегов (domain_resolver и т.п.).
        if (widget.dnsServerTags.isEmpty) return _buildTextField(v);
        final currentTag = _values[v.name] ?? v.defaultValue;
        final tags = widget.dnsServerTags.contains(currentTag)
            ? widget.dnsServerTags
            : [currentTag, ...widget.dnsServerTags];
        return _LabelledField(
          label: v.title.isNotEmpty ? v.title : v.name,
          tooltip: v.tooltip,
          field: DropdownButton<String>(
            isExpanded: true,
            value: currentTag,
            items: tags
                .map((t) => DropdownMenuItem(
                      value: t,
                      child: Text(t, style: const TextStyle(fontSize: 13)),
                    ))
                .toList(),
            onChanged: (val) {
              if (val == null) return;
              _update(v.name, val);
            },
          ),
        );

      default:
        return _buildTextField(v);
    }
  }

  /// text: если есть options — добавляется combo-popup ▾ с пресетами.
  /// int (§161): только цифры + clamp в uint16 [0, 65535] — ядро принимает
  /// числовые поля (port/tolerance) как uint16, значение вне диапазона роняет
  /// его на decode. Backstop тот же в `coerceVarValue`.
  Widget _buildTextField(WizardVar v) {
    final hasSuggestions = v.options.isNotEmpty;
    final isInt = v.type == 'int';
    return _VarTextField(
      key: ValueKey('text-${v.name}'),
      value: _values[v.name] ?? '',
      width: hasSuggestions ? 220 : 180,
      label: v.title.isNotEmpty ? v.title : v.name,
      tooltip: v.tooltip,
      numeric: isInt,
      errorText: _emptyRequired.contains(v.name) ? 'Required' : null,
      suggestions: v.options.map((o) => o.value).toList(),
      onChanged: (val) => _update(v.name, isInt ? _clampUint16(val) : val),
    );
  }

  /// §161: нормализует int-ввод в uint16. Пусто — оставляем как есть (юзер
  /// стирает поле; clamp на пустой строке дал бы внезапный «0»).
  static String _clampUint16(String raw) {
    if (raw.isEmpty) return raw;
    final n = int.tryParse(raw);
    if (n == null) return raw; // formatter уже отсёк не-цифры; defensive
    return n.clamp(0, 65535).toString();
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
    this.numeric = false,
    this.errorText,
  });

  final String value;
  final String label;
  final String tooltip;
  final void Function(String) onChanged;
  final bool obscure;
  final double width;
  final Widget? trailing;
  final List<String> suggestions;

  /// §161: цифровая клавиатура + digits-only formatter (для `type: int`).
  final bool numeric;

  /// §161: текст ошибки под полем (напр. «Required» для пустого
  /// обязательного поля). null — поле валидно.
  final String? errorText;

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
      keyboardType: widget.numeric ? TextInputType.number : null,
      inputFormatters: widget.numeric
          ? [FilteringTextInputFormatter.digitsOnly]
          : null,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        errorText: widget.errorText, // §161: «Required» для пустого обяз. поля
        errorStyle: const TextStyle(fontSize: 11),
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
