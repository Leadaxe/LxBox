import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/parser_config.dart';
import 'outbound_picker.dart';
import 'var_values_model.dart';
import '../services/l10n/locale_controller.dart';

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
/// - `text`/`int` → text-input; с закрытыми `options` — dropdown (TEMPLATE_LANG
///   §2.1: без `options_open` своё значение ввести нельзя); с
///   `options_open: true` — combo с suffix-▾ popup'ом: и выбрать из списка,
///   и напечатать своё (приведение по `type`: у `int` — цифры и clamp).
/// - `text_list` + `options` → множественный выбор чипами ([VarMultiSelect]);
///   при `options_open` — плюс поле своих значений, по одному на строку.
///
/// §232 — БЕЗ локальной копии значений: каждое поле подписано (one-way emit,
/// [ValueListenableBuilder]) на СВОЙ ключ [VarValuesModel]. Программные
/// изменения (on_change: галка ipv6 → стратегии) видны в UI мгновенно.
/// Правки юзера идут `model.set` + коллбэк `onChanged(name, value)` parent'у
/// (config-dirty + каскад side-effect'ов); persist — parent'ом на выходе.
///
/// Используется:
/// - `settings_screen.dart` — chapter: core (sing-box низкоуровневое)
/// - `dns_server_edit/tabs/params_tab.dart` — vars DNS-сервера (§117)
class TemplateVarListView extends StatefulWidget {
  const TemplateVarListView({
    super.key,
    required this.vars,
    required this.model,
    required this.onChanged,
    this.sectionDescriptions = const {},
    this.showSectionHeaders = true,
    this.outboundOptions = const [],
    this.dnsServerTags = const [],
  });

  /// Переменные для рендеринга. Порядок и секции сохраняются.
  final List<WizardVar> vars;

  /// §232 — реактивная модель значений. КОНТРАКТ: parent сидирует её ВСЕМИ
  /// [vars] (stored ?? defaultValue) до создания виджета — «отсутствующий
  /// ключ» здесь не различим от «пустого значения».
  final VarValuesModel model;

  /// Вызывается на каждое изменение (значение уже в [model]). Parent
  /// ответственен за config-dirty/side-effects; persist — на его выходе.
  final void Function(String name, String value) onChanged;

  /// Описания секций по title — для подзаголовков. Пусто → без описания.
  final Map<String, String> sectionDescriptions;

  /// Показывать ли section-заголовки. false — если parent сам рисует
  /// заголовок (например, routing_screen показывает одну секцию под своей
  /// шапкой).
  final bool showSectionHeaders;

  /// §117: Направления для `type: outbound` vars (Direct + активные Направления).
  /// Пусто → outbound-var рендерится текстовым полем (fallback).
  final List<OutboundOption> outboundOptions;

  /// §117: DNS-сервер-теги для `type: dns_servers` vars (domain_resolver).
  /// Пусто → var рендерится текстовым полем (fallback).
  final List<String> dnsServerTags;

  @override
  State<TemplateVarListView> createState() => _TemplateVarListViewState();
}

class _TemplateVarListViewState extends State<TemplateVarListView> {
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
    // default → чиним прямо в модели (подписчики ещё не построены — emit
    // безопасен). optional-vars (§033, required:false) НЕ трогаем — для них
    // пусто легитимно (поле выпадает из конфига через Dropped).
    final repaired = <String, String>{};
    for (final v in widget.vars) {
      if (widget.model.get(v.name).isEmpty && _backfillDefaultOnEmpty(v)) {
        widget.model.set(v.name, v.defaultValue);
        repaired[v.name] = v.defaultValue;
      }
    }
    // Сообщаем parent'у о самочинении ПОСЛЕ первого кадра — onChanged в
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
    // §161: пустое required-поле — НЕ персистим. display-only запись
    // (markDirty:false) + unstage: ни пустота, ни предыдущий staged-ввод
    // этого поля не доезжают до storage (остаётся исходное значение).
    // Backstop в build_config подставит default при сборке; здесь же не
    // даём «сохранить пустоту». onChanged НЕ зовём.
    if (value.isEmpty && v != null && v.required && v.type != 'secret') {
      widget.model.set(name, value, markDirty: false);
      widget.model.unstage(name);
      setState(() => _emptyRequired.add(name));
      return;
    }
    widget.model.set(name, value);
    if (_emptyRequired.contains(name)) {
      setState(() => _emptyRequired.remove(name));
    }
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
    return TemplateSectionHeader(
      title: title,
      description: widget.sectionDescriptions[title] ?? '',
    );
  }

  /// §232 — каждое поле подписано на СВОЙ ключ модели: перерисовывается
  /// только оно и только на изменение своего значения (юзером или программно
  /// через on_change).
  Widget _buildVarWidget(WizardVar v) => ValueListenableBuilder<String>(
        valueListenable: widget.model.notifier(v.name),
        builder: (_, value, _) => _buildControl(v, value),
      );

  Widget _buildControl(WizardVar v, String value) {
    // §555 — `text_list` + `options`: множественный выбор (SPEC 143, D-125).
    if (v.type == 'text_list' && v.options.isNotEmpty) {
      return _LabelledField(
        label: v.title.isNotEmpty ? v.title : v.name,
        tooltip: v.tooltip,
        field: VarMultiSelect(
          key: ValueKey('multi-${v.name}'),
          v: v,
          value: value,
          onChanged: (val) => _update(v.name, val),
        ),
      );
    }
    switch (v.type) {
      case 'bool':
        return SwitchListTile(
          title: Text(v.title.isNotEmpty ? v.title : v.name),
          subtitle: v.tooltip.isNotEmpty
              ? Text(v.tooltip, style: const TextStyle(fontSize: 12))
              : null,
          value: value == 'true',
          onChanged: (val) => _update(v.name, val.toString()),
        );

      case 'enum':
        // §555 — `options_open`: список плюс своё значение.
        if (v.optionsOpen) return _buildTextField(v, value);
        return _buildOptionsDropdown(v, value);

      case 'secret':
        return VarTextField(
          key: ValueKey('secret-${v.name}'),
          value: value,
          obscure: true,
          label: v.title.isNotEmpty ? v.title : v.name,
          tooltip: v.tooltip,
          onChanged: (val) => _update(v.name, val),
          trailing: IconButton(
            tooltip: getLocalText.s("Generate random"),
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
        // §117: пикер Направления (Direct + активные Направления). Без options —
        // fallback в text-input (экраны, не передающие Направления).
        if (widget.outboundOptions.isEmpty) return _buildTextField(v, value);
        return _LabelledField(
          label: v.title.isNotEmpty ? v.title : v.name,
          tooltip: v.tooltip,
          field: OutboundPicker(
            value: value.isNotEmpty ? value : v.defaultValue,
            options: widget.outboundOptions,
            allowReject: false,
            onChanged: (val) => _update(v.name, val),
          ),
        );

      case 'dns_servers':
        // §117: dropdown DNS-сервер-тегов (domain_resolver и т.п.).
        if (widget.dnsServerTags.isEmpty) return _buildTextField(v, value);
        final currentTag = value.isNotEmpty ? value : v.defaultValue;
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
        // §555 — закрытые `options` у `text`/`int`: только выбор из списка
        // (TEMPLATE_LANG §2.1); `options_open` — combo со своим значением.
        if (v.options.isNotEmpty &&
            !v.optionsOpen &&
            (v.type == 'text' || v.type == 'int')) {
          return _buildOptionsDropdown(v, value);
        }
        return _buildTextField(v, value);
    }
  }

  /// Закрытый список `options`. Значение вне списка (старое сохранённое) —
  /// показываем `default_value`, а если и его нет в списке — первый пункт:
  /// dropdown без совпавшего пункта падает.
  Widget _buildOptionsDropdown(WizardVar v, String value) {
    final values = v.optionValues;
    final shown = values.contains(value)
        ? value
        : (values.contains(v.defaultValue) ? v.defaultValue : values.first);
    return _LabelledField(
      label: v.title.isNotEmpty ? v.title : v.name,
      tooltip: v.tooltip,
      field: DropdownButton<String>(
        key: ValueKey('options-${v.name}'),
        isExpanded: true,
        value: shown,
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
  }

  /// text: если есть options — добавляется combo-popup ▾ с пресетами.
  /// int (§161): только цифры + clamp в uint16 [0, 65535] — ядро принимает
  /// числовые поля (port/tolerance) как uint16, значение вне диапазона роняет
  /// его на decode. Backstop тот же в `coerceVarValue`.
  Widget _buildTextField(WizardVar v, String value) {
    final hasSuggestions = v.options.isNotEmpty;
    final isInt = v.type == 'int';
    return VarTextField(
      key: ValueKey('text-${v.name}'),
      value: value,
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

/// Section header for template-driven settings screens (Core, Routing, DNS).
///
/// Also used by VPN Settings → System for native toggles grouped like Core
/// sections (primary titleSmall + optional description + divider).
class TemplateSectionHeader extends StatelessWidget {
  const TemplateSectionHeader({
    super.key,
    required this.title,
    this.description = '',
  });

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
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
          if (description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                description,
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
class VarTextField extends StatefulWidget {
  const VarTextField({
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
    this.maxLines = 1,
    this.hintText,
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

  /// §555 — многострочный ввод (свои значения `text_list`, по одному на
  /// строку). `1` — обычное поле.
  final int maxLines;

  /// Подсказка в пустом поле.
  final String? hintText;

  @override
  State<VarTextField> createState() => _VarTextFieldState();
}

class _VarTextFieldState extends State<VarTextField> {
  late final TextEditingController _ctrl;
  late bool _obscured;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
    _obscured = widget.obscure;
  }

  @override
  void didUpdateWidget(covariant VarTextField old) {
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
      tooltip: getLocalText.s("Presets"),
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
      maxLines: widget.obscure ? 1 : widget.maxLines,
      minLines: 1,
      keyboardType: widget.numeric
          ? TextInputType.number
          : (widget.maxLines > 1 ? TextInputType.multiline : null),
      inputFormatters: widget.numeric
          ? [FilteringTextInputFormatter.digitsOnly]
          : null,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        hintText: widget.hintText,
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

    // Без подписи — поле встроено в чужой контрол (свои значения в
    // [VarMultiSelect]).
    if (widget.label.isEmpty) return field;
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

/// §555 — множественный выбор `text_list` + `options` (TEMPLATE_LANG §2.1,
/// SPEC 143 D-125): чип на каждую опцию; значение — выбранные строки по одной
/// на строку, в порядке `options`. При `options_open` под чипами поле своих
/// значений (по одному на строку): они идут в значение после выбранных и
/// проходят то же приведение по `type` — построчный сплит, пустые строки
/// отбрасываются. Без `options_open` строки вне списка из значения
/// выпадают при первой правке — UI своего значения не даёт.
class VarMultiSelect extends StatelessWidget {
  const VarMultiSelect({
    super.key,
    required this.v,
    required this.value,
    required this.onChanged,
  });

  final WizardVar v;
  final String value;
  final ValueChanged<String> onChanged;

  static List<String> _lines(String s) => s
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  @override
  Widget build(BuildContext context) {
    final known = v.optionValues;
    final lines = _lines(value);
    final selected = lines.where(known.contains).toSet();
    final extra = lines.where((l) => !known.contains(l)).toList();

    String compose(Set<String> sel, List<String> own) => [
          for (final o in known)
            if (sel.contains(o)) o,
          if (v.optionsOpen)
            for (final l in own)
              if (!known.contains(l)) l,
        ].join('\n');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final o in v.options)
              FilterChip(
                key: ValueKey('multi-${v.name}-${o.value}'),
                label: Text(o.title, style: const TextStyle(fontSize: 13)),
                selected: selected.contains(o.value),
                onSelected: (on) {
                  final next = {...selected};
                  on ? next.add(o.value) : next.remove(o.value);
                  onChanged(compose(next, extra));
                },
              ),
          ],
        ),
        if (v.optionsOpen) ...[
          const SizedBox(height: 8),
          VarTextField(
            key: ValueKey('multi-own-${v.name}'),
            value: extra.join('\n'),
            label: '',
            maxLines: 4,
            hintText: getLocalText.s("Other values, one per line"),
            onChanged: (raw) => onChanged(compose(selected, _lines(raw))),
          ),
        ],
      ],
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
