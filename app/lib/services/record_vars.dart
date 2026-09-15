/// §441 (SPEC 128 контракта) — значения переменных, которые живут в записи:
/// `dns.servers[kind=template].vars` и `rules[kind=preset].vars`.
///
/// Слой 5 (§439 §2.5): чистые функции над моделями и объявлениями шаблона
/// СВОЕЙ стороны. Кодек записей шаблона не знает и значения не трогает;
/// нормализацию зовут писатели — репозиторий на записи, миграция хранения,
/// импорт и экспорт LX Backup, редакторы.
///
/// Нормы (решения владельца 15.09.2026):
///
///  * **Н2** — законны только имена, объявленные носителем в шаблоне: сервер
///    с тем же тегом (`dns_options.servers[].vars[].name`), пресет с тем же
///    `preset_id` (`selectable_rules[].vars[].name`). Необъявленное имя
///    снимается: на импорте — с предупреждением (его зовёт вызывающий через
///    `onUndeclared`), в хранении — молча. Носитель, которого в шаблоне нет
///    вовсе, не нормализуется: объявлений нет — сравнивать не с чем.
///  * **Н3** — значение хранится подрезанным (`trim`), пустое после подрезки
///    равно отсутствию ключа.
///  * **Н4** — значение, равное `default_value` объявления, не пишется:
///    отсутствие ключа значит «следовать шаблону».
///
/// Переменная пресета со ссылкой на глобальную (`ref`, §265) не
/// нормализуется: её значение живёт в глобальных `vars`.
///
/// Расширение LxBox (отклонение от буквы Н2): у любого пресета имя `outbound`
/// законно — это универсальная замена цели пресета (`preset_expand.dart`,
/// «Universal outbound override»), сборка читает её и у пресета, который
/// переменную не объявил (Block Ads). Объявил — умолчание снимается по Н4;
/// не объявил — значение остаётся.
library;

import '../models/custom_rule.dart';
import '../models/dns_ref.dart';
import '../models/parser_config.dart';
import 'app_log.dart';
import 'template_loader.dart';

/// Имя, законное у любого пресета LxBox (универсальная замена цели).
const String kPresetOutboundVar = 'outbound';

/// Объявление переменной записи в шаблоне.
class RecordVarDecl {
  const RecordVarDecl({
    required this.name,
    this.defaultValue = '',
    this.type = '',
    this.isRef = false,
  });

  final String name;

  /// `default_value` так, как его подставляет сборка (строкой).
  final String defaultValue;

  /// Тип языка шаблонов (`outbound`, `enum`, `dns_servers`, …).
  final String type;

  /// §265 — ссылка на глобальную переменную: значение не в записи.
  final bool isRef;
}

/// Объявления переменных носителей из шаблона своей стороны.
class RecordVarDecls {
  const RecordVarDecls({this.dnsServers = const {}, this.presets = const {}});

  /// Шаблона нет — нормализации нет.
  static const none = RecordVarDecls();

  /// Тег template-сервера DNS → его переменные. Сервер без `vars` — пустой
  /// список: сервер объявлен, законных имён у него нет.
  final Map<String, List<RecordVarDecl>> dnsServers;

  /// `preset_id` → переменные пресета.
  final Map<String, List<RecordVarDecl>> presets;

  bool get isEmpty => dnsServers.isEmpty && presets.isEmpty;

  /// Из загруженного шаблона приложения.
  factory RecordVarDecls.fromTemplate(WizardTemplate template) =>
      RecordVarDecls(
        dnsServers: dnsServerVarDecls(template.dnsOptions),
        presets: {
          for (final p in template.selectableRules)
            if (p.presetId.isNotEmpty)
              p.presetId: [
                for (final v in p.vars)
                  if (v.name.isNotEmpty)
                    RecordVarDecl(
                      name: v.name,
                      defaultValue: v.defaultValue,
                      type: v.type,
                      isRef: v.isRef,
                    ),
              ],
        },
      );

  /// Из JSON-объявлений: `dns_options.servers[]` (обёртка
  /// `{vars?, server{tag}}` или плоская запись с `tag`) и `presets[]` /
  /// `selectable_rules[]` (`id` или `preset_id`; умолчание — `default_value`
  /// или алиас лаунчера `default`). Форма фикстуры корпуса SPEC 128 §9.1.
  factory RecordVarDecls.fromJson(Map<String, dynamic> j) {
    final dnsOptions = j['dns_options'];
    final presets = <String, List<RecordVarDecl>>{};
    for (final key in const ['presets', 'selectable_rules']) {
      final list = j[key];
      if (list is! List) continue;
      for (final p in list) {
        if (p is! Map) continue;
        final id = p['id'] ?? p['preset_id'];
        if (id is! String || id.isEmpty) continue;
        presets[id] = _declsOf(p['vars']);
      }
    }
    return RecordVarDecls(
      dnsServers: dnsOptions is Map
          ? dnsServerVarDecls(dnsOptions.cast<String, dynamic>())
          : const {},
      presets: presets,
    );
  }
}

/// Объявления template-серверов DNS: тег → переменные (`dns_options.servers`
/// шаблона, обёртка §117 `{description, enabled, vars?, server}`).
Map<String, List<RecordVarDecl>> dnsServerVarDecls(
    Map<String, dynamic> dnsOptions) {
  final out = <String, List<RecordVarDecl>>{};
  final servers = dnsOptions['servers'];
  if (servers is! List) return out;
  for (final s in servers) {
    if (s is! Map) continue;
    final server = s['server'];
    final tag = server is Map ? server['tag'] : s['tag'];
    if (tag is! String || tag.isEmpty || out.containsKey(tag)) continue;
    out[tag] = _declsOf(s['vars']);
  }
  return out;
}

List<RecordVarDecl> _declsOf(Object? raw) => [
      if (raw is List)
        for (final d in raw)
          if (d is Map) ?_declOf(d),
    ];

RecordVarDecl? _declOf(Map d) {
  final ref = d['ref'];
  if (ref is String && ref.isNotEmpty) {
    return RecordVarDecl(name: ref, isRef: true);
  }
  final name = d['name'];
  if (name is! String || name.isEmpty) return null;
  // Как подставляет сборка (`resolveTemplateDnsServerBody`): строкой.
  final def = d.containsKey('default_value') ? d['default_value'] : d['default'];
  final type = d['type'];
  return RecordVarDecl(
    name: name,
    defaultValue: def?.toString() ?? '',
    type: type is String ? type : '',
  );
}

/// Объявления из шаблона приложения. Шаблон не загрузился — [RecordVarDecls.none]:
/// нормализации нет, записи пишутся как есть.
Future<RecordVarDecls> loadRecordVarDecls() async {
  try {
    return RecordVarDecls.fromTemplate(await TemplateLoader.load());
  } catch (e) {
    AppLog.I.warning('record vars: template not loaded ($e); '
        'record variables are written as is');
    return RecordVarDecls.none;
  }
}

/// Итог нормализации одной карты значений: законные значения и снятые
/// необъявленные имена (в порядке входа).
typedef RecordVarsNormalized = ({
  Map<String, String> vars,
  List<String> undeclared,
});

/// Н2/Н3/Н4 над картой значений [values] против объявлений [decls].
///
/// [implicit] — имена, законные без объявления (у пресета — [kPresetOutboundVar]);
/// умолчания у них нет, Н4 к ним не применяется.
RecordVarsNormalized normalizeRecordVarValues(
  Map<String, String> values,
  List<RecordVarDecl> decls, {
  Set<String> implicit = const {},
}) {
  final byName = {for (final d in decls) d.name: d};
  final vars = <String, String>{};
  final undeclared = <String>[];
  for (final e in values.entries) {
    final decl = byName[e.key];
    if (decl == null) {
      if (implicit.contains(e.key)) {
        final v = e.value.trim();
        if (v.isNotEmpty) vars[e.key] = v;
      } else {
        undeclared.add(e.key);
      }
      continue;
    }
    if (decl.isRef) {
      vars[e.key] = e.value; // §265 — не трогается
      continue;
    }
    final v = e.value.trim();
    if (v.isEmpty || v == decl.defaultValue.trim()) continue;
    vars[e.key] = v;
  }
  return (vars: vars, undeclared: undeclared);
}

/// Значение переменной записи, которое пишет редактор: [value] подрезано;
/// пустое или равное умолчанию объявления [decl] — `null`, ключ снимается
/// (выбор умолчания — сброс, Н4). [decl] `null` — имя без объявления
/// (у пресета — универсальная замена цели): Н4 не применяется.
String? recordVarValueToStore(String value, RecordVarDecl? decl) {
  if (decl != null && decl.isRef) return value;
  final v = value.trim();
  if (v.isEmpty) return null;
  if (decl != null && v == decl.defaultValue.trim()) return null;
  return v;
}

bool _sameVars(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

/// Н2–Н4 у template-сервера DNS. Сервер другого вида или не объявленный
/// шаблоном — как есть. [onUndeclared] получает снятые необъявленные имена.
DnsServerRef normalizeDnsServerVars(
  DnsServerRef server,
  RecordVarDecls decls, {
  void Function(String name)? onUndeclared,
}) {
  if (server is! DnsServerTemplate) return server;
  final declared = decls.dnsServers[server.tag];
  if (declared == null) return server;
  final n = normalizeRecordVarValues(server.varValues, declared);
  if (onUndeclared != null) n.undeclared.forEach(onUndeclared);
  if (_sameVars(n.vars, server.varValues)) return server;
  return server.copyWith(varValues: n.vars);
}

/// [normalizeDnsServerVars] по списку; [onUndeclared] — `(тег, имя)`.
List<DnsServerRef> normalizeDnsServersVars(
  List<DnsServerRef> servers,
  RecordVarDecls decls, {
  void Function(String tag, String name)? onUndeclared,
}) {
  if (decls.dnsServers.isEmpty) return servers;
  return [
    for (final s in servers)
      normalizeDnsServerVars(
        s,
        decls,
        onUndeclared:
            onUndeclared == null ? null : (name) => onUndeclared(s.tag, name),
      ),
  ];
}

/// Н2–Н4 у правила-пресета. Правило другого вида или пресет, которого нет в
/// шаблоне (`backup_unknown_preset`), — как есть.
CustomRule normalizePresetRuleVars(
  CustomRule rule,
  RecordVarDecls decls, {
  void Function(String name)? onUndeclared,
}) {
  if (rule is! CustomRulePreset) return rule;
  final declared = decls.presets[rule.presetId];
  if (declared == null) return rule;
  final n = normalizeRecordVarValues(rule.varsValues, declared,
      implicit: const {kPresetOutboundVar});
  if (onUndeclared != null) n.undeclared.forEach(onUndeclared);
  if (_sameVars(n.vars, rule.varsValues)) return rule;
  return rule.copyWith(varsValues: n.vars);
}

/// [normalizePresetRuleVars] по списку; [onUndeclared] — `(preset_id, имя)`.
List<CustomRule> normalizePresetRulesVars(
  List<CustomRule> rules,
  RecordVarDecls decls, {
  void Function(String presetId, String name)? onUndeclared,
}) {
  if (decls.presets.isEmpty) return rules;
  return [
    for (final r in rules)
      normalizePresetRuleVars(
        r,
        decls,
        onUndeclared: onUndeclared == null
            ? null
            : (name) => onUndeclared(r.presetId, name),
      ),
  ];
}

/// Н8 — корневое имя `dns_<tag>_<var>` против объявлений шаблона: кандидаты —
/// объявленные пары `(tag, var)`, у которых склейка совпала с [name]; из
/// нескольких выигрывает самый длинный тег (`google_doh` / `google_doh_vpn`).
/// `null` — кандидата нет.
({String tag, String varName})? rootDnsVarTarget(
  String name,
  RecordVarDecls decls,
) {
  if (!name.startsWith('dns_')) return null;
  ({String tag, String varName})? best;
  for (final e in decls.dnsServers.entries) {
    final tag = e.key;
    for (final d in e.value) {
      if (d.isRef || 'dns_${tag}_${d.name}' != name) continue;
      if (best == null || tag.length > best.tag.length) {
        best = (tag: tag, varName: d.name);
      }
    }
  }
  return best;
}
