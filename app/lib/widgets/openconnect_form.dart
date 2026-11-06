/// §654 B/B2 — форма узла OpenConnect: одна на Add server (вкладка
/// OpenConnect) и на правку узла (вкладка Source, над JSON). Раскладка,
/// видимость, обязательность, диапазоны и варианты — из модели формы
/// реестра ([formLayoutFor]); виджет держит только подписи. Поле формы
/// реестра без подписи не рисуется (`token.*`, пути сертификатов — вне
/// формы, правятся JSON-ом). Тело — у владельца виджета: правка поля отдаёт
/// новое тело через [OpenConnectForm.onChanged] ([withFormValue]/
/// [applyFormOption]: пустое поле ключ не пишет, прочие ключи не трогаются).
library;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/contract/registry_form.dart' hide FormState;
import '../services/contract/registry_form.dart' as rf show FormState;
import '../services/contract/registry_warning.dart';
import '../services/l10n/locale_controller.dart';
import 'banner_palette.dart' show warningSeverityStyle;

/// Схема узла OpenConnect в реестре.
const kOpenConnectScheme = 'openconnect';

/// Подпись поля формы OpenConnect; `null` — поле не рисуется (в форме
/// реестра есть, в форму экрана не входит).
String? openConnectFieldLabel(String path) => switch (path) {
  'server' => getLocalText.s("Server"),
  'flavor' => getLocalText.s("Gateway"),
  'username' => getLocalText.s("Username"),
  'password' => getLocalText.s("Password"),
  'auth_group' => getLocalText.s("Group / Realm"),
  'external_auth_disabled' => getLocalText.s("Disable SSO (external auth)"),
  // l10n-exempt: technical term
  'tls.server_name' => 'SNI',
  // l10n-exempt: HTTP header name
  'user_agent' => 'User-Agent',
  'fortinet_host_check.hostcheck' => getLocalText.s("Hostcheck"),
  'no_udp' => getLocalText.s("TCP only (no DTLS)"),
  'ipv6_disabled' => getLocalText.s("Disable IPv6"),
  // l10n-exempt: technical term
  'mtu' => 'MTU',
  'dpd_interval' => getLocalText.s("DPD interval"),
  'reconnect_timeout' => getLocalText.s("Reconnect timeout"),
  'allow_insecure_crypto' => getLocalText.s("Allow legacy crypto"),
  _ => null,
};

String? _choiceLabel(String choice) => switch (choice) {
  'server_cert_check' => getLocalText.s("Server certificate"),
  _ => null,
};

/// Поле рисуется формой: видимо по модели и у него есть подпись (для путей
/// групп выбора — у группы).
bool openConnectFieldShown(FormLayout layout, rf.FormState st, String path) {
  if (!st.isVisible(path)) return false;
  if (openConnectFieldLabel(path) != null) return true;
  for (final c in layout.choices) {
    if (c.paths.contains(path) && _choiceLabel(c.id) != null) return true;
  }
  return false;
}

/// Блоки и поля формы OpenConnect (без Tag и без прокрутки — их даёт экран).
///
/// Тело [body] приходит от владельца. Изменилось извне (не эхо последней
/// правки формы) — поля ввода, чьё значение разошлось с телом, получают
/// текст из тела; иначе контроллеры не трогаются (курсор не прыгает).
class OpenConnectForm extends StatefulWidget {
  const OpenConnectForm({
    super.key,
    required this.body,
    required this.onChanged,
    this.showErrors = false,
    this.enabled = true,
  });

  /// Тело узла (без правок формой — как есть, с `type`/`tag`, если есть).
  final Map<String, dynamic> body;

  /// Новое тело после правки поля.
  final ValueChanged<Map<String, dynamic>> onChanged;

  /// Показывать `Required` у пустых обязательных полей.
  final bool showErrors;

  /// `false` — форма видна, но не правится.
  final bool enabled;

  @override
  State<OpenConnectForm> createState() => _OpenConnectFormState();
}

class _OpenConnectFormState extends State<OpenConnectForm> {
  static const _eq = DeepCollectionEquality();

  late final FormLayout? _layout = formLayoutFor(kOpenConnectScheme);
  final Map<String, TextEditingController> _text = {};
  bool _showPassword = false;
  bool _securityOpen = true;
  bool _advancedOpen = false;
  // Вариант группы выбора, выбранный в этой форме, по id группы. Нужен,
  // пока путь выбранного варианта пуст (выбрали Pinned, отпечаток ещё не
  // ввели): по телу активным был бы вариант без путей.
  final Map<String, String> _picked = {};
  // Последнее тело, отданное формой: его эхо — не правка извне.
  Map<String, dynamic>? _emitted;

  Map<String, dynamic> get _body => widget.body;

  @override
  void didUpdateWidget(covariant OpenConnectForm old) {
    super.didUpdateWidget(old);
    final layout = _layout;
    if (layout == null || _eq.equals(widget.body, _emitted)) return;
    _emitted = null;
    for (final e in _text.entries) {
      final f = layout.field(e.key);
      if (f == null) continue;
      final ctrl = e.value;
      final v = formValueAt(_body, e.key);
      final typed = f.type.startsWith('listable')
          ? formListInput(ctrl.text)
          : formInputValue(f, ctrl.text);
      final empty = v == null || (v is List && v.isEmpty);
      final typedEmpty = typed == null || (typed is List && typed.isEmpty);
      if ((empty && typedEmpty) || _eq.equals(typed, v)) continue;
      final next = _textOf(v);
      if (next != ctrl.text) ctrl.text = next;
    }
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _emit(Map<String, dynamic> body) {
    _emitted = body;
    widget.onChanged(body);
  }

  static String _textOf(Object? v) =>
      v is List ? v.join(', ') : (v == null ? '' : '$v');

  /// Подсказка под полем (макет SPEC 167 §2.3 лаунчера). Диапазон MTU — из
  /// `min`/`max` формы реестра.
  String? _hint(FormFieldSpec f) => switch (f.path) {
    'server' => getLocalText.s("host:port or full URL; port 443 if omitted"),
    'password' => getLocalText.s(
      "If the gateway asks for a code, you will be prompted on connect",
    ),
    'tls.server_name' => getLocalText.s(
      "Only if it differs from the server host",
    ),
    'user_agent' => getLocalText.s(
      "Empty = core default (FortiGate: Mozilla/5.0 SV1)",
    ),
    'fortinet_host_check.hostcheck' => getLocalText.s("FortiGate only"),
    'no_udp' => getLocalText.s(
      "Use when UDP is blocked and the tunnel keeps dropping",
    ),
    'mtu' => getLocalText.s(
      "Empty = from gateway; lower it if HTTPS stalls (%1\$s…%2\$s)",
      '${f.min ?? ''}',
      '${f.max ?? ''}',
    ),
    'dpd_interval' => getLocalText.s(
      "Keep-alive probe period, e.g. 30s. Empty = from gateway",
    ),
    'reconnect_timeout' => getLocalText.s(
      "How long to retry a dropped tunnel, e.g. 5m. Empty = core default (5m)",
    ),
    'allow_insecure_crypto' => getLocalText.s(
      "Only for old gateways (TLS 1.0)",
    ),
    _ => null,
  };

  /// Подпись значения enum-поля; незнакомое значение — само значение
  /// (wire-имя вендора).
  String _valueLabel(String path, String value) => switch ((path, value)) {
    // l10n-exempt: vendor name
    ('flavor', 'fortinet') => 'FortiGate (fortinet)',
    // l10n-exempt: vendor name
    ('flavor', 'anyconnect') => 'Cisco AnyConnect (anyconnect)',
    // l10n-exempt: vendor name
    ('flavor', 'gp') => 'GlobalProtect (gp)',
    // l10n-exempt: vendor name
    ('flavor', 'f5') => 'F5 (f5)',
    // l10n-exempt: vendor name
    ('flavor', 'pulse') => 'Pulse (pulse)',
    // l10n-exempt: vendor name
    ('flavor', 'nc') => 'Juniper (nc)',
    _ => value,
  };

  String? _blockTitle(String block) => switch (block) {
    'security' => getLocalText.s("Security"),
    'advanced' => getLocalText.s("Advanced"),
    _ => null,
  };

  String? _optionLabel(String choice, String option) =>
      switch ((choice, option)) {
        ('server_cert_check', 'system') => getLocalText.s("System CA"),
        ('server_cert_check', 'pinned') => getLocalText.s("Pinned fingerprint"),
        ('server_cert_check', 'insecure') => getLocalText.s("Do not verify"),
        _ => null,
      };

  /// Свёрнут ли блок: первый блок раскладки всегда раскрыт и без заголовка,
  /// Security раскрыт, прочие свёрнуты (макет SPEC 167 §2.3).
  bool _blockOpen(String block) =>
      block == 'security' ? _securityOpen : _advancedOpen;

  void _setBlockOpen(String block, bool open) {
    if (block == 'security') {
      _securityOpen = open;
    } else {
      _advancedOpen = open;
    }
  }

  TextEditingController _ctrl(String path) => _text.putIfAbsent(path, () {
    return TextEditingController(text: _textOf(formValueAt(_body, path)));
  });

  void _set(String path, Object? value) =>
      _emit(withFormValue(_body, path, value));

  String? _error(FormFieldSpec f, rf.FormState st) {
    final range = st.outOfRangeAt(f.path);
    if (range != null) {
      return getLocalText.s(
        "Allowed range: %1\$s…%2\$s",
        '${range.min ?? ''}',
        '${range.max ?? ''}',
      );
    }
    if (widget.showErrors && st.isMissing(f.path)) {
      return getLocalText.s("Required");
    }
    return null;
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
  );

  InputDecoration _input(String hint) => InputDecoration(
    hintText: hint,
    border: const OutlineInputBorder(),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );

  List<Widget> _advisories(List<String> codes) {
    if (codes.isEmpty) return const [];
    final lang = registryLangForTag(LocaleController.I.effectiveTag);
    final small = Theme.of(context).textTheme.bodySmall;
    return [
      for (final code in codes)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Builder(
            builder: (context) {
              final (color, icon) = warningSeverityStyle(
                context,
                registrySeverity(code),
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      registryTitle(code, lang),
                      style: small?.copyWith(color: color),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final layout = _layout;
    if (layout == null) return const SizedBox.shrink();
    final st = layout.stateOf(_body);
    final hintStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final children = <Widget>[];
    for (var i = 0; i < layout.blocks.length; i++) {
      final block = layout.blocks[i];
      final items = <Widget>[
        for (final c in layout.choicesIn(block))
          ..._choiceWidgets(layout, c, hintStyle),
        for (final f in layout.fieldsIn(block))
          if (!f.isObject && openConnectFieldShown(layout, st, f.path))
            ..._fieldWidgets(f, st, hintStyle),
      ];
      if (items.isEmpty) continue;
      if (i == 0) {
        children.addAll(items);
        continue;
      }
      final title = _blockTitle(block);
      if (title == null) continue;
      children.add(const SizedBox(height: 8));
      children.add(
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: _blockOpen(block),
            onExpansionChanged: (v) => _setBlockOpen(block, v),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            title: Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            children: items,
          ),
        ),
      );
    }
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
    if (widget.enabled) return column;
    return ExcludeFocus(
      child: IgnorePointer(child: Opacity(opacity: 0.5, child: column)),
    );
  }

  List<Widget> _fieldWidgets(
    FormFieldSpec f,
    rf.FormState st,
    TextStyle? hintStyle,
  ) {
    final label = openConnectFieldLabel(f.path)!;
    final hint = _hint(f);
    final value = formValueAt(_body, f.path);
    final advisories = _advisories(formAdvisoryCodes(f, value, _body));
    if (f.type == 'bool') {
      return [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          subtitle: hint == null ? null : Text(hint),
          value: value == true,
          // Булево пишется только `true` (дефолт ядра — false).
          onChanged: (v) => _set(f.path, v ? true : null),
        ),
        ...advisories,
      ];
    }
    final error = _error(f, st);
    final Widget input;
    if (f.type == 'enum' && (f.values?.isNotEmpty ?? false)) {
      final values = [for (final v in f.values!) '$v'];
      final current = value is String && values.contains(value) ? value : null;
      input = DropdownButtonFormField<String>(
        key: ValueKey('oc-${f.path}-$current'),
        initialValue: current,
        isExpanded: true,
        decoration: _input('').copyWith(errorText: error),
        items: [
          for (final v in values)
            DropdownMenuItem(value: v, child: Text(_valueLabel(f.path, v))),
        ],
        onChanged: (v) => _set(f.path, v),
      );
    } else {
      final isInt = f.type == 'int';
      final obscure = f.secret && !_showPassword;
      input = TextFormField(
        controller: _ctrl(f.path),
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: !f.secret,
        keyboardType: isInt
            ? TextInputType.number
            : (f.path == 'server' ? TextInputType.url : TextInputType.text),
        inputFormatters: isInt
            ? [FilteringTextInputFormatter.digitsOnly]
            : null,
        decoration: _input('').copyWith(
          errorText: error,
          suffixIcon: f.secret
              ? IconButton(
                  tooltip: _showPassword
                      ? getLocalText.s("Hide")
                      : getLocalText.s("Show"),
                  icon: Icon(
                    _showPassword ? Icons.visibility_off : Icons.visibility,
                    size: 20,
                  ),
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                )
              : null,
        ),
        onChanged: (t) => _set(f.path, formInputValue(f, t)),
      );
    }
    return [
      const SizedBox(height: 12),
      _label(label),
      input,
      if (hint != null) ...[
        const SizedBox(height: 6),
        Text(hint, style: hintStyle),
      ],
      ...advisories,
    ];
  }

  /// Группа выбора (`form.choices`): радио по вариантам, ввод для путей
  /// выбранного варианта, которые он не ставит сам (`set`), и
  /// предупреждения `advisory` полей варианта.
  List<Widget> _choiceWidgets(
    FormLayout layout,
    FormChoice c,
    TextStyle? hintStyle,
  ) {
    final title = _choiceLabel(c.id);
    if (title == null) return const [];
    final byBody = activeFormOption(c, _body);
    final picked = _picked[c.id];
    // Выбор формы держится, пока тело не говорит о другом варианте с путями.
    final active = picked != null && (c.option(byBody)?.paths.isEmpty ?? true)
        ? picked
        : byBody;
    final option = c.option(active);
    final inputs = <Widget>[];
    final codes = <String>[];
    for (final p in option?.paths ?? const <String>[]) {
      final f = layout.field(p);
      if (f == null) continue;
      codes.addAll(formAdvisoryCodes(f, formValueAt(_body, p), _body));
      if (option!.set.containsKey(p)) continue;
      final listable = f.type.startsWith('listable');
      inputs.add(
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: TextFormField(
            controller: _ctrl(p),
            autocorrect: false,
            enableSuggestions: false,
            decoration: _input('sha256:…'),
            onChanged: (t) =>
                _set(p, listable ? formListInput(t) : formInputValue(f, t)),
          ),
        ),
      );
      if (listable) {
        inputs.add(
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Text(
              getLocalText.s("Several values: comma-separated"),
              style: hintStyle,
            ),
          ),
        );
      }
    }
    return [
      const SizedBox(height: 4),
      _label(title),
      RadioGroup<String>(
        groupValue: active,
        onChanged: (id) {
          if (id == null) return;
          setState(() => _picked[c.id] = id);
          var body = applyFormOption(_body, c, id);
          // Введённое раньше в поле варианта возвращается в тело.
          final chosen = c.option(id);
          for (final p in chosen?.paths ?? const <String>[]) {
            final f = layout.field(p);
            final ctrl = _text[p];
            if (f == null || ctrl == null || chosen!.set.containsKey(p)) {
              continue;
            }
            body = withFormValue(
              body,
              p,
              f.type.startsWith('listable')
                  ? formListInput(ctrl.text)
                  : formInputValue(f, ctrl.text),
            );
          }
          _emit(body);
        },
        child: Column(
          children: [
            for (final o in c.options)
              if (_optionLabel(c.id, o.id) case final label?) ...[
                RadioListTile<String>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  value: o.id,
                  title: Text(label),
                ),
                if (o.id == active) ...inputs,
              ],
          ],
        ),
      ),
      ..._advisories(codes),
    ];
  }
}
