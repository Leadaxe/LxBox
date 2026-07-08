import 'dart:convert';
import 'dart:io' show InternetAddress;

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';

import '../../config/consts.dart' show kDirectOutboundTag;
import '../../models/parser_config.dart' show WizardVar;
import '../../widgets/outbound_picker.dart';
import '../../widgets/var_values_model.dart';
import '../dns_settings_screen/resolved_server.dart';

/// §117 задача 4b — три режима формы создания/редактирования inline-сервера.
/// Значение = sing-box `type`. Прочие типы (`local`, `h3`, …) формой не
/// выражаются — редактируются на JSON-вкладке.
const kDnsServerModes = ['udp', 'tls', 'https'];

/// Дефолтный порт режима (sing-box применяет его сам при отсутствии
/// `server_port` — храним ключ только для нестандартных портов).
int defaultDnsPort(String mode) => switch (mode) {
      'tls' => 853,
      'https' => 443,
      _ => 53,
    };

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

  // §117 задача 4b — поля формы inline-сервера (UDP/DoT/DoH). Пишут в
  // канонический [_body]; JSON-вкладка синхронизируется текстом.
  late final TextEditingController addressCtrl;
  late final TextEditingController portCtrl;
  late final TextEditingController pathCtrl;
  late final TextEditingController sniCtrl;

  late bool _enabled;
  late Map<String, String> _varValues;

  /// §232 — реактивная модель для [TemplateVarListView] (per-key подписка
  /// полей). Persistence-истина остаётся [_varValues] (сериализуется в
  /// `out['varValues']` только с явно заданными ключами) — модель сидируется
  /// vars+defaults и обновляется TVLV напрямую; [setVarValue] (onChanged)
  /// ведёт запись в [_varValues]. §161: пустое required попадает в модель
  /// display-only и до [_varValues] не доходит.
  late final VarValuesModel varModel;
  late Map<String, dynamic> _body;
  String? _jsonError;
  bool _disposed = false;

  /// Гард от петли: JSON-edit → tagCtrl.text → listener tagCtrl НЕ должен
  /// перезаписывать bodyCtrl (сбил бы курсор юзера в JSON-поле).
  bool _syncingFromJson = false;

  bool get enabled => _enabled;
  Map<String, String> get varValues => _varValues;
  String? get jsonError => _jsonError;

  /// Текущий inline-detour (`body['detour']`; locked decision №10 — живёт в
  /// body, не в varValues). Отсутствие ключа = direct-out (решение №2).
  String get inlineDetour {
    final d = _body['detour'];
    return d is String && d.isNotEmpty ? d : kDirectOutboundTag;
  }

  /// §117 задача 4b — режим формы: `udp`/`tls`/`https`, либо null когда
  /// `body.type` формой не выражается (local, h3, …) → JSON-only editing.
  String? get serverMode {
    final t = _body['type'];
    return t is String && kDnsServerModes.contains(t) ? t : null;
  }

  /// Тип body как есть (для пометки «custom type — use JSON tab»).
  String get rawServerType => _body['type']?.toString() ?? '';

  /// Адрес — hostname (не IP)? Доменному серверу нужен `domain_resolver` —
  /// чем резолвить имя самого DNS-сервера (решение №4, как Safe DNS).
  bool get isHostnameAddress {
    final addr = _body['server']?.toString() ?? '';
    if (addr.isEmpty) return false;
    return InternetAddress.tryParse(addr) == null;
  }

  String get domainResolver => _body['domain_resolver']?.toString() ?? '';

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
    // §232 — модель для TVLV: все vars с fallback на default (контракт TVLV:
    // «отсутствующий ключ» не различим от пустого — сидируем всё).
    varModel = VarValuesModel({
      for (final v in vars) v.name: _varValues[v.name] ?? v.defaultValue,
    });
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
        text: kind == ServerKind.inline ? _encodeBodyWithTag() : '');
    addressCtrl = TextEditingController(text: _body['server']?.toString() ?? '');
    portCtrl = TextEditingController(
        text: _body['server_port'] is int ? '${_body['server_port']}' : '');
    pathCtrl = TextEditingController(text: _body['path']?.toString() ?? '');
    final tls = _body['tls'];
    sniCtrl = TextEditingController(
        text: tls is Map ? (tls['server_name']?.toString() ?? '') : '');
    tagCtrl.addListener(_onTagChanged);
    descCtrl.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    if (_disposed) return;
    notifyListeners();
  }

  /// Tag — поле sing-box-сервера: показываем его в JSON-вкладке. Правка
  /// Tag в Params пересинхронизирует JSON-текст (кроме случая, когда сама
  /// правка пришла из JSON — гард [_syncingFromJson]).
  void _onTagChanged() {
    if (_disposed) return;
    if (kind == ServerKind.inline && !_syncingFromJson) {
      _syncJsonFromBody();
    }
    notifyListeners();
  }

  /// Полное тело для JSON-вкладки: `tag` (из tagCtrl) первым ключом +
  /// body. description/enabled — ref-level, в sing-box-тело не входят.
  String _encodeBodyWithTag() => const JsonEncoder.withIndent('  ')
      .convert({'tag': tagCtrl.text.trim(), ..._body});

  @override
  void dispose() {
    _disposed = true;
    varModel.dispose();
    tagCtrl
      ..removeListener(_onTagChanged)
      ..dispose();
    descCtrl
      ..removeListener(_onTextChanged)
      ..dispose();
    bodyCtrl.dispose();
    addressCtrl.dispose();
    portCtrl.dispose();
    pathCtrl.dispose();
    sniCtrl.dispose();
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
    if (tag == kDirectOutboundTag || tag.isEmpty) {
      _body.remove('detour');
    } else {
      _body['detour'] = tag;
    }
    _syncJsonFromBody();
    notifyListeners();
  }

  // ─── §117 задача 4b — форма inline-сервера (UDP/DoT/DoH) ─────────────
  // Поля пишут в канонический _body; JSON-вкладка пересинхронизируется
  // текстом (затирает невалидный недонабранный JSON — осознанный trade-off:
  // валидный _body — последний источник правды).

  /// Переключение режима UDP/DoT/DoH. Адрес/detour сохраняются; порт со
  /// старого дефолта снимается (ключ уходит — sing-box применит дефолт
  /// нового режима); path/tls чистятся под режим.
  void setServerMode(String mode) {
    if (!kDnsServerModes.contains(mode)) return;
    final old = serverMode;
    if (old == mode) return;
    _body['type'] = mode;
    // Порт: стандартный для старого режима → убираем (дефолт нового);
    // нестандартный (юзер вводил) — сохраняем.
    final port = _body['server_port'];
    if (old != null && (port == null || port == defaultDnsPort(old))) {
      _body.remove('server_port');
      portCtrl.text = '';
    }
    if (mode != 'https') _body.remove('path');
    if (mode == 'udp') _body.remove('tls');
    if (mode != 'https') pathCtrl.text = '';
    if (mode == 'udp') sniCtrl.text = '';
    _syncJsonFromBody();
    notifyListeners();
  }

  /// Адрес сервера. Для DoH принимает и URL-вставку
  /// (`https://host/dns-query` → server=host, path=/dns-query).
  /// Hostname-адрес автоматически получает `domain_resolver` (дефолт
  /// google_udp — решение №4); IP-адрес — теряет его.
  void onAddressChanged(String raw) {
    var addr = raw.trim();
    if (addr.startsWith('https://')) {
      final uri = Uri.tryParse(addr);
      if (uri != null && uri.host.isNotEmpty) {
        addr = uri.host;
        addressCtrl.text = addr;
        addressCtrl.selection = TextSelection.collapsed(offset: addr.length);
        if (uri.path.isNotEmpty && uri.path != '/') {
          _body['path'] = uri.path;
          pathCtrl.text = uri.path;
        }
        if (serverMode != 'https') setServerMode('https');
      }
    }
    if (addr.isEmpty) {
      _body.remove('server');
    } else {
      _body['server'] = addr;
    }
    if (isHostnameAddress) {
      if (domainResolver.isEmpty) {
        final def = dnsServerTags.contains('google_udp')
            ? 'google_udp'
            : (dnsServerTags.isNotEmpty ? dnsServerTags.first : '');
        if (def.isNotEmpty) _body['domain_resolver'] = def;
      }
    } else {
      _body.remove('domain_resolver');
    }
    _syncJsonFromBody();
    notifyListeners();
  }

  /// Порт. Пусто/невалидно → ключ уходит (sing-box применит дефолт режима).
  void onPortChanged(String raw) {
    final port = int.tryParse(raw.trim());
    if (port == null || port < 1 || port > 65535) {
      _body.remove('server_port');
    } else {
      _body['server_port'] = port;
    }
    _syncJsonFromBody();
    notifyListeners();
  }

  /// DoH path. Пусто → ключ уходит (sing-box дефолт /dns-query).
  void onPathChanged(String raw) {
    final p = raw.trim();
    if (p.isEmpty) {
      _body.remove('path');
    } else {
      _body['path'] = p.startsWith('/') ? p : '/$p';
    }
    _syncJsonFromBody();
    notifyListeners();
  }

  /// TLS SNI (DoT/DoH с IP-адресом — каким именем проверять сертификат).
  /// Пусто → tls-блок уходит.
  void onSniChanged(String raw) {
    final sni = raw.trim();
    if (sni.isEmpty) {
      _body.remove('tls');
    } else {
      _body['tls'] = {'enabled': true, 'server_name': sni};
    }
    _syncJsonFromBody();
    notifyListeners();
  }

  /// Domain resolver для hostname-адреса (дропдаун существующих серверов).
  void setDomainResolver(String tag) {
    if (tag.isEmpty) {
      _body.remove('domain_resolver');
    } else {
      _body['domain_resolver'] = tag;
    }
    _syncJsonFromBody();
    notifyListeners();
  }

  void _syncJsonFromBody() {
    bodyCtrl.text = _encodeBodyWithTag();
    _jsonError = null;
  }

  /// После валидного JSON-edit'а подтягиваем поля формы (programmatic
  /// `.text` не триггерит onChanged у TextField — петли нет).
  void _syncFormFromBody() {
    final addr = _body['server']?.toString() ?? '';
    if (addressCtrl.text != addr) addressCtrl.text = addr;
    final port = _body['server_port'] is int ? '${_body['server_port']}' : '';
    if (portCtrl.text != port) portCtrl.text = port;
    final path = _body['path']?.toString() ?? '';
    if (pathCtrl.text != path) pathCtrl.text = path;
    final tls = _body['tls'];
    final sni = tls is Map ? (tls['server_name']?.toString() ?? '') : '';
    if (sniCtrl.text != sni) sniCtrl.text = sni;
  }

  /// JSON-вкладка (inline): парс на каждый edit. Валидный объект →
  /// становится текущим body (со strip'ом ref-level полей, та же логика
  /// что в бывшем server_editor_sheet); невалидный → jsonError, save
  /// блокируется, последний валидный body сохраняется.
  ///
  /// `tag` — часть sing-box-тела: правка tag в JSON синхронизирует поле
  /// Tag (rename каскадит по ссылкам на save — §117 задача 4b).
  void onBodyTextChanged(String text) {
    try {
      final parsed = jsonDecode(text);
      if (parsed is! Map<String, dynamic>) {
        _jsonError = 'Body must be a JSON object';
      } else {
        final jsonTag = parsed['tag']?.toString().trim() ?? '';
        if (jsonTag.isNotEmpty && jsonTag != tagCtrl.text.trim()) {
          _syncingFromJson = true;
          tagCtrl.text = jsonTag;
          _syncingFromJson = false;
        }
        parsed.remove('tag');
        _stripRefLevelFields(parsed);
        _body = parsed;
        _jsonError = null;
        _syncFormFromBody();
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
