import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/parser_config.dart';

/// Загрузка `wizard_template.json` — асинхронный синглтон. Вынесено из
/// v1 `ConfigBuilder.loadTemplate` чтобы экраны не зависели от legacy-сборщика.
class TemplateLoader {
  TemplateLoader._();

  static WizardTemplate? _cached;

  static Future<WizardTemplate> load() async {
    if (_cached != null) return _cached!;
    final raw = await rootBundle.loadString('assets/wizard_template.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;

    // Pre-substitute hidden/non-editable vars в preset_groups (и прочих
    // субтри, которые build_config не трогает через `_substituteVars`).
    // Для `@auto_proxy_tag` и подобных — должны дойти до PresetGroup.tag
    // как литерал, а не "@auto_proxy_tag" плейсхолдер.
    final hidden = _hiddenDefaults(json['sections'] as List<dynamic>?);
    if (hidden.isNotEmpty) {
      _substituteInPlace(json['preset_groups'], hidden);
    }

    _cached = WizardTemplate.fromJson(json);
    return _cached!;
  }

  /// Собирает Map<name, default> для vars где `wizard_ui == "hidden"`.
  /// Обходит nested-структуру `sections[].vars[]`. Редактируемые vars
  /// (edit/fix) подставляются позже `build_config`'ом на уровне `config`.
  static Map<String, String> _hiddenDefaults(List<dynamic>? sectionsJson) {
    final out = <String, String>{};
    if (sectionsJson == null) return out;
    for (final section in sectionsJson.whereType<Map<String, dynamic>>()) {
      final vars = section['vars'] as List<dynamic>? ?? const [];
      for (final item in vars.whereType<Map<String, dynamic>>()) {
        if (item['wizard_ui'] != 'hidden') continue;
        final name = item['name'];
        final def = item['default_value'];
        if (name is String && def != null) out[name] = def.toString();
      }
    }
    return out;
  }

  /// In-place рекурсивная замена строк `@<name>` на `vars[<name>]` в
  /// любом вложенном JSON-узле (Map / List / scalar).
  static void _substituteInPlace(dynamic obj, Map<String, String> vars) {
    if (obj is Map<String, dynamic>) {
      for (final k in obj.keys.toList()) {
        final v = obj[k];
        if (v is String) {
          obj[k] = _sub(v, vars);
        } else {
          _substituteInPlace(v, vars);
        }
      }
    } else if (obj is List) {
      for (var i = 0; i < obj.length; i++) {
        final v = obj[i];
        if (v is String) {
          obj[i] = _sub(v, vars);
        } else {
          _substituteInPlace(v, vars);
        }
      }
    }
  }

  static String _sub(String v, Map<String, String> vars) {
    if (!v.startsWith('@')) return v;
    final name = v.substring(1);
    return vars[name] ?? v;
  }
}
