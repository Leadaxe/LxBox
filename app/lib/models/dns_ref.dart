// ===========================================================================
// §294 — storage-level typed model для `dns_options.servers[]` и
// `dns_options.rules[]` (kind-discriminated refs, §043/§033).
//
// Зачем: до §294 обе секции жили как сырые `List<Map<String,dynamic>>` без
// модели и без write-валидации — Debug `PUT /settings/dns_options/servers`
// писал verbatim, асимметрично с типизированным `/rules` (sealed CustomRule).
//
// Что это НЕ трогает (осознанно, см. spec §294):
// - render-view `ResolvedServer` + резолвер `resolveDisplayedServers`
//   (screens/) — downstream VIEW, остаётся как есть; модель лишь типизирует
//   сырой ref, который резолвер продолжает читать `List<Map>`;
// - template-view `TemplateDnsServerEntry`/`DnsOptionsModel`
//   (parser_config.dart) — это template-сторона (canonical), другой JSON;
// - resolver-owned migration/orphan-cleanup/auto-discover — остаётся в
//   резолвере (модель НЕ роняет orphan'ы, чтобы не было двойного drop'а);
// - форма на диске НЕ мигрируется — `toJson` байт-совместим (§221 backup).
//
// Дискриминатор — строковый `kind` (как в JSON и как резолвер уже матчит
// `kind == 'inline'`); модель в `lib/models/` не тянет `ServerKind` из
// `screens/` (обратная зависимость слоёв запрещена).
//
// `fromJson` ТОЛЕРАНТЕН на чтение (не бросает): старые инсталляции и
// pre-043 legacy full-body снапшоты не должны падать на cold-start — вернёт
// null, вызывающий пропускает (как резолвер молча дропает unknown-kind).
// Строгость — ТОЛЬКО на Debug write-пути (там `fromJsonStrict` бросает).
// ===========================================================================

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
/// Порядок ключей в [toJson] совпадает с выводом резолвера
/// (`enabled, kind, tag, …`) — round-trip байт-совместим.
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

  /// Толерантный парс — вернёт null на legacy full-body (нет `kind`),
  /// unknown-kind, отсутствующий/пустой `tag`, inline без Map-`body`.
  /// Зеркалит фильтр резолвера (`dns_servers.dart` step-2), чтобы модель и
  /// резолвер дропали одно и то же.
  static DnsServerRef? fromJson(Map<String, dynamic> j) {
    final kind = j['kind'];
    final tag = j['tag']?.toString();
    if (kind is! String || tag == null || tag.isEmpty) return null;
    final enabled = j['enabled'] != false; // default true
    final description = j['description']?.toString();
    switch (kind) {
      case 'inline':
        final body = j['body'];
        if (body is! Map) return null; // malformed — как резолвер
        return DnsServerInline(
          enabled: enabled,
          tag: tag,
          body: body.cast<String, dynamic>(),
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
          varValues: vv is Map
              ? {
                  for (final e in vv.entries)
                    e.key.toString(): e.value.toString()
                }
              : const {},
          description: description,
        );
      default:
        return null; // legacy/unknown — dropped
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

  final Map<String, dynamic> body;

  @override
  String get kind => 'inline';

  @override
  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'kind': 'inline',
        'tag': tag,
        'body': body,
        if (description != null) 'description': description,
      };

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
}

class DnsServerPreset extends DnsServerRef {
  const DnsServerPreset({
    required super.enabled,
    required super.tag,
    super.description,
  });

  @override
  String get kind => 'preset';

  @override
  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'kind': 'preset',
        'tag': tag,
        if (description != null) 'description': description,
      };

  DnsServerPreset copyWith({bool? enabled, String? tag, String? description}) =>
      DnsServerPreset(
        enabled: enabled ?? this.enabled,
        tag: tag ?? this.tag,
        description: description ?? this.description,
      );
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
        if (varValues.isNotEmpty) 'varValues': varValues,
        if (description != null) 'description': description,
      };

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
}

// ─── Rules ──────────────────────────────────────────────────────────────────

/// Один ref из `dns_options.rules[]`. Четыре kind'а с РАЗНЫМИ identity-ключами:
///   inline `{kind, name, rule}` · srs `{kind, name, id, body?}` ·
///   preset `{kind, presetId, enabled?}` · template `{kind, name}`.
/// Preset — позиционный якорь mirror-группы: «мёртвое» поле `enabled`
/// сохраняется как есть (build_config anchor-семантика), НЕ чистится.
sealed class DnsRuleRef {
  const DnsRuleRef();

  String get kind;
  Map<String, dynamic> toJson();

  /// Толерантный парс (не бросает; unknown/legacy → null, дропается как в
  /// резолвере `dns_rules.dart`).
  static DnsRuleRef? fromJson(Map<String, dynamic> j) {
    final kind = j['kind'];
    if (kind is! String) return null;
    switch (kind) {
      case 'inline':
        final name = j['name']?.toString();
        final rule = j['rule'];
        if (name == null || name.isEmpty || rule is! Map) return null;
        return DnsRuleInline(name: name, rule: rule.cast<String, dynamic>());
      case 'srs':
        final id = j['id']?.toString();
        final name = j['name']?.toString();
        if (id == null || id.isEmpty || name == null || name.isEmpty) {
          return null;
        }
        final body = j['body'];
        return DnsRuleSrs(
          name: name,
          id: id,
          body: body is Map ? body.cast<String, dynamic>() : null,
        );
      case 'preset':
        final pid = j['presetId']?.toString();
        if (pid == null || pid.isEmpty) return null;
        return DnsRulePreset(presetId: pid, enabled: j['enabled'] != false);
      case 'template':
        final name = j['name']?.toString();
        if (name == null || name.isEmpty) return null;
        return DnsRuleTemplate(name: name);
      default:
        return null; // legacy 'user'/'rule'/unknown — dropped
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
  const DnsRuleInline({required this.name, required this.rule});
  final String name;
  final Map<String, dynamic> rule;

  @override
  String get kind => 'inline';

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'inline', 'name': name, 'rule': rule};

  DnsRuleInline copyWith({String? name, Map<String, dynamic>? rule}) =>
      DnsRuleInline(name: name ?? this.name, rule: rule ?? this.rule);
}

class DnsRuleSrs extends DnsRuleRef {
  const DnsRuleSrs({required this.name, required this.id, this.body});
  final String name;
  final String id;
  final Map<String, dynamic>? body;

  @override
  String get kind => 'srs';

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'srs',
        'name': name,
        'id': id,
        if (body != null) 'body': body,
      };

  DnsRuleSrs copyWith({String? name, String? id, Map<String, dynamic>? body}) =>
      DnsRuleSrs(
          name: name ?? this.name, id: id ?? this.id, body: body ?? this.body);
}

class DnsRulePreset extends DnsRuleRef {
  const DnsRulePreset({required this.presetId, this.enabled = true});
  final String presetId;

  /// §033 — «мёртвое» для активного preset'а, но позиционный anchor
  /// mirror-группы в build_config; сохраняется как есть, не чистится.
  final bool enabled;

  @override
  String get kind => 'preset';

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'preset', 'presetId': presetId, 'enabled': enabled};

  DnsRulePreset copyWith({String? presetId, bool? enabled}) => DnsRulePreset(
      presetId: presetId ?? this.presetId, enabled: enabled ?? this.enabled);
}

class DnsRuleTemplate extends DnsRuleRef {
  const DnsRuleTemplate({required this.name});
  final String name;

  @override
  String get kind => 'template';

  @override
  Map<String, dynamic> toJson() => {'kind': 'template', 'name': name};

  DnsRuleTemplate copyWith({String? name}) =>
      DnsRuleTemplate(name: name ?? this.name);
}
