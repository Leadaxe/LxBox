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
    _cached = WizardTemplate.fromJson(json);
    return _cached!;
  }
}
