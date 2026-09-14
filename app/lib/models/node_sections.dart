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

import 'package:collection/collection.dart';

import 'custom_rule.dart';
import 'dns_ref.dart';
import 'record_codec.dart';

/// Номер на оси порядка для правила узла без `num` (NODE_SECTIONS.md §3):
/// перед якорем `private-ips` (950) — подсеть tailnet и подсети за пиром
/// должны матчиться раньше общих правил.
const int kNodeRuleDefaultNum = 945;

/// Причины отбраковки записи секции (норма B3, `NODE_SECTIONS.md` §1) —
/// значения `reason` у `backup_section_record_dropped`. Перечень закрыт
/// контрактом: свои слова стороны заводить не вправе.
///
/// [kSectionDropKind] — вида записи у секции не бывает (или запись не
/// читается как запись этого вида); [kSectionDropRuleSet] — в теле правила
/// стоит `rule_set`; [kSectionDropUnknownKey] — в теле правила ключ, которого
/// эта сторона не держит (строгость LxBox, NODE_SECTIONS.md §1; detail
/// называет ключ); [kSectionDropNotAllowed] — узлу этого вида секции не
/// положены вовсе (ставит импорт, у модели секций такого случая нет).
const String kSectionDropKind = 'kind';
const String kSectionDropRuleSet = 'rule_set';
const String kSectionDropUnknownKey = 'unknown_key';
const String kSectionDropNotAllowed = 'not_allowed';

/// §438 — отброшенная запись секции: вид, причина из перечня B3 и текст для
/// человека (тот же, что уходит в `dropped`).
final class NodeSectionDrop {
  const NodeSectionDrop({
    required this.kind,
    required this.reason,
    required this.text,
  });

  final String kind;
  final String reason;
  final String text;
}

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
  ///
  /// §438 — [drops] получает те же отбраковки структурно (вид и причина по
  /// норме B3): импорт бэкапа называет их кодом с `reason`.
  static NodeSections? fromJson(
    Object? j, {
    List<String>? dropped,
    List<String>? unknownKeys,
    List<NodeSectionDrop>? drops,
  }) {
    if (j is! Map) return null;
    final m = j.cast<String, dynamic>();

    void drop(String text, Object? kind, String reason) {
      dropped?.add(text);
      drops?.add(NodeSectionDrop(
        kind: kind is String && kind.isNotEmpty ? kind : '?',
        reason: reason,
        text: text,
      ));
    }

    final rules = <CustomRule>[];
    final rawRules = m['rules'];
    if (rawRules is List) {
      for (var i = 0; i < rawRules.length; i++) {
        final rec = rawRules[i];
        if (rec is! Map) {
          drop('rules[$i]: not an object', null, kSectionDropKind);
          continue;
        }
        final record = _withSelfOutbound(rec.cast<String, dynamic>());
        final read = ruleFromRecord(record);
        final r = read.value;
        if (r == null) {
          drop('rules[$i]: ${read.dropped}', record['kind'], kSectionDropKind);
          continue;
        }
        // NODE_SECTIONS.md §1 — в секции допустимы только inline | srs.
        if (r.kind != CustomRuleKind.inline && r.kind != CustomRuleKind.srs) {
          drop('rules[$i]: kind "${r.kind.name}" is not allowed in node sections',
              r.kind.name, kSectionDropKind);
          continue;
        }
        // Норма лаунчера (14.09.2026, B3): ключ тела, который сторона не
        // переносит (`rule_set` — ссылка на набор конфига, и любой другой
        // незнакомый матчер), нельзя вырезать молча — без единственного
        // матчера правило стало бы match-all и завернуло бы весь трафик в
        // узел. Запись отбрасывается целиком, причина называет ключи.
        if (read.unknownKeys.isNotEmpty) {
          final keys = read.unknownKeys.join(', ');
          // §438 — причина по перечню B3: `rule_set` назван нормой; прочие
          // незнакомые ключи — строгость LxBox (NODE_SECTIONS.md §1), причина
          // `unknown_key` (ответ лаунчера 14.09.2026).
          drop(
            'rules[$i]: body keys not supported here: $keys',
            r.kind.name,
            read.unknownKeys.contains('rule_set')
                ? kSectionDropRuleSet
                : kSectionDropUnknownKey,
          );
          unknownKeys?.addAll(read.unknownKeys.map((k) => 'rules[$i].body.$k'));
          continue;
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
            drop('dns.servers[$i]: not an object', null, kSectionDropKind);
            continue;
          }
          final read = dnsServerFromRecord(rec.cast<String, dynamic>());
          final s = read.value;
          if (s == null) {
            drop('dns.servers[$i]: ${read.dropped}', rec['kind'],
                kSectionDropKind);
            continue;
          }
          if (s is! DnsServerInline) {
            drop(
                'dns.servers[$i]: kind "${s.kind}" is not allowed in node sections',
                s.kind,
                kSectionDropKind);
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
            drop('dns.rules[$i]: not an object', null, kSectionDropKind);
            continue;
          }
          final read = dnsRuleFromRecord(rec.cast<String, dynamic>());
          final r = read.value;
          if (r == null) {
            drop('dns.rules[$i]: ${read.dropped}', rec['kind'],
                kSectionDropKind);
            continue;
          }
          if (r is! DnsRuleInline) {
            drop(
                'dns.rules[$i]: kind "${r.kind}" is not allowed in node sections',
                r.kind,
                kSectionDropKind);
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

  static const _eq = ListEquality<Object>();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NodeSections &&
          _eq.equals(rules, other.rules) &&
          _eq.equals(dnsServers, other.dnsServers) &&
          _eq.equals(dnsRules, other.dnsRules));

  @override
  int get hashCode =>
      Object.hash(_eq.hash(rules), _eq.hash(dnsServers), _eq.hash(dnsRules));
}

/// Норма лаунчера (14.09.2026, B5): запись секции без `outbound` и без
/// `action` — правило ЭТОГО узла, цель дописывается `@self` (а не дефолт
/// `direct-out` корневого правила).
Map<String, dynamic> _withSelfOutbound(Map<String, dynamic> record) {
  final body = record['body'];
  if (body is! Map) return record;
  if (body.containsKey('outbound') || body.containsKey('action')) return record;
  return {
    ...record,
    'body': {...body.cast<String, dynamic>(), 'outbound': kSelfPlaceholder},
  };
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
