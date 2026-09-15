import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../config/consts.dart';
import '../models/parser_config.dart';
import 'app_log.dart';
import 'builder/if_engine.dart' show TemplateIfError, validateIfConstructs;
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

    // §120 / SPEC 393-D4: валидация условных конструкций против объявленных
    // var-нод. Кривая конструкция в bundled-шаблоне = баг разработчика →
    // бросаем на load (не молча битый конфиг).
    validateTemplateConstructs(json, template);

    // §267: инвариант зеркал magic_nodes ↔ consts.dart. Тот же принцип, что
    // validateIfConstructs — расхождение в bundled-шаблоне = баг разработчика,
    // бросаем на load, а не молча ломаем маршрутизацию.
    assertMagicNodeMirrors(template.groupTemplates);

    _cache[tag] = template;
    return template;
  }
}

/// SPEC 393-D4 — рубеж load-валидации условных конструкций ВСЕГО шаблона.
///
/// До этого проверялась одна секция `config`, и симметрия с лаунчером была
/// нарушена: Go валидирует `params`, `default_value` И `config`
/// (`core/template/template_validate.go:83`). Мобильный аналог `params` —
/// `selectable_rules[]` (тела правил, `rule_set[]`, `dns_rules[]`), аналог
/// `default_value.#if` — `vars[].#on_change.#set` (значение цели — `#if`-узел).
/// Ни то, ни другое не проверялось вовсе: единственный `#enable` боевого
/// шаблона живёт в `selectable_rules[2].rule_set[2]`, то есть мимо `config`.
///
/// Область видимости имён:
///   • `config` и `#on_change` глобальных vars — глобальные vars;
///   • тело пресета — глобальные vars ПЛЮС собственные `vars[]` пресета
///     (ref-запись `{"ref": "name"}` разрешается в глобальную декларацию —
///     свой type у неё placeholder'ный).
///
/// [raw] — декодированный (и уже оверлеенный) JSON шаблона; [template] — он же
/// разобранный, источник глобальных объявлений.
void validateTemplateConstructs(
  Map<String, dynamic> raw,
  WizardTemplate template,
) {
  final globals = <String, WizardVar>{
    for (final v in template.vars) v.name: v,
  };

  validateIfConstructs(raw['config'], globals, path: 'config');

  // `#on_change.#set` глобальных vars: значение цели — `#if`-узел, тот же
  // движок (evalIfScalar), значит и тот же валидатор.
  for (final s in (raw['sections'] as List? ?? const [])
      .whereType<Map<String, dynamic>>()) {
    final name = s['name'] as String? ?? '';
    for (final v in (s['vars'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()) {
      _validateOnChange(v, globals, 'sections[$name].vars[${v['name']}]');
    }
  }

  _validateDnsServerPlaceholders(raw);

  final rules = raw['selectable_rules'] as List? ?? const [];
  for (var i = 0; i < rules.length; i++) {
    final r = rules[i];
    if (r is! Map<String, dynamic>) continue;
    final id = (r['preset_id'] as String?) ?? '$i';
    final scope = _presetScope(r, globals);
    for (final key in const ['rule', 'rules', 'rule_set', 'dns_rules']) {
      if (!r.containsKey(key)) continue;
      validateIfConstructs(r[key], scope,
          path: 'selectable_rules[$id].$key');
    }
    for (final v in (r['vars'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()) {
      _validateOnChange(
          v, scope, 'selectable_rules[$id].vars[${v['name'] ?? v['ref']}]');
    }
  }
}

/// §443 (SPEC 129 Н11, D-118) — `@name` в теле шаблонного DNS-сервера
/// обязан быть объявлен в `vars[]` ЭТОГО сервера.
///
/// Сборка подставляет в тело только имена, объявленные сервером
/// (`resolveTemplateDnsServerBody`): глобальные переменные тела сервера не
/// видят, и необъявленный плейсхолдер молча выбил бы ключ из тела (у лаунчера
/// глобальная переменная — расширение desktop, у LxBox его нет). Это ошибка
/// ШАБЛОНА, а не данных пользователя — отвергается на загрузке.
///
/// Проверяются вложенные записи `{description, enabled, vars?, server}`; у
/// плоской записи объявлений нет, LxBox её сервером не читает. Условия `#if`
/// / `#enable` в теле — тем же валидатором с областью видимости переменных
/// сервера.
void _validateDnsServerPlaceholders(Map<String, dynamic> raw) {
  final dnsOptions = raw['dns_options'];
  if (dnsOptions is! Map<String, dynamic>) return;
  final servers = dnsOptions['servers'] as List? ?? const [];
  for (var i = 0; i < servers.length; i++) {
    final entry = servers[i];
    if (entry is! Map<String, dynamic>) continue;
    final server = entry['server'];
    if (server is! Map<String, dynamic>) continue;
    final tag = server['tag'] as String? ?? '$i';
    final scope = <String, WizardVar>{
      for (final v in (entry['vars'] as List? ?? const [])
          .whereType<Map<String, dynamic>>())
        if ((v['name'] as String? ?? '').isNotEmpty)
          v['name'] as String: WizardVar.fromJson(v),
    };
    final path = 'dns_options.servers[$tag].server';
    validateIfConstructs(server, scope, path: path);
    for (final name in _placeholderNames(server)) {
      if (!scope.containsKey(name)) {
        throw TemplateIfError('$path: `@$name` is not declared in the vars of '
            'DNS server "$tag" (SPEC 129 Н11)');
      }
    }
  }
}

/// Имена `@name` в значениях JSON-дерева [node] — строка целиком `@name`, как
/// её читает подстановка (`walk`); ключи объекта не плейсхолдеры.
Set<String> _placeholderNames(dynamic node, [Set<String>? out]) {
  final names = out ?? <String>{};
  if (node is String) {
    if (node.startsWith('@')) {
      final name = node.substring(1);
      if (name.isNotEmpty && !name.contains('@')) names.add(name);
    }
  } else if (node is Map) {
    for (final v in node.values) {
      _placeholderNames(v, names);
    }
  } else if (node is List) {
    for (final v in node) {
      _placeholderNames(v, names);
    }
  }
  return names;
}

/// Область видимости имён внутри пресета: глобальные vars + собственные.
/// Ref-запись метаданных не несёт — её тип берётся из глобальной декларации,
/// поэтому она в scope просто не переопределяет глобаль.
Map<String, WizardVar> _presetScope(
  Map<String, dynamic> rule,
  Map<String, WizardVar> globals,
) {
  final scope = Map<String, WizardVar>.from(globals);
  for (final v in (rule['vars'] as List? ?? const [])
      .whereType<Map<String, dynamic>>()) {
    final ref = v['ref'] as String? ?? '';
    if (ref.isNotEmpty) continue; // тип и остальное — у глобали
    final name = v['name'] as String? ?? '';
    if (name.isEmpty) continue;
    scope[name] = WizardVar.fromJson(v);
  }
  return scope;
}

/// `#on_change` (канон) / `on_change` (легаси): `{"#set": {"@target": <#if>}}`.
/// Каждое значение цели — узел языка, обходится общим валидатором.
void _validateOnChange(
  Map<String, dynamic> varJson,
  Map<String, WizardVar> scope,
  String path,
) {
  final oc = varJson['#on_change'] ?? varJson['on_change'];
  if (oc is! Map<String, dynamic>) return;
  final set = oc['#set'] ?? oc['set'];
  if (set is! Map<String, dynamic>) return;
  set.forEach((target, node) {
    validateIfConstructs(node, scope, path: '$path.#on_change.#set[$target]');
  });
}

/// §267 — сверяет `magic_nodes.*.tag` (source of truth) против const-зеркал
/// в `consts.dart`. Расхождение (переименовали tag в шаблоне, забыли const)
/// → бросаем StateError на старте с ясной ошибкой вместо тихой поломки
/// роутинга. `auto` — производная нода (tag собирается per-direction из tpl),
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
