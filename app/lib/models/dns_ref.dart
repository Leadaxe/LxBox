// ===========================================================================
// §294 — модель DNS-записей (виды §043/§033).
//
// §439 A1 — единственный рабочий формат DNS выше хранения. Резолверы, сборка,
// экраны и контроллер DNS работают только с этими типами. Хранение (`dns{}`
// в `settings_storage/network.dart`), бэкап, файл правил, секции узла и
// Debug `PUT /settings/dns_options/*` пишут и читают запись 1.0 кодеком
// `codec/dns_record.dart`; форму 2.23.2 читают только замороженные читатели
// `storage_migration/legacy_form_v0.dart`. Своей сериализации у моделей нет.
//
// Семантика `enabled` при отсутствии ключа в записи (кодек):
// - сервер, inline- и srs-правило — включено (`enabled != false`);
// - template-правило — выключено (`enabled == true`, как читала сборка).
//
// Значения неизменяемы по договорённости: кодек копирует JSON-поддеревья,
// модель не делит карты с документом хранения.
//
// Дискриминатор — строковый `kind`; модель не тянет `ServerKind` из `screens/`
// (обратная зависимость слоёв запрещена).
// ===========================================================================

import 'package:collection/collection.dart';

const _eq = DeepCollectionEquality();

// ─── Servers ────────────────────────────────────────────────────────────────

/// Один DNS-сервер хранения (`dns.servers[]`; запись — `codec/dns_record.dart`).
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

  /// Та же запись с другим `enabled`.
  DnsServerRef withEnabled(bool enabled);
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
  final String presetId;

  @override
  String get kind => 'preset';

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

/// Одно DNS-правило хранения (`dns.rules[]`). Четыре вида с РАЗНЫМИ
/// identity-ключами: inline — имя и тело · srs — имя и `id` · preset —
/// `presetId` · template — имя; у всех — `enabled`.
/// Preset — позиционный якорь mirror-группы: его `enabled` сборка с
/// mirror-группой не читает, но значение сохраняется как есть.
sealed class DnsRuleRef {
  const DnsRuleRef();

  String get kind;

  /// Включено ли правило (отсутствие ключа — см. шапку файла).
  bool get enabled;

  /// Та же запись с другим `enabled`.
  DnsRuleRef withEnabled(bool enabled);
}

class DnsRuleInline extends DnsRuleRef {
  const DnsRuleInline({
    required this.name,
    required this.rule,
    this.enabled = true,
  });
  final String name;
  final Map<String, dynamic> rule;

  /// §435 — тумблер записи (ONE_NAMESPACE §1: `enabled` у DNS-правил); запись
  /// без ключа читается как «включено».
  @override
  final bool enabled;

  @override
  String get kind => 'inline';

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
/// `rule` / `srsUrl` — поля §033, их несут только старые записи: сборка берёт
/// их раньше `body`, тайл показывает `srsUrl`/`server`.
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
