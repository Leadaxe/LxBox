import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../config/consts.dart';
import '../models/parser_config.dart';
import 'builder/if_engine.dart' show validateIfConstructs;

/// Загрузка `wizard_template.json` — асинхронный синглтон. Вынесено из
/// v1 `ConfigBuilder.loadTemplate` чтобы экраны не зависели от legacy-сборщика.
class TemplateLoader {
  TemplateLoader._();

  static WizardTemplate? _cached;

  static Future<WizardTemplate> load() async {
    if (_cached != null) return _cached!;
    final raw = await rootBundle.loadString('assets/wizard_template.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;

    final template = WizardTemplate.fromJson(json);

    // §120: валидация #if-конструкций против объявленных var-нод. Кривой #if
    // в bundled-шаблоне = баг разработчика → бросаем на load (не молча битый
    // конфиг). byName собирается из template.vars (метаданные/типы).
    final byName = <String, WizardVar>{
      for (final v in template.vars) v.name: v,
    };
    validateIfConstructs(template.config, byName);

    // §267: инвариант зеркал magic_nodes ↔ consts.dart. Тот же принцип, что
    // validateIfConstructs — расхождение в bundled-шаблоне = баг разработчика,
    // бросаем на load, а не молча ломаем маршрутизацию.
    assertMagicNodeMirrors(template.groupTemplates);

    _cached = template;
    return _cached!;
  }
}

/// §267 — сверяет `magic_nodes.*.tag` (source of truth) против const-зеркал
/// в `consts.dart`. Расхождение (переименовали tag в шаблоне, забыли const)
/// → бросаем StateError на старте с ясной ошибкой вместо тихой поломки
/// роутинга. `auto` — производная нода (tag собирается per-channel из tpl),
/// её `kAutoOutboundTag` = имя-заготовка, сверяется тестом на resolveTpl.
///
/// Top-level (не приватная) — чтобы покрывалась unit-тестом напрямую, без
/// мока rootBundle/asset-load.
void assertMagicNodeMirrors(GroupTemplates gt) {
  final direct = gt.magicNodes['direct']?.tag;
  final block = gt.magicNodes['block']?.tag;
  if (direct != kDirectOutboundTag || block != kBlockOutboundTag) {
    throw StateError(
        'magic_nodes tag mismatch with consts.dart mirror — update consts.dart');
  }
}
