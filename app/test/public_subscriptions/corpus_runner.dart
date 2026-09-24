// §525 — прогон конвейера разбора по корпусу публичных подписок.
//
// Одна реализация на два потребителя: тест
// (`public_subs_corpus_test.dart`) и CLI (`tool/public_subs/run.dart`).
// Разойдись они, «прогон в CI» и «прогон руками» считали бы по-разному.
//
// Что делает прогон: по каждому снимку `decode()` → `parseAll(dropped:)`, и
// собирает ЧИСЛА — узлы, коды отбраковок, коды предупреждений, покрытие
// «протокол × транспорт × security». Конфиг НЕ собирается, ядро НЕ
// запускается, в сеть прогон не ходит: тела берутся с диска.

import 'dart:convert';
import 'dart:io';

import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/contract/warning_codes.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/parser/parse_all.dart';

/// Корень корпуса относительно `app/` (рабочий каталог и тестов, и CLI).
const kCorpusRoot = 'test/fixtures/public_subscriptions';

/// Реестр — из бандлируемого зеркала, как у остальных тестов (§486).
const _kRegistryRoot = 'assets/contract';
const _kDraftRoot = 'assets/contract_draft';

/// Корпус на месте? Его отсутствие — законный skip, а не падение: клон без
/// LFS/фикстур должен собираться.
bool get corpusAvailable => File('$kCorpusRoot/index.json').existsSync();

/// Одна запись индекса корпуса.
class CorpusEntry {
  CorpusEntry(this.raw);
  final Map<String, dynamic> raw;

  String get id => raw['id'] as String;
  String get url => raw['url'] as String;
  String get source => raw['source'] as String? ?? '';
  String? get bodyFile => raw['body_file'] as String?;
  String? get deadSince => raw['dead_since'] as String?;
  int get bodyBytes => raw['body_bytes'] as int? ?? 0;
  String get kindHint => raw['body_kind_hint'] as String? ?? '';

  /// Тело снимка. Файл лежит `.gz` (сжат КОРПУС, не транспорт) — снимаем.
  String readBody() {
    final f = File('$kCorpusRoot/$bodyFile');
    final bytes = f.path.endsWith('.gz')
        ? gzip.decode(f.readAsBytesSync())
        : f.readAsBytesSync();
    // `allowMalformed` — тела бывают в чужой кодировке; разбор обязан их
    // переварить, а не упасть на декодировании.
    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// Результат прогона по одному снимку.
class SubscriptionResult {
  SubscriptionResult({
    required this.id,
    required this.url,
    required this.source,
    required this.decodedKind,
    required this.nodesTotal,
    required this.groupsTotal,
    required this.byType,
    required this.dropped,
    required this.warnings,
    required this.coverage,
    required this.parseMs,
    required this.decodeFailure,
    required this.sampleDropLines,
  });

  final String id;
  final String url;
  final String source;

  /// Как `decode()` опознал тело (`UriLines`, `JsonConfig:xray_config`, …).
  final String decodedKind;
  final int nodesTotal;
  final int groupsTotal;

  /// `type` из `emit()` → число узлов.
  final Map<String, int> byType;

  /// Коды отбраковок целых записей (`dropped[]` конвейера) → число.
  final Map<String, int> dropped;

  /// Коды предупреждений на выживших узлах → число.
  final Map<String, int> warnings;

  /// `протокол|транспорт|security` → число узлов (метрика покрытия).
  final Map<String, int> coverage;

  final int parseMs;

  /// Непустая строка, если `decode()` отказал (`DecodeFailure.reason`).
  final String? decodeFailure;

  /// До трёх примеров отбракованных строк — для анализа, адреса замаскированы.
  final List<String> sampleDropLines;

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'source': source,
        'decoded_kind': decodedKind,
        'nodes_total': nodesTotal,
        if (groupsTotal > 0) 'groups_total': groupsTotal,
        'by_type': _sorted(byType),
        'dropped': _sorted(dropped),
        'warnings': _sorted(warnings),
        'coverage': _sorted(coverage),
        'parse_ms': parseMs,
        if (decodeFailure != null) 'decode_failure': decodeFailure,
        if (sampleDropLines.isNotEmpty) 'sample_drop_lines': sampleDropLines,
      };

  /// Эталонный срез: только ЧИСЛА, без времени разбора и примеров. Время
  /// машинозависимо, и эталон, который его несёт, расходился бы на каждом
  /// прогоне.
  Map<String, dynamic> toExpected() => {
        'nodes_total': nodesTotal,
        'dropped': _sorted(dropped),
        'warnings': _sorted(warnings),
      };
}

Map<String, int> _sorted(Map<String, int> m) {
  final keys = m.keys.toList()..sort();
  return {for (final k in keys) k: m[k]!};
}

/// Загрузить реестр и секции — без биндингов Flutter (§486, `loadFromDirectory`).
Future<void> loadCorpusRegistry() async {
  if (!ContractRegistry.I.isLoaded) {
    await ContractRegistry.I.loadFromDirectory(_kRegistryRoot);
  }
  await MapperSections.I.loadDrafts(dir: _kDraftRoot, files: kDraftFiles);
}

/// Прочитать индекс корпуса.
List<CorpusEntry> readCorpusIndex() {
  final decoded =
      jsonDecode(File('$kCorpusRoot/index.json').readAsStringSync());
  final list = (decoded as Map<String, dynamic>)['subscriptions'] as List;
  return [
    for (final e in list.cast<Map<String, dynamic>>()) CorpusEntry(e),
  ];
}

/// Прогон по одному снимку. В сеть не ходит, конфиг не собирает.
SubscriptionResult runOne(CorpusEntry entry) {
  final body = entry.readBody();
  final sw = Stopwatch()..start();

  final decoded = decode(body);
  final dropped = <NodeWarning>[];
  final nodes = parseAll(decoded, dropped: dropped);
  sw.stop();

  final byType = <String, int>{};
  final warnings = <String, int>{};
  final coverage = <String, int>{};
  var groups = 0;

  for (final n in nodes) {
    if (n.isGroup) {
      groups++;
      continue;
    }
    final body = _emitOf(n);
    final type = body?['type'] as String? ?? 'unknown';
    byType[type] = (byType[type] ?? 0) + 1;
    final key = '$type|${_transportOf(body)}|${_securityOf(body)}';
    coverage[key] = (coverage[key] ?? 0) + 1;
    for (final w in n.warnings) {
      final code = warningCodeOf(w) ?? w.runtimeType.toString();
      warnings[code] = (warnings[code] ?? 0) + 1;
    }
  }

  final dropCodes = <String, int>{};
  for (final w in dropped) {
    final code = warningCodeOf(w) ?? w.runtimeType.toString();
    dropCodes[code] = (dropCodes[code] ?? 0) + 1;
  }

  return SubscriptionResult(
    id: entry.id,
    url: entry.url,
    source: entry.source,
    decodedKind: _kindOf(decoded),
    nodesTotal: nodes.length - groups,
    groupsTotal: groups,
    byType: byType,
    dropped: dropCodes,
    warnings: warnings,
    coverage: coverage,
    parseMs: sw.elapsedMilliseconds,
    decodeFailure: decoded is DecodeFailure ? decoded.reason : null,
    sampleDropLines: _sampleDropLines(decoded, nodes),
  );
}

Map<String, dynamic>? _emitOf(NodeSpec n) {
  try {
    return Map<String, dynamic>.from(n.emit(TemplateVars.empty).map);
  } catch (_) {
    // Эмит узла падать не должен, но прогон корпуса из-за одного узла —
    // тем более.
    return null;
  }
}

/// Транспорт узла для таблицы покрытия. `none` — прямой TCP/UDP без обёртки.
String _transportOf(Map<String, dynamic>? body) {
  final t = body?['transport'];
  if (t is Map && t['type'] is String) return t['type'] as String;
  return 'none';
}

/// Слой безопасности: `reality` сильнее `tls`, дальше — что объявлено телом.
String _securityOf(Map<String, dynamic>? body) {
  final tls = body?['tls'];
  if (tls is! Map) return 'none';
  if (tls['enabled'] != true) return 'none';
  final reality = tls['reality'];
  if (reality is Map && reality['enabled'] == true) return 'reality';
  return 'tls';
}

String _kindOf(DecodedBody d) => switch (d) {
      UriLines() => 'uri_lines',
      IniConfig() => 'ini',
      AmneziaConfig() => 'amnezia',
      JsonConfig(source: final s) => 'json:${s.kind}',
      DecodeFailure() => 'decode_failure',
    };

/// Примеры строк, которые разбор не превратил в узел. Адрес маскируется: отчёт
/// про КОДЫ, а не про чужие серверы.
List<String> _sampleDropLines(DecodedBody decoded, List<NodeSpec> nodes) {
  if (decoded is! UriLines) return const [];
  if (nodes.isNotEmpty) return const [];
  final out = <String>[];
  for (final line in decoded.lines) {
    if (out.length >= 3) break;
    out.add(_maskLine(line));
  }
  return out;
}

/// Схема и форма строки остаются, узнаваемые части — нет.
String _maskLine(String line) {
  var s = line.length > 160 ? '${line.substring(0, 160)}…' : line;
  // user@host:port → ***@***:port
  s = s.replaceAllMapped(
      RegExp(r'//[^@/?#]*@'), (_) => '//***@');
  s = s.replaceAllMapped(
      RegExp(r'@([^/?#:]+)'), (_) => '@***');
  // Осмысленные хвосты запроса (sni/host/pbk) — тоже адреса.
  s = s.replaceAllMapped(
      RegExp(r'([?&](?:sni|host|pbk|sid|serverName)=)[^&#]*'),
      (m) => '${m[1]}***');
  return s;
}

/// Полный прогон по индексу. Мёртвые URL без тела пропускаются.
Future<List<SubscriptionResult>> runCorpus({void Function(String)? log}) async {
  await loadCorpusRegistry();
  final out = <SubscriptionResult>[];
  for (final e in readCorpusIndex()) {
    if (e.bodyFile == null) {
      log?.call('skip ${e.id}: тела нет (dead_since ${e.deadSince})');
      continue;
    }
    if (!File('$kCorpusRoot/${e.bodyFile}').existsSync()) {
      log?.call('skip ${e.id}: файл тела отсутствует');
      continue;
    }
    final r = runOne(e);
    out.add(r);
    log?.call(
        '${r.id}: ${r.nodesTotal} узлов, ${r.dropped.length} код(ов) отбраковки, ${r.parseMs}ms');
  }
  return out;
}
