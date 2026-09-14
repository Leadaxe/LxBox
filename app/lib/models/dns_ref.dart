// ===========================================================================
// §294 — модель записей `dns_options.servers[]` и `dns_options.rules[]`
// (виды записей §043/§033).
//
// §439 A1 — единственный рабочий формат DNS выше хранения. Резолверы, сборка,
// экраны и контроллер DNS работают только с этими типами; сырые записи живут
// в репозитории `settings_storage/network.dart`, который зовёт [fromJson] /
// [toJson]. Запись 1.0 (бэкап, секции узла) — отдельный кодек
// `codec/dns_record.dart`.
//
// Семантика `enabled` при отсутствии ключа:
// - сервер, inline- и srs-правило — включено (`enabled != false`); [toJson]
//   пишет у правил только `false`. До §439 A1 сборка ждала `enabled == true`
//   и молча пропускала такие правила (баг, исправлен в A1);
// - template- и preset-правило — выключено (`enabled == true`, как читала
//   сборка); [toJson] пишет `enabled` всегда.
//
// Значения неизменяемы по договорённости: [fromJson] и [toJson] копируют
// JSON-поддеревья, модель не делит карты с документом хранения.
//
// [fromJson] терпим к чтению: незнакомый вид или запись без обязательных полей
// → null. Такую запись репозиторий хранит как есть и наверх не отдаёт.
// Строгость — только на Debug write-пути ([DnsServerRef.fromJsonStrict]).
//
// Дискриминатор — строковый `kind`; модель не тянет `ServerKind` из `screens/`
// (обратная зависимость слоёв запрещена).
// ===========================================================================

import 'package:collection/collection.dart';

const _eq = DeepCollectionEquality();

/// Глубокая копия JSON-значения (карты и списки; скаляры как есть).
Object? _copyJson(Object? v) {
  if (v is Map) {
    return <String, dynamic>{
      for (final e in v.entries) e.key.toString(): _copyJson(e.value),
    };
  }
  if (v is List) return [for (final x in v) _copyJson(x)];
  return v;
}

Map<String, dynamic> _copyMap(Map v) => _copyJson(v) as Map<String, dynamic>;

/// Ошибка валидации формы ref'а на write-пути. Debug-handler мапит в
/// `BadRequest`; модель сама HTTP-типов не знает.
class DnsRefFormatException implements Exception {
  const DnsRefFormatException(this.message);
  final String message;
  @override
  String toString() => 'DnsRefFormatException: $message';
}

// ─── Servers ────────────────────────────────────────────────────────────────

/// Один ref из `dns_options.servers[]`. Форма на диске:
///   `{enabled, kind: inline|preset|template, tag, body?, varValues?, description?}`
sealed class DnsServerRef {
  const DnsServerRef({
    required this.enabled,
    required this.tag,
    this.description,
  });

  final bool enabled;
  final String tag;
  final String? description;

  /// `inline` | `preset` | `template`.
  String get kind;

  Map<String, dynamic> toJson();

  /// Та же запись с другим `enabled`.
  DnsServerRef withEnabled(bool enabled);

  /// Толерантный парс — null на запись без `kind` (формы до §043), незнакомый
  /// вид, отсутствующий/пустой `tag`, inline без Map-`body`.
  static DnsServerRef? fromJson(Map<String, dynamic> j) {
    final kind = j['kind'];
    final tag = j['tag']?.toString();
    if (kind is! String || tag == null || tag.isEmpty) return null;
    final enabled = j['enabled'] != false; // default true
    final description = j['description']?.toString();
    switch (kind) {
      case 'inline':
        final body = j['body'];
        if (body is! Map) return null;
        return DnsServerInline(
          enabled: enabled,
          tag: tag,
          body: _copyMap(body),
          description: description,
        );
      case 'preset':
        return DnsServerPreset(
            enabled: enabled, tag: tag, description: description);
      case 'template':
        final vv = j['varValues'];
        return DnsServerTemplate(
          enabled: enabled,
          tag: tag,
          // null-значение сборка читала как «не задано» (дефолт var) —
          // ключ не заводим.
          varValues: vv is Map
              ? {
                  for (final e in vv.entries)
                    if (e.value != null) e.key.toString(): e.value.toString()
                }
              : const {},
          description: description,
        );
      default:
        return null;
    }
  }

  /// Строгий парс для Debug write-пути — бросает [DnsRefFormatException] с
  /// объяснением вместо тихого drop'а. Используется в `_putDnsServers`.
  static DnsServerRef fromJsonStrict(Map<String, dynamic> j) {
    final kind = j['kind'];
    if (kind is! String || kind.isEmpty) {
      throw const DnsRefFormatException(
          'server "kind" required (inline|preset|template)');
    }
    final tag = j['tag']?.toString();
    if (tag == null || tag.isEmpty) {
      throw const DnsRefFormatException('server "tag" required');
    }
    if (kind == 'inline' && j['body'] is! Map) {
      throw const DnsRefFormatException('inline server requires "body" object');
    }
    if (kind != 'inline' && kind != 'preset' && kind != 'template') {
      throw DnsRefFormatException(
          'unknown server kind "$kind" (inline|preset|template)');
    }
    return fromJson(j)!;
  }
}

class DnsServerInline extends DnsServerRef {
  const DnsServerInline({
    required super.enabled,
    required super.tag,
    required this.body,
    super.description,
  });

  /// Тело sing-box-сервера без `tag`/`enabled`/`description` (§044).
  final Map<String, dynamic> body;

  @override
  String get kind => 'inline';

  @override
  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'kind': 'inline',
        'tag': tag,
        'body': _copyMap(body),
        if (description != null) 'description': description,
      };

  @override
  DnsServerInline withEnabled(bool enabled) => copyWith(enabled: enabled);

  DnsServerInline copyWith({
    bool? enabled,
    String? tag,
    Map<String, dynamic>? body,
    String? description,
  }) =>
      DnsServerInline(
        enabled: enabled ?? this.enabled,
        tag: tag ?? this.tag,
        body: body ?? this.body,
        description: description ?? this.description,
      );

  @override
  bool operator ==(Object other) =>
      other is DnsServerInline &&
      other.enabled == enabled &&
      other.tag == tag &&
      other.description == description &&
      _eq.equals(other.body, body);

  @override
  int get hashCode =>
      Object.hash('inline', enabled, tag, description, _eq.hash(body));
}

class DnsServerPreset extends DnsServerRef {
  const DnsServerPreset({
    required super.enabled,
    required super.tag,
    this.presetId = '',
    super.description,
  });

  /// §439 — пресет шаблона, которому принадлежит сервер: запись 1.0 адресует
  /// его `ref` = `<preset_id>:<tag>`. Пусто — пресет не известен (`ref` = тег).
  /// Форма хранения 2.23.2 ([toJson]/[DnsServerRef.fromJson]) поля не несёт.
  final String presetId;

  @override
  String get kind => 'preset';

  @override
  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'kind': 'preset',
        'tag': tag,
        if (description != null) 'description': description,
      };

  @override
  DnsServerPreset withEnabled(bool enabled) => copyWith(enabled: enabled);

  DnsServerPreset copyWith({
    bool? enabled,
    String? tag,
    String? presetId,
    String? description,
  }) =>
      DnsServerPreset(
        enabled: enabled ?? this.enabled,
        tag: tag ?? this.tag,
        presetId: presetId ?? this.presetId,
        description: description ?? this.description,
      );

  @override
  bool operator ==(Object other) =>
      other is DnsServerPreset &&
      other.enabled == enabled &&
      other.tag == tag &&
      other.presetId == presetId &&
      other.description == description;

  @override
  int get hashCode =>
      Object.hash('preset', enabled, tag, presetId, description);
}

class DnsServerTemplate extends DnsServerRef {
  const DnsServerTemplate({
    required super.enabled,
    required super.tag,
    this.varValues = const {},
    super.description,
  });

  final Map<String, String> varValues;

  @override
  String get kind => 'template';

  @override
  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'kind': 'template',
        'tag': tag,
        // §294 — varValues эмитится только непустой (резолвер так же не пишет
        // пустой varValues); порядок ключей после tag совпадает с выводом.
        if (varValues.isNotEmpty) 'varValues': Map<String, String>.of(varValues),
        if (description != null) 'description': description,
      };

  @override
  DnsServerTemplate withEnabled(bool enabled) => copyWith(enabled: enabled);

  DnsServerTemplate copyWith({
    bool? enabled,
    String? tag,
    Map<String, String>? varValues,
    String? description,
  }) =>
      DnsServerTemplate(
        enabled: enabled ?? this.enabled,
        tag: tag ?? this.tag,
        varValues: varValues ?? this.varValues,
        description: description ?? this.description,
      );

  @override
  bool operator ==(Object other) =>
      other is DnsServerTemplate &&
      other.enabled == enabled &&
      other.tag == tag &&
      other.description == description &&
      _eq.equals(other.varValues, varValues);

  @override
  int get hashCode =>
      Object.hash('template', enabled, tag, description, _eq.hash(varValues));
}

// ─── Rules ──────────────────────────────────────────────────────────────────

/// Один ref из `dns_options.rules[]`. Четыре kind'а с РАЗНЫМИ identity-ключами:
///   inline `{kind, name, rule}` · srs `{kind, name, id, …}` ·
///   preset `{kind, presetId}` · template `{kind, name}`; у всех — `enabled`.
/// Preset — позиционный якорь mirror-группы: его `enabled` сборка с
/// mirror-группой не читает, но значение сохраняется как есть.
sealed class DnsRuleRef {
  const DnsRuleRef();

  String get kind;

  /// Включено ли правило (отсутствие ключа — см. шапку файла).
  bool get enabled;

  Map<String, dynamic> toJson();

  /// Та же запись с другим `enabled`.
  DnsRuleRef withEnabled(bool enabled);

  /// Толерантный парс (не бросает): незнакомый вид (в том числе `user` и
  /// `rule` до §033) или запись без обязательных полей → null.
  static DnsRuleRef? fromJson(Map<String, dynamic> j) {
    final kind = j['kind'];
    if (kind is! String) return null;
    final enabledByDefault = j['enabled'] != false;
    final enabledExplicit = j['enabled'] == true;
    switch (kind) {
      case 'inline':
        final name = j['name']?.toString();
        final rule = j['rule'];
        if (name == null || name.isEmpty || rule is! Map) return null;
        return DnsRuleInline(
          name: name,
          rule: _copyMap(rule),
          enabled: enabledByDefault,
        );
      case 'srs':
        final id = j['id']?.toString();
        final name = j['name']?.toString();
        if (id == null || id.isEmpty || name == null || name.isEmpty) {
          return null;
        }
        final body = j['body'];
        final server = j['server'];
        final rule = j['rule'];
        final srsUrl = j['srsUrl'];
        return DnsRuleSrs(
          name: name,
          id: id,
          body: body is Map ? _copyMap(body) : null,
          server: server is String ? server : null,
          rule: rule is Map ? _copyMap(rule) : null,
          srsUrl: srsUrl is String ? srsUrl : null,
          enabled: enabledByDefault,
        );
      case 'preset':
        final pid = j['presetId']?.toString();
        if (pid == null || pid.isEmpty) return null;
        return DnsRulePreset(presetId: pid, enabled: enabledExplicit);
      case 'template':
        final name = j['name']?.toString();
        if (name == null || name.isEmpty) return null;
        return DnsRuleTemplate(name: name, enabled: enabledExplicit);
      default:
        return null;
    }
  }

  /// Строгий парс для Debug write-пути.
  static DnsRuleRef fromJsonStrict(Map<String, dynamic> j) {
    final kind = j['kind'];
    if (kind is! String || kind.isEmpty) {
      throw const DnsRefFormatException(
          'rule "kind" required (inline|srs|preset|template)');
    }
    final parsed = fromJson(j);
    if (parsed == null) {
      throw DnsRefFormatException(
          'invalid dns rule of kind "$kind" (missing required fields)');
    }
    return parsed;
  }
}

class DnsRuleInline extends DnsRuleRef {
  const DnsRuleInline({
    required this.name,
    required this.rule,
    this.enabled = true,
  });
  final String name;
  final Map<String, dynamic> rule;

  /// §435 — тумблер записи (ONE_NAMESPACE §1: `enabled` у DNS-правил). В JSON
  /// пишется только `false`: запись без ключа читается как «включено».
  @override
  final bool enabled;

  @override
  String get kind => 'inline';

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'inline',
        'name': name,
        'rule': _copyMap(rule),
        if (!enabled) 'enabled': false,
      };

  @override
  DnsRuleInline withEnabled(bool enabled) => copyWith(enabled: enabled);

  DnsRuleInline copyWith({
    String? name,
    Map<String, dynamic>? rule,
    bool? enabled,
  }) =>
      DnsRuleInline(
        name: name ?? this.name,
        rule: rule ?? this.rule,
        enabled: enabled ?? this.enabled,
      );

  @override
  bool operator ==(Object other) =>
      other is DnsRuleInline &&
      other.name == name &&
      other.enabled == enabled &&
      _eq.equals(other.rule, rule);

  @override
  int get hashCode => Object.hash('inline', name, enabled, _eq.hash(rule));
}

/// DNS-правило по скачанному rule-set. UI его не создаёт. Тело — `body`
/// (`server` + доп. условия; форма §294: Debug API, файл правил). `server` /
/// `rule` / `srsUrl` верхнего уровня — форма §033, её пишут только старые
/// записи: сборка берёт их раньше `body`, тайл показывает `srsUrl`/`server`.
class DnsRuleSrs extends DnsRuleRef {
  const DnsRuleSrs({
    required this.name,
    required this.id,
    this.body,
    this.server,
    this.rule,
    this.srsUrl,
    this.enabled = true,
  });
  final String name;
  final String id;
  final Map<String, dynamic>? body;
  final String? server;
  final Map<String, dynamic>? rule;
  final String? srsUrl;

  @override
  final bool enabled;

  @override
  String get kind => 'srs';

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'srs',
        'name': name,
        'id': id,
        if (srsUrl != null) 'srsUrl': srsUrl,
        if (server != null) 'server': server,
        if (rule != null) 'rule': _copyMap(rule!),
        if (body != null) 'body': _copyMap(body!),
        if (!enabled) 'enabled': false,
      };

  @override
  DnsRuleSrs withEnabled(bool enabled) => copyWith(enabled: enabled);

  DnsRuleSrs copyWith({
    String? name,
    String? id,
    Map<String, dynamic>? body,
    String? server,
    Map<String, dynamic>? rule,
    String? srsUrl,
    bool? enabled,
  }) =>
      DnsRuleSrs(
        name: name ?? this.name,
        id: id ?? this.id,
        body: body ?? this.body,
        server: server ?? this.server,
        rule: rule ?? this.rule,
        srsUrl: srsUrl ?? this.srsUrl,
        enabled: enabled ?? this.enabled,
      );

  @override
  bool operator ==(Object other) =>
      other is DnsRuleSrs &&
      other.name == name &&
      other.id == id &&
      other.server == server &&
      other.srsUrl == srsUrl &&
      other.enabled == enabled &&
      _eq.equals(other.body, body) &&
      _eq.equals(other.rule, rule);

  @override
  int get hashCode => Object.hash('srs', name, id, server, srsUrl, enabled,
      _eq.hash(body), _eq.hash(rule));
}

class DnsRulePreset extends DnsRuleRef {
  const DnsRulePreset({required this.presetId, this.enabled = true});
  final String presetId;

  /// §033 — «мёртвое» для активного preset'а, но позиционный anchor
  /// mirror-группы в build_config; сохраняется как есть, не чистится.
  @override
  final bool enabled;

  @override
  String get kind => 'preset';

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'preset', 'presetId': presetId, 'enabled': enabled};

  @override
  DnsRulePreset withEnabled(bool enabled) => copyWith(enabled: enabled);

  DnsRulePreset copyWith({String? presetId, bool? enabled}) => DnsRulePreset(
      presetId: presetId ?? this.presetId, enabled: enabled ?? this.enabled);

  @override
  bool operator ==(Object other) =>
      other is DnsRulePreset &&
      other.presetId == presetId &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash('preset', presetId, enabled);
}

class DnsRuleTemplate extends DnsRuleRef {
  const DnsRuleTemplate({required this.name, this.enabled = true});
  final String name;

  @override
  final bool enabled;

  @override
  String get kind => 'template';

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'template', 'name': name, 'enabled': enabled};

  @override
  DnsRuleTemplate withEnabled(bool enabled) => copyWith(enabled: enabled);

  DnsRuleTemplate copyWith({String? name, bool? enabled}) => DnsRuleTemplate(
      name: name ?? this.name, enabled: enabled ?? this.enabled);

  @override
  bool operator ==(Object other) =>
      other is DnsRuleTemplate &&
      other.name == name &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash('template', name, enabled);
}
