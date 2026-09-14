/// §393 B9 — секция `dns` в LX Backup: обе стороны.
///
/// Схема — `contract/schema/backup.schema.json` (`dns.servers[]`/`dns.rules[]`
/// с дискриминатором `kind: template|preset|user`, плюс `strategy`/`final`/
/// `default_domain_resolver`); семантика — `contract/docs/BACKUP.md` §2, §9
/// п. 5. Эталон обработки — `core/backup/import.go:importDNS`. §438 — в файл
/// 1.0 записи пишет кодек записей (`record_codec.dart`) из [LxDns].
///
/// Три расхождения между каноном и мобильной моделью, из-за которых нужен
/// явный маппинг, а не «отдать storage как есть»:
///
///  1. **Имя пользовательской записи.** Канон зовёт её `user`, мобильный
///     storage — `inline`. Понятие одно и то же (тело написал пользователь),
///     имя разное.
///  2. **`srs`-правила.** У мобилы DNS-правило бывает ссылкой на скачанный
///     rule-set (`kind: srs`); в каноне такого происхождения НЕТ. §401 —
///     карман провоза упразднён (П3), поэтому такая запись в файл не едет и
///     названа предупреждением `backup_local_only_dropped` на экспорте.
///  3. **Тело template/preset-записей не переносится вообще** — ни в одну
///     сторону. Оно принадлежит шаблону ПРИНИМАЮЩЕЙ стороны, и зафиксировать
///     чужое значило бы навсегда отрезать пользователя от обновлений шаблона
///     (та же причина, что в `export.go:dnsRefFrom`). Переносится ссылка:
///     тег у template-сервера, `ref` = `<preset_id>:<tag>` у preset-сервера,
///     `ref` = `preset_id` у preset-правила.
///
/// `final`/`strategy`/`default_domain_resolver` секции — те же значения, что
/// мобильные переносимые переменные `dns_final`/`dns_strategy`/
/// `dns_default_domain_resolver`. В файле они дублируются намеренно:
/// секция самодостаточна (лаунчер читает именно её), а `vars` остаются
/// каналом для сторон, которые секцию не разбирают.
library;

import 'dart:convert';

import '../../models/parser_config.dart' show SelectableRule;
import '../lx_backup.dart';
import '../node_hash.dart' show deepSortKeys;

/// §438 — тег preset-сервера DNS → `preset_id` пресета шаблона, который его
/// объявляет (`selectable_rules[].dns_servers[].tag`). Нужен, чтобы
/// собрать `ref` = `<preset_id>:<tag>` у записи, хранящей только тег. Первый
/// объявивший пресет побеждает.
Map<String, String> presetIdByDnsServerTag(Iterable<SelectableRule> presets) {
  final out = <String, String>{};
  for (final p in presets) {
    for (final s in p.dnsServers) {
      final tag = s['tag'];
      if (tag is String && tag.isNotEmpty) out.putIfAbsent(tag, () => p.presetId);
    }
  }
  return out;
}

/// §393 B9 — мобильный storage → переносимая секция.
///
/// [servers] / [rules] — сырые списки из `dns_options` (см.
/// `SettingsStorage.getDnsServers` / `getDnsRulesList`).
///
/// §438 — форма 1.0: preset-сервер адресуется `ref` = `<preset_id>:<tag>`
/// (ONE_NAMESPACE §1). У LxBox preset-сервер хранит только тег, пресет
/// находится по [presetIdByServerTag] (тег сервера пресета → `preset_id`
/// шаблона); тег без пресета едет как есть. `default_domain_resolver` —
/// третий скаляр секции (var `dns_default_domain_resolver`).
///
/// §401 — [warnings] пополняется потерями экспорта: у канона нет дома ни для
/// `srs`-правил, ни для значений template-переменных и заметки сервера, и
/// молчать о них нельзя (П6). DNS-правила вида `template` в 1.0 не выражаются
/// и не пишутся: это ссылки на правила шаблона, которые сторона заводит сама
/// по своему шаблону, пользовательской настройки в них нет.
LxDns dnsToBackup({
  required List<Map<String, dynamic>> servers,
  required List<Map<String, dynamic>> rules,
  required String dnsFinal,
  required String strategy,
  String defaultDomainResolver = '',
  Map<String, String> presetIdByServerTag = const {},
  List<LxBackupWarning>? warnings,
}) {
  final localOnly = <String>[];
  final outServers = <LxDnsRef>[];
  for (final e in servers) {
    final kind = _canonKind(e['kind']);
    final tag = (e['tag'] as String?) ?? '';
    if (kind == null || tag.isEmpty) continue;
    final presetId = presetIdByServerTag[tag] ?? '';
    outServers.add(
      LxDnsRef(
        kind: kind,
        name: kind == 'preset' ? '' : tag,
        ref: kind != 'preset'
            ? ''
            : (presetId.isEmpty ? tag : '$presetId:$tag'),
        enabled: e['enabled'] as bool? ?? true,
        // Тело — только у пользовательской записи (см. docstring, п. 3).
        value: kind == 'user'
            ? (e['body'] as Map?)?.cast<String, dynamic>()
            : null,
      ),
    );
    // Значения template-переменных и заметка: мобильные понятия, у канона
    // места нет. §401 — в файл не едут, потеря названа ниже одной строкой.
    if (e['varValues'] is Map) localOnly.add('$tag: varValues');
    if (e['description'] is String) localOnly.add('$tag: description');
  }

  final outRules = <LxDnsRef>[];
  for (final e in rules) {
    final rawKind = '${e['kind']}';
    if (rawKind == 'srs') {
      // Происхождения `srs` в каноне нет, и провозить его больше нечем (§401).
      localOnly.add('${e['name'] ?? 'dns rule'}: srs');
      continue;
    }
    if (rawKind == 'template') continue;
    final kind = _canonKind(e['kind']);
    if (kind == null) continue;
    final name = (e['name'] as String?) ?? '';
    final presetId = (e['presetId'] as String?) ?? '';
    final body = (e['rule'] as Map?)?.cast<String, dynamic>();
    if (kind == 'user' ? body == null : presetId.isEmpty) continue;
    outRules.add(
      LxDnsRef(
        kind: kind,
        name: kind == 'user' ? name : '',
        ref: kind == 'preset' ? presetId : '',
        enabled: e['enabled'] as bool? ?? true,
        value: kind == 'user' ? body : null,
      ),
    );
  }

  // ОДИН warning на секцию с перечнем: строка на каждую потерю утопила бы
  // пользователя в списке при большом DNS-конфиге.
  if (localOnly.isNotEmpty && warnings != null) {
    warnings.add(
      LxBackupWarning(kWarnLocalOnlyDropped, 'dns: ${localOnly.join(', ')}'),
    );
  }

  return LxDns(
    servers: outServers,
    rules: outRules,
    finalServer: dnsFinal,
    strategy: strategy,
    defaultDomainResolver: defaultDomainResolver,
  );
}

/// §393 B9 — результат применения секции на мобилу.
typedef DnsBackupApply = ({
  List<Map<String, dynamic>> servers,
  List<Map<String, dynamic>> rules,
  String dnsFinal,
  String strategy,

  /// §438 — `dns.default_domain_resolver` (var `dns_default_domain_resolver`).
  String defaultDomainResolver,
  int applied,
});

/// §393 B9 — переносимая секция → мобильный storage (merge).
///
/// Merge, а не replace: своя настройка сильнее приехавшей (эталон
/// `import.go:importDNS`). Совпавшая запись остаётся локальной, несовпавшая
/// дописывается в конец в порядке файла.
///
/// §438 — ключи слияния по BACKUP.md §9 п. 5, одни для обоих форматов:
///
///  * сервер — `kind` + `tag`, а у `preset` — `kind` + полный `ref`
///    (`<preset_id>:<tag>`): тега у ссылочной записи нет, и ключ по тегу
///    схлопнул бы все preset-серверы в один. Storage LxBox держит тег сервера
///    пресета; `ref` своей записи собирается по [presetIdByServerTag];
///  * правило — `kind` + `ref` + тело: своего имени у правила контракта нет,
///    различить два правила можно только тем, что они делают. Дописанному
///    пользовательскому правилу без имени имя выводится из тела (storage
///    LxBox безымянное правило не держит), с уникализацией суффиксом.
///
/// `final`/`strategy`/`default_domain_resolver` применяются только когда
/// приехали непустыми: пустая строка в файле означает «сторона это не
/// переносила», а не «сбросить».
DnsBackupApply applyDnsBackup({
  required LxDns incoming,
  required List<Map<String, dynamic>> servers,
  required List<Map<String, dynamic>> rules,
  required String dnsFinal,
  required String strategy,
  String defaultDomainResolver = '',
  Map<String, String> presetIdByServerTag = const {},
}) {
  var applied = 0;
  final outServers = [for (final e in servers) Map<String, dynamic>.from(e)];
  // Ключ preset — полный `ref`: у своей записи он собирается из тега и
  // пресета шаблона, которому тег принадлежит.
  String localRef(String tag) {
    final pid = presetIdByServerTag[tag] ?? '';
    return pid.isEmpty ? tag : '$pid:$tag';
  }

  final haveServers = <String>{
    for (final e in outServers)
      e['kind'] == 'preset'
          ? _serverKey('preset', localRef('${e['tag']}'))
          : _serverKey('${e['kind']}', '${e['tag']}'),
  };
  // Storage LxBox держит preset-сервер тегом: второй записи под тем же тегом
  // (тот же сервер чужого пресета) места нет.
  final presetTags = <String>{
    for (final e in outServers)
      if (e['kind'] == 'preset') '${e['tag']}',
  };

  for (final ref in incoming.servers) {
    final kind = _mobileKind(ref.kind);
    // preset адресуется `ref` = `<preset_id>:<tag>` (1.0); у записи 0.x
    // ссылка ехала именем.
    final fullRef = kind == 'preset' && ref.ref.isNotEmpty ? ref.ref : ref.name;
    if (fullRef.isEmpty) continue;
    final at = kind == 'preset' ? fullRef.indexOf(':') : -1;
    final tag = at < 0 ? fullRef : fullRef.substring(at + 1);
    if (tag.isEmpty) continue;
    if (!haveServers.add(_serverKey(kind, fullRef))) continue; // своё сильнее
    if (kind == 'preset' && !presetTags.add(tag)) continue;
    outServers.add(<String, dynamic>{
      'kind': kind,
      'tag': tag,
      'enabled': ref.enabled,
      if (kind == 'inline' && ref.value != null) 'body': ref.value,
    });
    applied++;
  }

  final outRules = [for (final e in rules) Map<String, dynamic>.from(e)];
  final haveRules = <String>{
    for (final e in outRules)
      _ruleKey(
        '${e['kind']}',
        name: (e['name'] as String?) ?? '',
        ref: (e['presetId'] as String?) ?? (e['id'] as String?) ?? '',
        body: e['rule'],
      ),
  };
  final usedNames = <String>{
    for (final e in outRules)
      if (e['name'] is String) e['name'] as String,
  };

  for (final ref in incoming.rules) {
    final kind = _mobileKind(ref.kind);
    if (kind == 'inline' ? ref.value == null : ref.name.isEmpty && ref.ref.isEmpty) {
      continue;
    }
    final key = _ruleKey(kind, name: ref.name, ref: ref.ref, body: ref.value);
    if (!haveRules.add(key)) continue; // своё сильнее
    var name = ref.name;
    if (kind == 'inline') {
      name = _uniqueName(
        name.isNotEmpty ? name : _ruleNameFromBody(ref.value!),
        usedNames,
      );
    }
    if (name.isNotEmpty) usedNames.add(name);
    outRules.add(<String, dynamic>{
      'kind': kind,
      'enabled': ref.enabled,
      if (name.isNotEmpty) 'name': name,
      if (ref.ref.isNotEmpty) 'presetId': ref.ref,
      if (kind == 'inline' && ref.value != null) 'rule': ref.value,
    });
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

String _serverKey(String kind, String tag) => '$kind\u0000$tag';

/// Ключ DNS-правила: пользовательское — телом в каноне (ключи отсортированы),
/// ссылочные — ссылкой, шаблонное — именем.
String _ruleKey(
  String kind, {
  required String name,
  required String ref,
  Object? body,
}) {
  switch (kind) {
    case 'inline':
      return 'inline\u0000${body is Map ? jsonEncode(deepSortKeys(body)) : ''}';
    case 'template':
      return 'template\u0000$name';
    default:
      return '$kind\u0000$ref';
  }
}

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

/// Мобильное имя происхождения → каноническое; `null` = у канона места нет.
String? _canonKind(Object? raw) => switch ('$raw') {
  'inline' => 'user',
  'template' => 'template',
  'preset' => 'preset',
  _ => null,
};

/// Каноническое имя происхождения → мобильное.
String _mobileKind(String canon) => canon == 'user' ? 'inline' : canon;
