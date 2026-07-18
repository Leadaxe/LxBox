import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../config/consts.dart';
import '../models/parser_config.dart';
import 'app_log.dart';
import 'builder/if_engine.dart' show validateIfConstructs;
import 'l10n/locale_controller.dart';
import 'l10n/template_overlay.dart';

/// Загрузка `wizard_template.json` — асинхронный синглтон. Вынесено из
/// v1 `ConfigBuilder.loadTemplate` чтобы экраны не зависели от legacy-сборщика.
///
/// §279 — кэш ключуется тегом локали: pre-switch `load()` кладёт результат под
/// СВОЙ (старый) тег, новый язык не затирается по построению (гонка
/// invalidate-при-смене-локали невозможна). Overlay display-текста применяется
/// к декодированной map ДО `WizardTemplate.fromJson` (см. TemplateOverlay).
class TemplateLoader {
  TemplateLoader._();

  static final Map<String, WizardTemplate> _cache = {};

  static WizardTemplate? cachedOrNull([String? tag]) =>
      _cache[tag ?? LocaleController.I.effectiveTag];

  static Future<WizardTemplate> load() {
    // Тег читается В НАЧАЛЕ — результат ляжет под него, даже если локаль
    // сменится пока идёт load (mid-flight смена не отравляет кэш).
    final tag = LocaleController.I.effectiveTag;
    final hit = _cache[tag];
    if (hit != null) return Future.value(hit);
    return _loadFor(tag);
  }

  /// §279 — прогрев кэша под [tag]. LocaleController зовёт ДО notifyListeners,
  /// чтобы каждый rebuild видел тёплый локализованный кэш.
  static Future<void> reload(String tag) async {
    if (_cache.containsKey(tag)) return;
    await _loadFor(tag);
  }

  /// Полный сброс — только для смены самого ассета в dev.
  static void invalidate() => _cache.clear();

  static Future<WizardTemplate> _loadFor(String tag) async {
    final raw = await rootBundle.loadString('assets/wizard_template.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;

    // §279 — для en overlay-файла нет (шаблон И ЕСТЬ английский источник).
    // Per-key fallback (нет ключа в overlay) — тихий by design; отказ ЦЕЛОГО
    // файла — packaging-сбой: громкий лог + debug-assert, release падает в
    // английский шаблон вместо краша.
    if (tag != 'en') {
      try {
        final ovRaw =
            await rootBundle.loadString('assets/l10n/$tag/template.json');
        final overlay = TemplateOverlay.parseLocaleFile(
            jsonDecode(ovRaw) as Map<String, dynamic>);
        TemplateOverlay.apply(json, overlay);
      } catch (e) {
        AppLog.I.error('l10n: template overlay "$tag" failed to load: $e');
        assert(false, 'l10n: template overlay "$tag" failed to load: $e');
      }
    }

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

    _cache[tag] = template;
    return template;
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
