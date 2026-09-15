/// Кодек DNS-записей: [DnsServerRef] ↔ `dns.servers[]`, [DnsRuleRef] ↔
/// `dns.rules[]` контракта 1.0 (`contract/docs/ONE_NAMESPACE.md` §1, спека
/// §439 §1.2).
///
/// Словарь записи: пользовательский сервер и правило — `kind: user` (у модели
/// `inline`), тело — `body`; preset-сервер адресуется `ref` формы
/// `<preset_id>:<тег внутри пресета>` — это тег конфига сервера
/// ([dnsServerPresetRef]); значения переменных template-сервера — `vars`.
/// Виды LxBox (`srs`, `template` у правил) пишутся в форме модели.
///
/// Тег DNS-сервера — поле записи, в `body` его нет. Строки (`tag`, `name`,
/// `description`) не режутся: путь хранения переносит их как есть.
///
/// Чтение терпимо: чужой `kind` и битая форма — [RecordRead.dropped].
/// Незнакомые ключи корня записи игнорируются, `body` переносится целиком.
library;

import '../dns_ref.dart';
import 'record_read.dart';

// ─── DNS-серверы ─────────────────────────────────────────────────────────────

/// Ref DNS-сервера LxBox → запись 1.0.
Map<String, dynamic> dnsServerToRecord(DnsServerRef s) => switch (s) {
      DnsServerInline() => {
          'kind': 'user',
          'tag': s.tag,
          'enabled': s.enabled,
          'body': _copyMap(s.body)..remove('tag'),
          if (s.description != null) 'description': s.description,
        },
      // §438 — у записи preset тега нет, её идентичность — `ref` формы
      // `<preset_id>:<tag>` (BACKUP.md §2), [dnsServerPresetRef].
      DnsServerPreset() => {
          'kind': 'preset',
          'ref': dnsServerPresetRef(s),
          'enabled': s.enabled,
          if (s.description != null) 'description': s.description,
        },
      DnsServerTemplate() => {
          'kind': 'template',
          'tag': s.tag,
          'enabled': s.enabled,
          if (s.varValues.isNotEmpty)
            'vars': Map<String, String>.of(s.varValues),
          if (s.description != null) 'description': s.description,
        },
    };

/// Запись 1.0 → ref DNS-сервера LxBox.
RecordRead<DnsServerRef> dnsServerFromRecord(Map<String, dynamic> j) {
  final kind = j['kind'];
  if (kind is! String || kind.isEmpty) {
    return const RecordRead.drop('dns server without kind');
  }
  // preset: `ref` ([dnsServerPresetFromRef]); `tag` у preset — прежняя форма
  // этого кодека (тег конфига), запасной ход.
  var presetId = '';
  String? tag;
  if (kind == 'preset') {
    final parsed = dnsServerPresetFromRef(
        _nonEmpty(j['ref']) ?? _nonEmpty(j['tag']) ?? '');
    presetId = parsed?.presetId ?? '';
    tag = parsed?.tag;
  } else {
    tag = _nonEmpty(j['tag']);
  }
  if (tag == null) return RecordRead.drop('dns server ($kind) without tag');
  final enabled = j['enabled'] != false;
  final rawDescription = j['description'];
  final description = rawDescription is String ? rawDescription : null;
  switch (kind) {
    case 'user':
      final body = j['body'];
      if (body is! Map) {
        return RecordRead.drop('dns server "$tag": body is not an object');
      }
      return RecordRead.ok(DnsServerInline(
        enabled: enabled,
        tag: tag,
        body: _copyMap(body)..remove('tag'),
        description: description,
      ));
    case 'preset':
      return RecordRead.ok(DnsServerPreset(
        enabled: enabled,
        tag: tag,
        presetId: presetId,
        description: description,
      ));
    case 'template':
      final vars = j['vars'];
      return RecordRead.ok(DnsServerTemplate(
        enabled: enabled,
        tag: tag,
        // null-значение — «не задано» (дефолт переменной), ключ не заводим.
        varValues: vars is Map
            ? {
                for (final e in vars.entries)
                  if (e.value != null) e.key.toString(): e.value.toString(),
              }
            : const {},
        description: description,
      ));
    default:
      return RecordRead.drop('dns server "$tag": unknown kind "$kind"');
  }
}

/// `ref` записи preset-сервера DNS: `<preset_id>:<тег внутри пресета>`
/// (BACKUP.md §2). Тег модели — тег конфига, пространство пресета в нём уже
/// есть ([DnsServerPreset]), поэтому `ref` совпадает с ним; повтор
/// пространства (ранние сборки 2.23.3 писали `ru-direct:ru-direct:dns_ru`)
/// снимается. Пресет не известен — `ref` = тег.
String dnsServerPresetRef(DnsServerPreset s) {
  final presetId = s.presetId;
  if (presetId.isEmpty) return s.tag;
  return '$presetId:${_presetLocalTag(presetId, s.tag)}';
}

/// `ref` preset-сервера DNS → пресет и тег модели (тег конфига), обратное
/// [dnsServerPresetRef]: `ref` делится по ПЕРВОМУ `:` (id пресета двоеточия
/// не содержит, тег внутри пресета — может); `ref` без `:` — тег целиком,
/// пресет не известен. Терпимо к повтору пространства ранних сборок 2.23.3:
/// `ru-direct:ru-direct:dns_ru` читается как `ru-direct:dns_ru`. null — тега
/// нет.
({String presetId, String tag})? dnsServerPresetFromRef(String ref) {
  final at = ref.indexOf(':');
  if (at <= 0) {
    final tag = at < 0 ? ref : ref.substring(1);
    return tag.isEmpty ? null : (presetId: '', tag: tag);
  }
  final presetId = ref.substring(0, at);
  final local = _presetLocalTag(presetId, ref.substring(at + 1));
  if (local.isEmpty) return null;
  return (presetId: presetId, tag: '$presetId:$local');
}

/// `<preset_id>` из `ref` preset-сервера DNS: часть до ПЕРВОГО `:`; пусто,
/// если `:` нет.
String presetIdOfDnsServerRef(String ref) =>
    dnsServerPresetFromRef(ref)?.presetId ?? '';

/// Тег внутри пресета [presetId]: [tag] без ведущих `<preset_id>:` (одного
/// или повторённых).
String _presetLocalTag(String presetId, String tag) {
  final prefix = '$presetId:';
  var local = tag;
  while (local.startsWith(prefix)) {
    local = local.substring(prefix.length);
  }
  return local;
}

// ─── DNS-правила ─────────────────────────────────────────────────────────────

/// Ref DNS-правила LxBox → запись 1.0. Пользовательская запись — `kind: user`,
/// тело — правило sing-box целиком (`server` внутри), `enabled` пишется всегда.
/// `srs` — форма модели: поля §033 (`srsUrl`, `server`, `rule`) верхнего
/// уровня сборка читает раньше `body`.
Map<String, dynamic> dnsRuleToRecord(DnsRuleRef r) => switch (r) {
      DnsRuleInline() => {
          'kind': 'user',
          'name': r.name,
          'enabled': r.enabled,
          'body': _copyMap(r.rule),
        },
      DnsRuleSrs() => {
          'kind': 'srs',
          'name': r.name,
          'id': r.id,
          if (r.srsUrl != null) 'srsUrl': r.srsUrl,
          if (r.server != null) 'server': r.server,
          if (r.rule != null) 'rule': _copyMap(r.rule!),
          if (r.body != null) 'body': _copyMap(r.body!),
          if (!r.enabled) 'enabled': false,
        },
      DnsRulePreset() => {
          'kind': 'preset',
          'ref': r.presetId,
          'enabled': r.enabled,
        },
      DnsRuleTemplate() => {
          'kind': 'template',
          'name': r.name,
          'enabled': r.enabled,
        },
    };

/// Запись 1.0 → ref DNS-правила LxBox.
RecordRead<DnsRuleRef> dnsRuleFromRecord(Map<String, dynamic> j) {
  final kind = j['kind'];
  if (kind is! String || kind.isEmpty) {
    return const RecordRead.drop('dns rule without kind');
  }
  final rawName = j['name'];
  final name = rawName is String ? rawName : '';
  switch (kind) {
    case 'user':
      final body = j['body'];
      if (body is! Map) {
        return RecordRead.drop('dns rule "$name": body is not an object');
      }
      return RecordRead.ok(DnsRuleInline(
        name: name,
        rule: _copyMap(body),
        enabled: j['enabled'] != false,
      ));
    case 'srs':
      final id = _nonEmpty(j['id']);
      if (id == null) return RecordRead.drop('dns rule "$name": srs without id');
      final body = j['body'];
      final server = j['server'];
      final rule = j['rule'];
      final srsUrl = j['srsUrl'];
      return RecordRead.ok(DnsRuleSrs(
        name: name,
        id: id,
        body: body is Map ? _copyMap(body) : null,
        server: server is String ? server : null,
        rule: rule is Map ? _copyMap(rule) : null,
        srsUrl: srsUrl is String ? srsUrl : null,
        enabled: j['enabled'] != false,
      ));
    case 'preset':
      final ref = _nonEmpty(j['ref']);
      if (ref == null) {
        return const RecordRead.drop('dns rule: preset without ref');
      }
      return RecordRead.ok(
          DnsRulePreset(presetId: ref, enabled: j['enabled'] != false));
    case 'template':
      if (name.isEmpty) {
        return const RecordRead.drop('dns rule: template without name');
      }
      // Вид LxBox: без ключа — выключено, как в форме хранения 2.23.2.
      return RecordRead.ok(
          DnsRuleTemplate(name: name, enabled: j['enabled'] == true));
    default:
      return RecordRead.drop('dns rule "$name": unknown kind "$kind"');
  }
}

// ─── helpers ─────────────────────────────────────────────────────────────────

/// Непустая строка как есть (без обрезки), иначе null.
String? _nonEmpty(Object? v) => v is String && v.isNotEmpty ? v : null;

/// Глубокая копия JSON-объекта: модель не делит карты с документом.
Map<String, dynamic> _copyMap(Map v) => {
      for (final e in v.entries) e.key.toString(): _copyJson(e.value),
    };

Object? _copyJson(Object? v) => switch (v) {
      Map() => _copyMap(v),
      List() => [for (final x in v) _copyJson(x)],
      _ => v,
    };
