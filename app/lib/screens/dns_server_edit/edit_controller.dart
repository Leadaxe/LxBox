import 'dart:convert';
import 'dart:io' show InternetAddress;

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';

import '../../config/consts.dart' show kDirectOutboundTag;
import '../../models/parser_config.dart' show WizardVar;
import '../../widgets/outbound_picker.dart';
import '../../widgets/var_values_model.dart';
import '../dns_settings_screen/resolved_server.dart';

/// §117 задача 4b — режимы формы создания/редактирования inline-сервера.
/// Значение = sing-box `type`. Прочие типы (`local`, `h3`, …) формой не
/// выражаются — редактируются на JSON-вкладке.
/// §312 — `group` (kernel SPEC 033): группа DNS-серверов с резервированием.
const kDnsServerModes = ['udp', 'tls', 'https', 'quic', 'h3', 'group'];

/// §411 — режимы, у которых есть HTTP-path (`/dns-query`): DoH и DoH3.
const kDnsPathModes = {'https', 'h3'};

/// §312 — режимы выбора цели DNS-группы (kernel SPEC 033).
const kDnsGroupModes = ['stable', 'fastest', 'parallel'];

/// §312 — валидация duration-полей группы (`error_ttl`/`win_ttl`).
/// Go-совместимый композит: `2m`, `90s`, `1h5m30s`. Пустая строка валидна
/// (ключ не пишется — ядро применит дефолт 2m/5m).
final kDnsDurationRe = RegExp(r'^(\d+h)?(\d+m)?(\d+s)?$');

bool isValidDnsDuration(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return true;
  final m = kDnsDurationRe.firstMatch(v);
  return m != null && m[0] == v && v != '';
}

/// §312 — опция пикера членов DNS-группы.
class DnsMemberOption {
  const DnsMemberOption({
    required this.tag,
    required this.type,
    required this.enabled,
  });
  final String tag;
  final String type; // sing-box type (для подписи строки)
  final bool enabled; // false → «disabled — will be skipped» (drop-семантика)
}

/// Дефолтный порт режима (sing-box применяет его сам при отсутствии
/// `server_port` — храним ключ только для нестандартных портов).
int defaultDnsPort(String mode) => switch (mode) {
  'tls' || 'quic' => 853,
  'https' || 'h3' => 443,
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
    this.dnsMemberOptions = const [],
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

  /// Направления для `type: outbound` vars и inline-detour пикера
  /// (Direct + активные Направления, решение №2).
  final List<OutboundOption> outboundOptions;

  /// Теги DNS-серверов для `type: dns_servers` vars (без самого себя).
  final List<String> dnsServerTags;

  /// §312 — опции пикера членов DNS-группы: ВСЕ серверы (включая disabled —
  /// drop-семантика №3: выбираем, но помечаем «will be skipped»), кроме
  /// самого себя; fakeip/hosts отфильтрованы источником (запрет ядра).
  final List<DnsMemberOption> dnsMemberOptions;

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

  // §312 — duration-поля DNS-группы.
  late final TextEditingController errorTtlCtrl;
  late final TextEditingController winTtlCtrl;

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

  /// §117 задача 4b — режим формы: `udp`/`tls`/`https`, §411 — `quic`/`h3`,
  /// либо null когда `body.type` формой не выражается (local, dhcp, …) →
  /// JSON-only editing.
  String? get serverMode {
    final t = _body['type'];
    return t is String && kDnsServerModes.contains(t) ? t : null;
  }

  /// §312 — это DNS-группа? У неё нет адреса: вместо `server` — список
  /// участников. Отдельный признак, а не `serverMode != null`: `'group'`
  /// входит в [kDnsServerModes] наравне с udp/tls/https, и гейт «адрес
  /// обязателен для формного режима» ловил группу тоже (сохранение падало
  /// с «Server address is required» — v2.18.0).
  bool get isGroup => serverMode == 'group';

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
    tagCtrl = TextEditingController(
      text: r?.tag ?? initialRef['tag']?.toString() ?? '',
    );
    descCtrl = TextEditingController(
      text: r?.description ?? initialRef['description']?.toString() ?? '',
    );
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
      text: kind == ServerKind.inline ? _encodeBodyWithTag() : '',
    );
    addressCtrl = TextEditingController(
      text: _body['server']?.toString() ?? '',
    );
    portCtrl = TextEditingController(
      text: _body['server_port'] is int ? '${_body['server_port']}' : '',
    );
    pathCtrl = TextEditingController(text: _body['path']?.toString() ?? '');
    final tls = _body['tls'];
    sniCtrl = TextEditingController(
      text: tls is Map ? (tls['server_name']?.toString() ?? '') : '',
    );
    // §312 — групповые duration-поля.
    errorTtlCtrl = TextEditingController(
      text: _body['error_ttl']?.toString() ?? '',
    );
    winTtlCtrl = TextEditingController(
      text: _body['win_ttl']?.toString() ?? '',
    );
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
  String _encodeBodyWithTag() => const JsonEncoder.withIndent(
    '  ',
  ).convert({'tag': tagCtrl.text.trim(), ..._body});

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
    errorTtlCtrl.dispose();
    winTtlCtrl.dispose();
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

  /// Переключение режима UDP/DoT/DoH/DoQ/DoH3/Group. Адрес/detour сохраняются между
  /// транспортными режимами; порт со старого дефолта снимается (ключ уходит —
  /// sing-box применит дефолт нового режима); path/tls чистятся под режим.
  /// §312 — переход В группу чистит транспортные поля (у группы их нет),
  /// переход ИЗ группы чистит групповые.
  void setServerMode(String mode) {
    if (!kDnsServerModes.contains(mode)) return;
    final old = serverMode;
    if (old == mode) return;
    _body['type'] = mode;
    if (mode == 'group') {
      // §312 — у группы только servers/mode/error_ttl/win_ttl.
      _body
        ..remove('server')
        ..remove('server_port')
        ..remove('path')
        ..remove('tls')
        ..remove('domain_resolver')
        ..remove('detour');
      _body['servers'] = _body['servers'] is List
          ? _body['servers']
          : <String>[];
      addressCtrl.text = '';
      portCtrl.text = '';
      pathCtrl.text = '';
      sniCtrl.text = '';
      _syncJsonFromBody();
      notifyListeners();
      return;
    }
    if (old == 'group') {
      _body
        ..remove('servers')
        ..remove('mode')
        ..remove('error_ttl')
        ..remove('win_ttl');
      errorTtlCtrl.text = '';
      winTtlCtrl.text = '';
    }
    // Порт: стандартный для старого режима → убираем (дефолт нового);
    // нестандартный (юзер вводил) — сохраняем.
    final port = _body['server_port'];
    if (old != null && (port == null || port == defaultDnsPort(old))) {
      _body.remove('server_port');
      portCtrl.text = '';
    }
    if (!kDnsPathModes.contains(mode)) _body.remove('path');
    if (mode == 'udp') _body.remove('tls');
    if (!kDnsPathModes.contains(mode)) pathCtrl.text = '';
    if (mode == 'udp') sniCtrl.text = '';
    _syncJsonFromBody();
    notifyListeners();
  }

  // ─── §312 — форма DNS-группы (kernel SPEC 033) ───────────────────────

  /// Члены группы из body (порядок хранится как введён; ядру не значим).
  List<String> get groupMembers => [
    for (final m in (_body['servers'] as List<dynamic>? ?? const []))
      if (m is String && m.isNotEmpty) m,
  ];

  /// Режим выбора цели; дефолт ядра — stable (ключ не материализуем).
  String get groupMode {
    final m = _body['mode'];
    return m is String && kDnsGroupModes.contains(m) ? m : 'stable';
  }

  String get groupErrorTtl => _body['error_ttl']?.toString() ?? '';
  String get groupWinTtl => _body['win_ttl']?.toString() ?? '';

  /// §312 — ошибки duration-полей (форма показывает hint, save не блокируем:
  /// невалидное значение просто не пишется в body — ядро применит дефолт).
  bool get groupErrorTtlInvalid => !isValidDnsDuration(errorTtlCtrl.text);
  bool get groupWinTtlInvalid => !isValidDnsDuration(winTtlCtrl.text);

  void toggleGroupMember(String tag, bool on) {
    if (tag.isEmpty || tag == tagCtrl.text.trim()) return;
    final members = groupMembers;
    if (on && !members.contains(tag)) {
      members.add(tag);
    } else if (!on) {
      members.remove(tag);
    } else {
      return;
    }
    _body['servers'] = members;
    _syncJsonFromBody();
    notifyListeners();
  }

  /// `stable` (дефолт ядра) → ключ уходит; прочие пишутся явно.
  void setGroupMode(String mode) {
    if (!kDnsGroupModes.contains(mode) || groupMode == mode) return;
    if (mode == 'stable') {
      _body.remove('mode');
    } else {
      _body['mode'] = mode;
    }
    _syncJsonFromBody();
    notifyListeners();
  }

  /// Duration-поле: валидное непустое → пишем; пустое/невалидное → ключ
  /// уходит (дефолт ядра), форма показывает hint по [groupErrorTtlInvalid].
  void onErrorTtlChanged(String raw) {
    final v = raw.trim();
    if (v.isEmpty || !isValidDnsDuration(v)) {
      _body.remove('error_ttl');
    } else {
      _body['error_ttl'] = v;
    }
    _syncJsonFromBody();
    notifyListeners();
  }

  void onWinTtlChanged(String raw) {
    final v = raw.trim();
    if (v.isEmpty || !isValidDnsDuration(v)) {
      _body.remove('win_ttl');
    } else {
      _body['win_ttl'] = v;
    }
    _syncJsonFromBody();
    notifyListeners();
  }

  /// Адрес сервера. Для DoH/DoH3 принимает и URL-вставку
  /// (`https://host/dns-query` → server=host, path=/dns-query); режим h3
  /// при вставке сохраняется (§411), остальные переводятся в https.
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
        if (!kDnsPathModes.contains(serverMode)) setServerMode('https');
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

  /// DoH/DoH3 path. Пусто → ключ уходит (sing-box дефолт /dns-query).
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
    // §312 — групповые поля.
    final ettl = _body['error_ttl']?.toString() ?? '';
    if (errorTtlCtrl.text != ettl) errorTtlCtrl.text = ettl;
    final wttl = _body['win_ttl']?.toString() ?? '';
    if (winTtlCtrl.text != wttl) winTtlCtrl.text = wttl;
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
    final scope = context
        .dependOnInheritedWidgetOfExactType<DnsServerEditScope>();
    assert(scope != null, 'DnsServerEditScope.of: no scope in context');
    return scope!.notifier!;
  }
}
