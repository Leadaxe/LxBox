/// §393 B9 — секция `dns` в LX Backup: обе стороны.
///
/// Схема — `contract/schema/backup.schema.json` (`dns.servers[]`/`dns.rules[]`
/// с дискриминатором `kind: template|preset|user`, плюс `strategy`/`final`/
/// `default_domain_resolver`); семантика — `contract/docs/BACKUP.md` §2, §9
/// п. 5. Эталон обработки — `core/backup/import.go:importDNS`.
///
/// §439 — записи секции — записи хранения `dns{}`: экспорт пишет их кодеком
/// (`models/codec/dns_record.dart`) и срезает поля LxBox таблицей
/// `lx_backup_slice.dart`, импорт отдаёт слиянию модели [DnsServerRef] /
/// [DnsRuleRef]. Что не едет:
///
///  1. **`srs`-правила.** У LxBox DNS-правило бывает ссылкой на скачанный
///     rule-set (`kind: srs`); в каноне такого вида НЕТ. Запись не пишется и
///     названа `backup_local_only_dropped` (§401: карманов провоза нет).
///  2. **`template`-правила.** Ссылки на правила шаблона: сторона заводит их
///     сама по своему шаблону, пользовательской настройки в них нет — молча.
///  3. **`description` и `vars` сервера** — поля LxBox без дома в 1.0,
///     срезаются с `backup_local_only_dropped`. Тело template/preset-записи
///     не переносится вовсе: оно принадлежит шаблону принимающей стороны
///     (`export.go:dnsRefFrom`); переносится ссылка — тег у template, `ref` =
///     `<preset_id>:<tag>` у preset-сервера, `ref` = `preset_id` у
///     preset-правила.
///
/// `final`/`strategy`/`default_domain_resolver` секции — те же значения, что
/// мобильные переносимые переменные `dns_final`/`dns_strategy`/
/// `dns_default_domain_resolver`. В файле они дублируются намеренно:
/// секция самодостаточна (лаунчер читает именно её), а `vars` остаются
/// каналом для сторон, которые секцию не разбирают.
library;

import 'dart:convert';

import '../../models/dns_ref.dart';
import '../../models/record_codec.dart';
import '../lx_backup.dart';
import '../lx_backup_slice.dart';
import '../node_hash.dart' show deepSortKeys;

/// §393 B9 — DNS хранения → секция `dns` файла 1.0; `null` — нечего писать.
///
/// [warnings] пополняется потерями экспорта: одно
/// `backup_local_only_dropped` на запись (П6).
Map<String, dynamic>? dnsToBackup({
  required List<DnsServerRef> servers,
  required List<DnsRuleRef> rules,
  required String dnsFinal,
  required String strategy,
  String defaultDomainResolver = '',
  List<LxBackupWarning>? warnings,
}) {
  final sink = warnings ?? <LxBackupWarning>[];
  final outServers = [
    for (final s in servers)
      ?exportBackupRecord(BackupRecord.dnsServer, dnsServerToRecord(s),
          'dns: ${_serverLabel(s)}', sink),
  ];
  final outRules = [
    for (final r in rules)
      ?exportBackupRecord(BackupRecord.dnsRule, dnsRuleToRecord(r),
          'dns: ${_ruleLabel(r)}', sink),
  ];
  final out = <String, dynamic>{
    if (strategy.isNotEmpty) 'strategy': strategy,
    if (dnsFinal.isNotEmpty) 'final': dnsFinal,
    if (defaultDomainResolver.isNotEmpty)
      'default_domain_resolver': defaultDomainResolver,
    if (outServers.isNotEmpty) 'servers': outServers,
    if (outRules.isNotEmpty) 'rules': outRules,
  };
  return out.isEmpty ? null : out;
}

String _serverLabel(DnsServerRef s) => s is DnsServerPreset && s.presetId.isNotEmpty
    ? '${s.presetId}:${s.tag}'
    : s.tag;

String _ruleLabel(DnsRuleRef r) => switch (r) {
      DnsRuleInline(:final name) ||
      DnsRuleSrs(:final name) ||
      DnsRuleTemplate(:final name) =>
        name.isEmpty ? 'dns rule' : name,
      DnsRulePreset(:final presetId) => presetId,
    };

/// §393 B9 — результат применения секции.
typedef DnsBackupApply = ({
  List<DnsServerRef> servers,
  List<DnsRuleRef> rules,
  String dnsFinal,
  String strategy,

  /// §438 — `dns.default_domain_resolver` (var `dns_default_domain_resolver`).
  String defaultDomainResolver,
  int applied,
});

/// §393 B9 — секция файла → DNS хранения (merge).
///
/// Merge, а не replace: своя настройка сильнее приехавшей (эталон
/// `import.go:importDNS`). Совпавшая запись остаётся локальной, несовпавшая
/// дописывается в конец в порядке файла.
///
/// Ключи слияния по BACKUP.md §9 п. 5, одни для обоих форматов:
///
///  * сервер — вид + тег, а у `preset` — вид + полный `ref`
///    (`<preset_id>:<tag>`): тега у ссылочной записи нет, и ключ по тегу
///    схлопнул бы все preset-серверы в один. Серверы файла между собой тоже
///    не дублируются: тег — имя outbound'а DNS, второго владельца у него нет;
///  * правило — вид + `ref` + тело: своего имени у правила контракта нет,
///    различить два правила можно только тем, что они делают. §439 §6.5
///    п. 12 — пользовательские правила сверяются только с правилами, которые
///    стояли ДО импорта (как папки по имени, §9 п. 3): файл — сериализация
///    состояния, и два одинаковых правила в нём — два правила состояния.
///    Ссылки (`preset`, `template`) дублем не заводятся. Безымянному
///    пользовательскому правилу имя выводится из тела с уникализацией
///    суффиксом; имя из файла остаётся как есть.
///
/// `final`/`strategy`/`default_domain_resolver` применяются только когда
/// приехали непустыми: пустая строка в файле означает «сторона это не
/// переносила», а не «сбросить».
DnsBackupApply applyDnsBackup({
  required LxDns incoming,
  required List<DnsServerRef> servers,
  required List<DnsRuleRef> rules,
  required String dnsFinal,
  required String strategy,
  String defaultDomainResolver = '',
}) {
  var applied = 0;
  final outServers = servers.toList();
  final haveServers = <String>{for (final s in outServers) _serverKey(s)};
  // Хранение держит preset-сервер тегом: второй записи под тем же тегом
  // (тот же сервер чужого пресета) места нет.
  final presetTags = <String>{
    for (final s in outServers)
      if (s is DnsServerPreset) s.tag,
  };
  for (final s in incoming.servers) {
    if (!haveServers.add(_serverKey(s))) continue; // своё сильнее
    if (s is DnsServerPreset && !presetTags.add(s.tag)) continue;
    outServers.add(s);
    applied++;
  }

  final outRules = rules.toList();
  final localRules = <String>{for (final r in outRules) _ruleKey(r)};
  final addedRefs = <String>{};
  final usedNames = <String>{
    for (final r in outRules)
      if (_nameOf(r) case final name? when name.isNotEmpty) name,
  };
  for (final r in incoming.rules) {
    final key = _ruleKey(r);
    if (localRules.contains(key)) continue; // своё сильнее
    if (r is! DnsRuleInline && !addedRefs.add(key)) continue;
    final rule = r is DnsRuleInline && r.name.isEmpty
        ? r.copyWith(name: _uniqueName(_ruleNameFromBody(r.rule), usedNames))
        : r;
    if (_nameOf(rule) case final name? when name.isNotEmpty) {
      usedNames.add(name);
    }
    outRules.add(rule);
    applied++;
  }

  // §401 — `srs`-правила обратно не приезжают: карман, которым они ездили,
  // упразднён (П3). Свои правила на этой машине при этом целы — merge их не
  // трогает, а приехать им теперь неоткуда.

  return (
    servers: outServers,
    rules: outRules,
    dnsFinal: incoming.finalServer.isNotEmpty ? incoming.finalServer : dnsFinal,
    strategy: incoming.strategy.isNotEmpty ? incoming.strategy : strategy,
    defaultDomainResolver: incoming.defaultDomainResolver.isNotEmpty
        ? incoming.defaultDomainResolver
        : defaultDomainResolver,
    applied: applied,
  );
}

String _serverKey(DnsServerRef s) => switch (s) {
      DnsServerPreset(:final presetId, :final tag) =>
        'preset\u0000${presetId.isEmpty ? tag : '$presetId:$tag'}',
      _ => '${s.kind}\u0000${s.tag}',
    };

/// Ключ DNS-правила: пользовательское — телом в каноне (ключи отсортированы),
/// ссылочные — ссылкой, шаблонное — именем, `srs` — своим `id`.
String _ruleKey(DnsRuleRef r) => switch (r) {
      DnsRuleInline(:final rule) => 'user\u0000${jsonEncode(deepSortKeys(rule))}',
      DnsRulePreset(:final presetId) => 'preset\u0000$presetId',
      DnsRuleTemplate(:final name) => 'template\u0000$name',
      DnsRuleSrs(:final id) => 'srs\u0000$id',
    };

String? _nameOf(DnsRuleRef r) => switch (r) {
      DnsRuleInline(:final name) ||
      DnsRuleSrs(:final name) ||
      DnsRuleTemplate(:final name) =>
        name,
      DnsRulePreset() => null,
    };

/// Имя безымянного пользовательского DNS-правила: первое значение первого
/// матчера тела (`domain_suffix: [".corp.example"]` → `.corp.example`), без
/// матчера — `server`.
String _ruleNameFromBody(Map<String, dynamic> body) {
  for (final e in body.entries) {
    if (e.key == 'server' || e.key == 'action') continue;
    final v = e.value;
    if (v is List && v.isNotEmpty && v.first is String) return v.first as String;
    if (v is String && v.isNotEmpty) return v;
  }
  final server = body['server'];
  return server is String && server.isNotEmpty ? server : 'rule';
}

String _uniqueName(String base, Set<String> used) {
  if (!used.contains(base)) return base;
  for (var n = 2;; n++) {
    final candidate = '$base-$n';
    if (!used.contains(candidate)) return candidate;
  }
}
