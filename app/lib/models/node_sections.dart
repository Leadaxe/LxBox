/// §435 — секции узла (контракт ## 13, `contract/docs/NODE_SECTIONS.md`):
/// фрагмент конфига, который свободный узел носит с собой — правила маршрута
/// и DNS-записи. Хранится в форме ONE_NAMESPACE §2 (`kind`/`name`|`tag`/
/// `enabled`/`num`/`body`), с плейсхолдерами `@self`/`@{self}` **как есть**;
/// подстановка финального тега — при сборке и при показе
/// ([substituteSelfPlaceholder]).
///
/// Модель типизирована теми же классами, что корневые списки (`CustomRule`,
/// `DnsServerInline`, `DnsRuleInline`): экран Routing показывает `summary()`,
/// DNS-экран рендерит тело тем же кодом. Перевод в запись и обратно — кодек
/// `record_codec.dart`, будущий корневой парсер 1.0.
library;

import 'custom_rule.dart';
import 'dns_ref.dart';
import 'record_codec.dart';

/// Номер на оси порядка для правила узла без `num` (NODE_SECTIONS.md §3):
/// перед якорем `private-ips` (950) — подсеть tailnet и подсети за пиром
/// должны матчиться раньше общих правил.
const int kNodeRuleDefaultNum = 945;

final class NodeSections {
  const NodeSections({
    this.rules = const [],
    this.dnsServers = const [],
    this.dnsRules = const [],
  });

  /// Правила маршрута узла — только `inline` | `srs`.
  final List<CustomRule> rules;

  /// DNS-серверы узла — только пользовательские (запись `kind: user`).
  final List<DnsServerInline> dnsServers;

  /// DNS-правила узла — только пользовательские (запись `kind: user`).
  final List<DnsRuleInline> dnsRules;

  bool get isEmpty => rules.isEmpty && dnsServers.isEmpty && dnsRules.isEmpty;
  bool get isNotEmpty => !isEmpty;

  int get recordCount => rules.length + dnsServers.length + dnsRules.length;

  /// Форма §2 ONE_NAMESPACE. Пустые списки не пишутся; пустые секции = `{}`
  /// (вызывающий такое поле не пишет вовсе).
  Map<String, dynamic> toJson() => {
        if (rules.isNotEmpty) 'rules': [for (final r in rules) ruleToRecord(r)],
        if (dnsServers.isNotEmpty || dnsRules.isNotEmpty)
          'dns': {
            if (dnsServers.isNotEmpty)
              'servers': [for (final s in dnsServers) dnsServerToRecord(s)],
            if (dnsRules.isNotEmpty)
              'rules': [for (final r in dnsRules) dnsRuleToRecord(r)],
          },
      };

  /// Чтение формы §2. Не бросает: чужой `kind`, битая форма записи —
  /// в [dropped] (текст для UI редактора узла), незнакомые ключи `body` — в
  /// [unknownKeys]. `null` — поля нет, оно не объект или все списки пусты.
  static NodeSections? fromJson(
    Object? j, {
    List<String>? dropped,
    List<String>? unknownKeys,
  }) {
    if (j is! Map) return null;
    final m = j.cast<String, dynamic>();

    final rules = <CustomRule>[];
    final rawRules = m['rules'];
    if (rawRules is List) {
      for (var i = 0; i < rawRules.length; i++) {
        final rec = rawRules[i];
        if (rec is! Map) {
          dropped?.add('rules[$i]: not an object');
          continue;
        }
        final read = ruleFromRecord(rec.cast<String, dynamic>());
        final r = read.value;
        if (r == null) {
          dropped?.add('rules[$i]: ${read.dropped}');
          continue;
        }
        // NODE_SECTIONS.md §1 — в секции допустимы только inline | srs.
        if (r.kind != CustomRuleKind.inline && r.kind != CustomRuleKind.srs) {
          dropped?.add(
              'rules[$i]: kind "${r.kind.name}" is not allowed in node sections');
          continue;
        }
        if (read.unknownKeys.isNotEmpty) {
          unknownKeys?.addAll(read.unknownKeys.map((k) => 'rules[$i].body.$k'));
        }
        rules.add(r);
      }
    }

    final dnsServers = <DnsServerInline>[];
    final dnsRules = <DnsRuleInline>[];
    final dns = m['dns'];
    if (dns is Map) {
      final rawServers = dns['servers'];
      if (rawServers is List) {
        for (var i = 0; i < rawServers.length; i++) {
          final rec = rawServers[i];
          if (rec is! Map) {
            dropped?.add('dns.servers[$i]: not an object');
            continue;
          }
          final read = dnsServerFromRecord(rec.cast<String, dynamic>());
          final s = read.value;
          if (s == null) {
            dropped?.add('dns.servers[$i]: ${read.dropped}');
            continue;
          }
          if (s is! DnsServerInline) {
            dropped?.add(
                'dns.servers[$i]: kind "${s.kind}" is not allowed in node sections');
            continue;
          }
          dnsServers.add(s);
        }
      }
      final rawDnsRules = dns['rules'];
      if (rawDnsRules is List) {
        for (var i = 0; i < rawDnsRules.length; i++) {
          final rec = rawDnsRules[i];
          if (rec is! Map) {
            dropped?.add('dns.rules[$i]: not an object');
            continue;
          }
          final read = dnsRuleFromRecord(rec.cast<String, dynamic>());
          final r = read.value;
          if (r == null) {
            dropped?.add('dns.rules[$i]: ${read.dropped}');
            continue;
          }
          if (r is! DnsRuleInline) {
            dropped?.add(
                'dns.rules[$i]: kind "${r.kind}" is not allowed in node sections');
            continue;
          }
          dnsRules.add(r);
        }
      }
    }

    final out = NodeSections(
      rules: rules,
      dnsServers: dnsServers,
      dnsRules: dnsRules,
    );
    return out.isEmpty ? null : out;
  }

  /// Секции с подставленным финальным тегом узла (NODE_SECTIONS.md §2).
  /// Подстановка идёт по JSON-записям, поэтому покрывает все строковые
  /// значения на любой глубине без пер-типовых веток.
  NodeSections substituteSelf(String finalTag) {
    if (isEmpty) return this;
    final json = substituteSelfPlaceholder(toJson(), finalTag);
    return NodeSections.fromJson(json) ?? const NodeSections();
  }

  NodeSections copyWith({
    List<CustomRule>? rules,
    List<DnsServerInline>? dnsServers,
    List<DnsRuleInline>? dnsRules,
  }) =>
      NodeSections(
        rules: rules ?? this.rules,
        dnsServers: dnsServers ?? this.dnsServers,
        dnsRules: dnsRules ?? this.dnsRules,
      );
}

/// Плейсхолдер финального тега узла (NODE_SECTIONS.md §2), ровно две формы:
/// строка целиком `@self` и `@{self}` внутри строки любое число раз.
/// Подставляется во все строковые значения на любой глубине; ключи объектов
/// не трогаются; `@selfish`, `@self_dns` и прочие `@…` остаются как есть.
/// Экранирования нет.
Object? substituteSelfPlaceholder(Object? json, String tag) {
  if (json is String) {
    if (json == kSelfPlaceholder) return tag;
    if (json.contains(kSelfInlinePlaceholder)) {
      return json.replaceAll(kSelfInlinePlaceholder, tag);
    }
    return json;
  }
  if (json is Map) {
    return <String, dynamic>{
      for (final e in json.entries)
        e.key as String: substituteSelfPlaceholder(e.value, tag),
    };
  }
  if (json is List) {
    return [for (final v in json) substituteSelfPlaceholder(v, tag)];
  }
  return json;
}

const String kSelfPlaceholder = '@self';
const String kSelfInlinePlaceholder = '@{self}';

/// Есть ли в значении плейсхолдер (для подписи «после подстановки» и тестов).
bool containsSelfPlaceholder(Object? json) {
  if (json is String) {
    return json == kSelfPlaceholder || json.contains(kSelfInlinePlaceholder);
  }
  if (json is Map) return json.values.any(containsSelfPlaceholder);
  if (json is List) return json.any(containsSelfPlaceholder);
  return false;
}
