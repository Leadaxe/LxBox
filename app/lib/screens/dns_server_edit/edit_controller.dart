import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';

import '../../models/parser_config.dart' show WizardVar;
import '../../widgets/outbound_picker.dart';
import '../dns_settings_screen/resolved_server.dart';

/// §117 задача 4 — единая точка истины для редактора DNS-сервера.
/// Паттерн 1:1 с [CustomRuleEditController] (§053 Stage 3): `ChangeNotifier`
/// + `isDirty()`/`snapshot()`, раздаётся вниз через [DnsServerEditScope].
///
/// Редактирует **ref-запись** стораджа `{enabled, kind, tag, description?,
/// body?, varValues?}` — модель/сторадж/эмиссия серверов не меняются
/// (locked decision №10), это чистый UI поверх задач 1–3.
///
/// **Что владеет controller:**
/// - `tagCtrl` (inline; locked при edit existing), `descCtrl`,
///   `bodyCtrl` (inline JSON — источник правды inline-сервера);
/// - `enabled`, `varValues` (template), распарсенный `body` (inline) +
///   `jsonError` (невалидный JSON в bodyCtrl → save блокируется);
/// - `snapshot()` / `isDirty()` — pure read из текущего state.
///
/// **Что НЕ владеет:** ничего требующего BuildContext (save/back/delete
/// диалоги, snackbar'ы) — это на screen State.
class DnsServerEditController extends ChangeNotifier {
  DnsServerEditController({
    required this.initialRef,
    this.resolved,
    this.templateWrapper,
    this.canonicalDescription = '',
    this.outboundOptions = const [],
    this.dnsServerTags = const [],
  }) {
    _init();
  }

  /// Исходная ref-запись (для edit — из `_servers`; для new — дефолтная
  /// inline-заготовка). База для dirty-сравнения и snapshot'а.
  final Map<String, dynamic> initialRef;

  /// Display-модель редактируемого сервера. null = new-режим (inline).
  final ResolvedServer? resolved;

  /// §117-обёртка `{description, enabled, vars?, server}` из шаблона —
  /// для live-превью отрезолвленного тела на JSON-вкладке (kind=template).
  final Map<String, dynamic>? templateWrapper;

  /// Каноническое описание (template/preset) — в ref пишем description
  /// только если отличается (иначе резолв и так фоллбэчит на canonical).
  final String canonicalDescription;

  /// Каналы для `type: outbound` vars и inline-detour пикера
  /// (Direct + активные каналы, решение №2).
  final List<OutboundOption> outboundOptions;

  /// Теги DNS-серверов для `type: dns_servers` vars (без самого себя).
  final List<String> dnsServerTags;

  // ─── Производные ─────────────────────────────────────────────────────

  bool get isNew => resolved == null;
  ServerKind get kind => resolved?.kind ?? ServerKind.inline;
  bool get locked => resolved?.locked ?? false;
  String get lockedByLabel => resolved?.lockedByLabel ?? '';
  ServerKind? get overrides => resolved?.overrides;
  bool get isUserOnly => resolved?.isUserOnly ?? true;
  List<WizardVar> get vars => resolved?.vars ?? const [];

  // ─── Text controllers / mutable state ────────────────────────────────

  late final TextEditingController tagCtrl;
  late final TextEditingController descCtrl;
  late final TextEditingController bodyCtrl;

  late bool _enabled;
  late Map<String, String> _varValues;
  late Map<String, dynamic> _body;
  String? _jsonError;
  bool _disposed = false;

  bool get enabled => _enabled;
  Map<String, String> get varValues => _varValues;
  String? get jsonError => _jsonError;

  /// Текущий inline-detour (`body['detour']`; locked decision №10 — живёт в
  /// body, не в varValues). Отсутствие ключа = direct-out (решение №2).
  String get inlineDetour {
    final d = _body['detour'];
    return d is String && d.isNotEmpty ? d : 'direct-out';
  }

  void _init() {
    final r = resolved;
    tagCtrl = TextEditingController(text: r?.tag ?? initialRef['tag']?.toString() ?? '');
    descCtrl = TextEditingController(
        text: r?.description ?? initialRef['description']?.toString() ?? '');
    _enabled = initialRef['enabled'] != false;
    final vv = initialRef['varValues'];
    _varValues = vv is Map
        ? {for (final e in vv.entries) e.key.toString(): '${e.value}'}
        : <String, String>{};
    // Inline body: для существующего — resolved.body без синтезированного
    // tag'а; для new — заготовка из initialRef.
    Map<String, dynamic> body;
    if (kind == ServerKind.inline) {
      final src = r != null ? r.body : (initialRef['body'] ?? const {});
      body = src is Map ? Map<String, dynamic>.from(src) : <String, dynamic>{};
      _stripRefLevelFields(body);
    } else {
      body = const {};
    }
    _body = body;
    bodyCtrl = TextEditingController(
        text: kind == ServerKind.inline
            ? const JsonEncoder.withIndent('  ').convert(_body)
            : '');
    tagCtrl.addListener(_onTextChanged);
    descCtrl.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    tagCtrl
      ..removeListener(_onTextChanged)
      ..dispose();
    descCtrl
      ..removeListener(_onTextChanged)
      ..dispose();
    bodyCtrl.dispose();
    super.dispose();
  }

  // ─── Mutators ────────────────────────────────────────────────────────

  void setEnabled(bool v) {
    if (_enabled == v) return;
    _enabled = v;
    notifyListeners();
  }

  void setVarValue(String name, String value) {
    _varValues[name] = value;
    notifyListeners();
  }

  /// §117 inline-detour: пишет/стирает `body['detour']`. `direct-out` →
  /// ключ стирается (дефолт = отсутствие ключа; на билде normalizeDnsDetour
  /// сделал бы то же — храним каноничную форму сразу).
  void setInlineDetour(String tag) {
    if (tag == 'direct-out' || tag.isEmpty) {
      _body.remove('detour');
    } else {
      _body['detour'] = tag;
    }
    // JSON-вкладка показывает тот же body — пересинхронизируем текст
    // (затирает невалидный недонабранный JSON — осознанный trade-off:
    // detour меняют из Params, валидный _body — последний источник правды).
    bodyCtrl.text = const JsonEncoder.withIndent('  ').convert(_body);
    _jsonError = null;
    notifyListeners();
  }

  /// JSON-вкладка (inline): парс на каждый edit. Валидный объект →
  /// становится текущим body (со strip'ом ref-level полей, та же логика
  /// что в бывшем server_editor_sheet); невалидный → jsonError, save
  /// блокируется, последний валидный body сохраняется.
  void onBodyTextChanged(String text) {
    try {
      final parsed = jsonDecode(text);
      if (parsed is! Map<String, dynamic>) {
        _jsonError = 'Body must be a JSON object';
      } else {
        _stripRefLevelFields(parsed);
        _body = parsed;
        _jsonError = null;
      }
    } catch (e) {
      _jsonError = 'Invalid JSON';
    }
    notifyListeners();
  }

  // ─── Snapshot / dirty ────────────────────────────────────────────────

  /// Текущее состояние формы как ref-запись стораджа. Не валидирует tag
  /// (это делает save flow на screen State).
  Map<String, dynamic> snapshot() {
    final out = Map<String, dynamic>.from(initialRef);
    out['enabled'] = _enabled;
    final desc = descCtrl.text.trim();
    switch (kind) {
      case ServerKind.inline:
        out['kind'] = 'inline';
        out['tag'] = tagCtrl.text.trim();
        if (desc.isNotEmpty) {
          out['description'] = desc;
        } else {
          out.remove('description');
        }
        out['body'] = _body;
      case ServerKind.template:
        // description в ref — только override (иначе резолв фоллбэчит).
        if (desc.isNotEmpty && desc != canonicalDescription) {
          out['description'] = desc;
        } else {
          out.remove('description');
        }
        if (_varValues.isNotEmpty) {
          out['varValues'] = _varValues;
        } else {
          out.remove('varValues');
        }
      case ServerKind.preset:
        if (desc.isNotEmpty && desc != canonicalDescription) {
          out['description'] = desc;
        } else {
          out.remove('description');
        }
    }
    return out;
  }

  bool isDirty() =>
      !const DeepCollectionEquality().equals(snapshot(), initialRef);
}

/// §044/§117: tag/description/enabled живут на ref-level, UI-аннотации не
/// персистятся — strip из body (та же логика, что была в server_editor_sheet).
void _stripRefLevelFields(Map<String, dynamic> body) {
  body
    ..remove('tag')
    ..remove('description')
    ..remove('enabled')
    ..remove('_origin')
    ..remove('_kind')
    ..remove('_overrides')
    ..remove('_preset_label');
}

/// §117 задача 4 — InheritedNotifier для раздачи controller'а вниз по tree
/// без prop-drilling (паттерн [CustomRuleEditScope]).
class DnsServerEditScope extends InheritedNotifier<DnsServerEditController> {
  const DnsServerEditScope({
    super.key,
    required DnsServerEditController super.notifier,
    required super.child,
  });

  static DnsServerEditController of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<DnsServerEditScope>();
    assert(scope != null, 'DnsServerEditScope.of: no scope in context');
    return scope!.notifier!;
  }
}
