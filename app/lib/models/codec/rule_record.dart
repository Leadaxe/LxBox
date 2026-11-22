/// Кодек правил маршрута: [CustomRule] ↔ запись `rules[]` контракта 1.0
/// (`contract/docs/ONE_NAMESPACE.md` §1, спека §439 §1.2).
///
/// **Запись = метаданные приложения + `body` = правило sing-box как есть.**
/// Метаданные — `kind`, `id`, `name`, `enabled`, `num`, `ref`, `vars`;
/// поля LxBox рядом с телом — `dns{}`, `resolve{}`, `update_interval_hours`
/// (srs, preset), `verbatim` (inline).
///
/// §757 (контракт 1.1.179) — `body` — дерево условий: `refs` пишутся внутри
/// простых правил тела, `kind` (`inline` | `srs`) выводится из дерева.
/// Читаются обе формы: `refs` / `ref` на записи (старая) переносятся в
/// корень тела. Какие ключи — условия, решает таблица условий реестра
/// (`ruleConditionTable`), списка ключей в кодеке нет.
///
/// Один кодек на хранение, бэкап, файл правил, секции узла и Debug API, поэтому
/// строки (`id`, `name`) не режутся: имя srs-правила — тег `rule_set` в
/// конфиге (§439 §2.3 п. 12).
///
/// Вид `json` (§225) в записи не живёт: [CustomRuleJson] пишется как
/// `inline` + `verbatim: true`, тело-объект — в `body`; текст, который
/// объектом не разбирается (битый JSON, массив), — маркер без `body`. Массив
/// раскладывает на записи вызывающий до кодека ([splitJsonRuleArrays], §439
/// В2).
///
/// Чтение терпимо: чужой `kind` и битая форма — [RecordRead.dropped], не
/// исключение; скаляр вместо списка читается списком; незнакомые ключи корня
/// записи игнорируются молча. Ключи `body` вне таблицы условий (на любом
/// уровне дерева) — в [RecordRead.unknownKeys]; с `unknownAsVerbatim`
/// inline-запись с ними читается [CustomRuleJson] с телом целиком.
library;

import 'dart:convert';

import '../../config/consts.dart' show kDirectOutboundTag;
import '../../services/contract/rule_conditions.dart';
import '../custom_rule.dart';
import '../rule_tree.dart';
import 'record_read.dart';

/// Текст тела [CustomRuleJson], прочитанного из записи.
const JsonEncoder _verbatimText = JsonEncoder.withIndent('  ');

/// §439 В2 — запись правила держит один объект sing-box, поэтому правило
/// вида json с массивом, в котором есть объекты, раскладывается до кодека на
/// правила по объекту: первое сохраняет `id` и имя, следующие — `<имя> #2`,
/// `<имя> #3`… с новым `id`; `enabled` и `num` общие (как экспорт 438).
/// Элементы-не-объекты отбрасываются (сборка их и так не эмитит), строка об
/// этом уходит в [notes]. Прочие правила, включая json, который массивом с
/// объектами не разбирается, идут как есть. Порядок сохраняется.
///
/// Один путь деления на хранение и миграцию формы 2.23.2.
List<CustomRule> splitJsonRuleArrays(
  Iterable<CustomRule> rules, {
  List<String>? notes,
}) {
  final out = <CustomRule>[];
  for (final r in rules) {
    final array = r is CustomRuleJson ? _arrayOf(r.json) : null;
    final items = array?.whereType<Map>().toList() ?? const <Map>[];
    if (items.isEmpty) {
      out.add(r);
      continue;
    }
    final skipped = array!.length - items.length;
    if (skipped > 0) {
      notes?.add('rule "${r.name}": $skipped non-object element(s) of the '
          'JSON array dropped');
    }
    for (var i = 0; i < items.length; i++) {
      out.add(CustomRuleJson(
        id: i == 0 ? r.id : null,
        name: i == 0 ? r.name : '${r.name} #${i + 1}',
        enabled: r.enabled,
        orderNum: r.orderNum,
        json: _verbatimText.convert(items[i]),
      ));
    }
  }
  return out;
}

/// Массив из текста json-правила; прочее — null.
List<dynamic>? _arrayOf(String text) {
  try {
    final decoded = jsonDecode(text);
    return decoded is List ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// Правило LxBox → запись 1.0.
Map<String, dynamic> ruleToRecord(CustomRule r) {
  final out = <String, dynamic>{
    'kind': r is CustomRuleJson ? 'inline' : r.kind.name,
    'id': r.id,
    'name': r.name,
    'enabled': r.enabled,
    if (r.orderNum != null) 'num': r.orderNum,
  };
  switch (r) {
    case CustomRuleTree():
      // §757 — `refs` внутри простых правил тела (`ruleTreeBodyToJson`),
      // на записи их больше нет; `kind` — выведенный из дерева.
      if (r.kind == CustomRuleKind.srs &&
          r.updateIntervalHours != kDefaultSrsTtlHours) {
        out['update_interval_hours'] = r.updateIntervalHours;
      }
      out['body'] = ruleTreeBodyToJson(r.body);
    case CustomRulePreset():
      out['ref'] = r.presetId;
      if (r.varsValues.isNotEmpty) {
        out['vars'] = Map<String, String>.of(r.varsValues);
      }
      // §757 (§180) — период обновления наборов пресета: хранится и
      // провозится.
      if (r.updateIntervalHours != null) {
        out['update_interval_hours'] = r.updateIntervalHours;
      }
    case CustomRuleJson():
      out['verbatim'] = true;
      final body = _objectOf(r.json);
      if (body != null) out['body'] = body;
  }
  if (r.dns != null) out['dns'] = r.dns!.toJson();
  if (r.resolve != null) out['resolve'] = r.resolve!.toJson();
  return out;
}

/// Запись 1.0 → правило LxBox.
///
/// [unknownAsVerbatim] — путь хранения: inline-запись, тело которой модель не
/// выражает (незнакомый матчер, `rule_set`, `action` кроме `reject`,
/// `method`), читается [CustomRuleJson] с телом целиком, ключи всё равно
/// перечислены в [RecordRead.unknownKeys]. Без флага (секции узла, импорт)
/// читается типизированное правило, ключи потеряны, решает вызывающий.
RecordRead<CustomRule> ruleFromRecord(
  Map<String, dynamic> j, {
  bool unknownAsVerbatim = false,
}) {
  final kind = j['kind'];
  if (kind is! String || kind.isEmpty) {
    return const RecordRead.drop('rule without kind');
  }
  final rawId = j['id'];
  final id = rawId is String && rawId.trim().isNotEmpty ? rawId : null;
  final rawName = j['name'];
  final name = rawName is String ? rawName : '';
  final enabled = j['enabled'] != false;
  final rawNum = j['num'];
  final orderNum = rawNum is num ? rawNum.toInt() : null;

  switch (kind) {
    case 'inline':
    case 'srs':
      final rawBody = j['body'];
      final body = rawBody is Map ? rawBody.cast<String, dynamic>() : null;
      if (rawBody != null && body == null) {
        return RecordRead.drop('rule "$name": body is not an object');
      }
      if (kind == 'inline' && j['verbatim'] == true) {
        return RecordRead.ok(CustomRuleJson(
          id: id,
          name: name,
          enabled: enabled,
          orderNum: orderNum,
          json: body == null ? '' : _verbatimText.convert(body),
        ));
      }
      final table = ruleConditionTable;
      final b = body ?? const <String, dynamic>{};
      // §757 — ключи вне таблицы условий и служебных (на любом уровне
      // дерева) и цель, которую модель не выражает: `action` кроме
      // `reject` (§438 — самостоятельный эффект ядра, прочитанный правилом
      // на direct-out, молча стал бы маршрутом) и `method`.
      final unknown = <String>{};
      final cleaned = _cleanNode(b, table, unknown, isRoot: true);
      if (b.containsKey('action') && b['action'] != 'reject') {
        unknown.add('action');
      }
      if (b.containsKey('method')) unknown.add('method');
      final unknownKeys = unknown.toList()..sort();
      RecordRead<CustomRule> verbatim() => RecordRead.ok(
            CustomRuleJson(
              id: id,
              name: name,
              enabled: enabled,
              orderNum: orderNum,
              json: _verbatimText.convert(b),
            ),
            unknownKeys: unknownKeys,
          );
      if (kind == 'inline' && unknownAsVerbatim && unknownKeys.isNotEmpty) {
        return verbatim();
      }
      // §757 — тело-дерево; ссылки старой формы (на записи) переносятся в
      // корень, `refs` в дереве главнее.
      final tree = parseRuleTreeBody(
        cleaned,
        table,
        recordRefs: legacyRecordRefs(j),
      );
      if (tree == null) {
        // Структура не дерево (`logical` без `mode` / детей, цель не у
        // корня) — хранилище держит тело как есть, прочие пути отказывают.
        if (unknownAsVerbatim) return verbatim();
        return RecordRead.drop('rule "$name": body is not a rule');
      }
      return RecordRead.ok(
        CustomRuleTree(
          id: id,
          name: name,
          enabled: enabled,
          orderNum: orderNum,
          root: tree.root,
          outbound: _outboundOf(b),
          dns: RuleDns.fromJson(j['dns']),
          resolve: RuleResolve.fromJson(j['resolve']),
          updateIntervalHours:
              CustomRuleTree.ttlHoursFrom(j['update_interval_hours']),
        ),
        unknownKeys: unknownKeys,
      );
    case 'preset':
      final ref = j['ref'];
      final vars = j['vars'];
      return RecordRead.ok(CustomRulePreset(
        id: id,
        name: name,
        enabled: enabled,
        orderNum: orderNum,
        presetId: ref is String ? ref : '',
        varsValues: vars is Map
            ? {
                for (final e in vars.entries)
                  e.key.toString(): e.value?.toString() ?? '',
              }
            : const {},
        // §757 (§180) — `null`: поля нет, действует период шаблона.
        updateIntervalHours: j['update_interval_hours'] is num
            ? CustomRuleTree.ttlHoursFrom(j['update_interval_hours'])
            : null,
      ));
    default:
      return RecordRead.drop('rule "$name": unknown kind "$kind"');
  }
}

/// Цель из тела: `action: reject` → [kOutboundReject]; строковый `outbound`
/// как есть (пустой тоже); без ключа — цель по умолчанию.
String _outboundOf(Map<String, dynamic> body) {
  if (body['action'] == 'reject') return kOutboundReject;
  final o = body['outbound'];
  return o is String ? o : kDirectOutboundTag;
}

/// Текст правила вида json → объект тела; массив, скаляр и мусор → null.
Map<String, dynamic>? _objectOf(String text) {
  try {
    final decoded = jsonDecode(text);
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  } on FormatException {
    return null;
  }
}

/// Список строк из значения JSON: массив → элементы `toString()`; скаляр →
/// один элемент (sing-box принимает и строку, и массив). `null`/пусто → [].
List<String> _strList(Object? v) {
  if (v == null) return const [];
  if (v is List) return [for (final e in v) e.toString()];
  if (v is String) return v.isEmpty ? const [] : [v];
  return [v.toString()];
}

/// §757 — узел тела без ключей вне таблицы условий и служебных (они — в
/// [unknown]) и со значениями условий в форме дерева: скаляр вместо списка —
/// списком, элементы — `toString()`, порты — только числа 0–65535, флаг —
/// `== true` (терпимое чтение, как у кодека до §757). Цель (`outbound`,
/// `action`, `method`) остаётся у корня.
Map<String, dynamic> _cleanNode(
  Map<String, dynamic> m,
  RuleConditionTable table,
  Set<String> unknown, {
  required bool isRoot,
}) {
  final out = <String, dynamic>{};
  for (final e in m.entries) {
    final k = e.key;
    final v = e.value;
    if (RuleConditionTable.targetKeys.contains(k)) {
      out[k] = v;
      continue;
    }
    if (k == RuleConditionTable.kRules && v is List) {
      out[k] = [
        for (final c in v)
          c is Map
              ? _cleanNode(c.cast<String, dynamic>(), table, unknown,
                  isRoot: false)
              : c,
      ];
      continue;
    }
    if (k == RuleConditionTable.kInvert) {
      out[k] = v == true;
      continue;
    }
    if (RuleConditionTable.serviceKeys.contains(k) ||
        k == RuleConditionTable.kRuleSet) {
      out[k] = v;
      continue;
    }
    final desc = table.key(k);
    if (desc == null) {
      unknown.add(k);
      continue;
    }
    if (desc.isBool) {
      out[k] = v == true;
    } else if (desc.isIntList) {
      out[k] = [
        for (final s in _strList(v))
          if (int.tryParse(s.trim()) case final p? when p >= 0 && p <= 65535)
            p,
      ];
    } else if (k == kRuleKeyWifiBssid) {
      // §051 — ядро сравнивает BSSID с учётом регистра: нижний регистр.
      out[k] = [for (final b in _strList(v)) b.trim().toLowerCase()];
    } else {
      out[k] = _strList(v);
    }
  }
  return out;
}
