/// §652 — чистая часть регидрации подписки из кэша тела и её запуск в
/// отдельном isolate.
///
/// Разбор тела большой подписки (тысячи узлов) в основном isolate подвешивал
/// UI на десятки секунд сразу после старта. Здесь только данные: тело
/// (прочитанное на main — `HttpCache` ходит в `path_provider`), активные
/// import-правила, отметки выключения и хранимые вердикты на входе; узлы,
/// мигрированные отметки, сводка `dropped` и подсказка пустого разбора на
/// выходе. Мутации контроллера остаются на main.
///
/// §652 C — тем же механизмом в воркере разбирается и ответ источника
/// подписки (сеть, снапшот файловой, тело нового файла): [FetchParseInput] →
/// [FetchParseResult].
library;

import 'dart:isolate';

import '../../models/core_reject_verdict.dart';
import '../../models/debug_entry.dart';
import '../../models/import_rule.dart';
import '../../models/node_spec.dart';
import '../../models/node_warning.dart';
import '../../services/app_log.dart';
import '../../services/contract/registry.dart';
import '../../services/node_hash.dart';
import '../../services/node_identity.dart';
import '../../services/parse_hints.dart';
import '../../services/parser/body_decoder.dart';
import '../../services/parser/engine/section_loader.dart';
import '../../services/parser/parse_all.dart';
import '../../services/subscription/import_rules.dart';
import '../../services/subscription/sources.dart';
import 'core_reject_ops.dart';

/// Вход разбора кэша одной подписки.
final class CacheParseInput {
  const CacheParseInput({
    required this.body,
    required this.rules,
    required this.disabledHashes,
    required this.nodeWarnings,
  });

  final String body;

  /// `SubscriptionServers.activeImportRules` (§302).
  final List<ImportRule> rules;

  /// `SubscriptionServers.disabledHashes` — вход миграции legacy-ключей (§400).
  final Map<String, DateTime> disabledHashes;

  /// `SubscriptionServers.nodeWarnings` — хранимые вердикты ядра (фича 478).
  final Map<String, List<StoredWarning>> nodeWarnings;
}

/// Запись журнала, сделанная разбором в воркере: воспроизводится на main.
typedef CapturedLog = ({DebugLevel level, String message, DebugSource source});

/// Результат разбора кэша одной подписки.
final class CacheParseResult {
  const CacheParseResult({
    required this.nodes,
    required this.migrated,
    required this.dropped,
    required this.emptyHint,
    this.logs = const [],
  });

  /// Узлы после import-правил (§302) с дописанными вердиктами (фича 478).
  /// Пусто — тело разобралось в 0 узлов, см. [emptyHint].
  final List<NodeSpec> nodes;

  /// Отметки после миграции legacy-ключей; `null` — мигрировать было нечего
  /// (вызывающий оставляет свою карту и не пишет диск).
  final Map<String, DateTime>? migrated;

  /// `summaryDropped` разбора (§561).
  final List<NodeWarning> dropped;

  /// `diagnoseEmptyParse` тела при пустом разборе.
  final String? emptyHint;

  /// Записи журнала разбора в воркере (на main разбор пишет сразу).
  final List<CapturedLog> logs;

  CacheParseResult _withLogs(List<CapturedLog> logs) => CacheParseResult(
        nodes: nodes,
        migrated: migrated,
        dropped: dropped,
        emptyHint: emptyHint,
        logs: logs,
      );
}

/// Разбор кэша одной подписки — тот же путь, что и в основном isolate до
/// §652: `decode` → `parseAll` → import-правила → миграция legacy-ключей →
/// вердикты ядра. GC отметок здесь нет: регидрация не сигнал «узел ушёл»
/// (§283).
CacheParseResult parseCachedBody(CacheParseInput input) {
  final decoded = decode(input.body);
  // §561 — `dropped[]` сводки источника восстанавливается тем же разбором
  // кэша, что и узлы: в кодек записи он не пишется.
  final dropped = <NodeWarning>[];
  final nodes = parseAll(decoded, dropped: dropped);
  // §302 — те же import-rules, что на сетевом обновлении: иначе после рестарта
  // узлы вернулись бы в ДОзаменном виде, их идентичность не совпала бы с
  // отметками DISABLE, а REPLACE не применился бы. Отметки правил здесь не
  // берутся — их ставит только сетевой refresh.
  applyRulesToNodes(nodes, input.rules);
  if (nodes.isEmpty) {
    return CacheParseResult(
      nodes: nodes,
      migrated: null,
      dropped: summaryDropped(dropped),
      emptyHint: diagnoseEmptyParse(input.body),
    );
  }
  // §400 (IDENTITY.md §5.1) — регидрация кэша это тоже первый разбор
  // источника: legacy-ключи опознаются, не дожидаясь сетевого refresh.
  final migrated = migrateLegacyDisabledKeys(input.disabledHashes, nodes);
  // Фича 478 — вердикт ядра пересчётом по телу не воспроизводится:
  // дописываем его на разобранные узлы.
  stampStoredVerdicts(nodes, input.nodeWarnings);
  return CacheParseResult(
    nodes: nodes,
    migrated: identical(migrated, input.disabledHashes) ? null : migrated,
    dropped: summaryDropped(dropped),
    emptyHint: null,
  );
}

/// Синглтоны разбора основного isolate, снятые для воркера: в новом isolate
/// `ContractRegistry.I` и `MapperSections.I` пусты, а разбор без них молча
/// деградирует (коды и санитайзер пропускаются, черновые секции пусты).
final class ParseEnvSnapshot {
  const ParseEnvSnapshot({required this.registry, required this.drafts});

  /// Снимок main. Тексты уже лежат в синглтонах — повторного чтения ассетов
  /// нет.
  factory ParseEnvSnapshot.capture() => ParseEnvSnapshot(
        registry: ContractRegistry.I.snapshot,
        drafts: MapperSections.I.draftTexts,
      );

  /// `null` — на main реестр не загружен; воркер тогда работает без него же.
  final RegistrySnapshot? registry;
  final Map<String, String> drafts;

  Future<void> _install() async {
    final reg = registry;
    if (reg != null) {
      await ContractRegistry.I.loadFromSnapshot(reg);
      if (!ContractRegistry.I.isLoaded) {
        throw StateError('contract registry not initialized in worker');
      }
    }
    MapperSections.I.loadDraftsFromTexts(drafts);
  }
}

/// [parseCachedBody] в отдельном isolate. Ошибка инициализации синглтонов —
/// ошибка воркера (исключение), а не тихий разбор без них. Вызывающий
/// отвечает за откат на main.
Future<CacheParseResult> parseCachedBodyInIsolate(
    CacheParseInput input, ParseEnvSnapshot env) async {
  final (value, logs) =
      await _runInWorker(() => parseCachedBody(input), env, 'rehydrate');
  return value._withLogs(logs);
}

/// Общий запуск чистого разбора в отдельном isolate: установка синглтонов
/// из снимка main, перехват журнала. [parse] обязан быть построен в
/// top-level функции: замыкание из метода контроллера утянуло бы в воркер
/// контекст с `this`.
Future<(R, List<CapturedLog>)> _runInWorker<R>(
        R Function() parse, ParseEnvSnapshot env, String debugName) =>
    Isolate.run(() => _workerMain(parse, env), debugName: debugName);

Future<(R, List<CapturedLog>)> _workerMain<R>(
    R Function() parse, ParseEnvSnapshot env) async {
  final logs = <CapturedLog>[];
  AppLog.I.capture = (level, message, source) =>
      logs.add((level: level, message: message, source: source));
  await env._install();
  return (parse(), logs);
}

/// §652 C — вход разбора ответа источника подписки (сеть, снапшот файловой,
/// ответ того же URL в проходе автообновления, тело нового файла).
final class FetchParseInput {
  const FetchParseInput({required this.fetch, this.rules = const []});

  final FetchResult fetch;

  /// `SubscriptionServers.activeImportRules` на момент старта разбора
  /// (§302). Пусто — правила не применяются (новая подписка, смена
  /// источника).
  final List<ImportRule> rules;
}

/// §652 C — результат разбора ответа: [ParseResult] (узлы после
/// import-правил, мета, `dropped`) и отметки правил.
final class FetchParseResult {
  const FetchParseResult({
    required this.result,
    required this.ruleMarks,
    this.logs = const [],
  });

  final ParseResult result;

  /// [applyRulesToNodes] над [ParseResult.nodes].
  final ({Set<String> disable, Set<String> enable}) ruleMarks;

  /// Записи журнала разбора в воркере (на main разбор пишет сразу).
  final List<CapturedLog> logs;
}

/// §652 C — разбор ответа: `parseFetched` (inline-заголовки, мета, `decode`,
/// `parseAll(dropped:)`) и import-правила. Состояние контроллера (миграция,
/// вердикты, GC, ключ состава) здесь не трогается — это main.
FetchParseResult parseFetchedWithRules(FetchParseInput input) {
  final result = parseFetched(input.fetch);
  final marks = applyRulesToNodes(result.nodes, input.rules);
  return FetchParseResult(result: result, ruleMarks: marks);
}

/// [parseFetchedWithRules] в отдельном isolate — тот же механизм, что у
/// [parseCachedBodyInIsolate]. Откат на main — у вызывающего.
Future<FetchParseResult> parseFetchedInIsolate(
    FetchParseInput input, ParseEnvSnapshot env) async {
  final (value, logs) =
      await _runInWorker(() => parseFetchedWithRules(input), env, 'fetch-parse');
  return FetchParseResult(
      result: value.result, ruleMarks: value.ruleMarks, logs: logs);
}

/// Воспроизводит на main записи журнала, сделанные разбором в воркере.
void replayCapturedLogs(List<CapturedLog> logs) {
  for (final l in logs) {
    AppLog.I.log(l.level, l.message, source: l.source);
  }
}

/// §302 — применяет import-rules к разобранным узлам и возвращает
/// идентичности узлов, помеченных к выключению (Disable) и к
/// принудительному включению (Enable, §332).
///
/// §400 — REPLACE патчит `NodeSpec.patchedJson` (узел эмитится из него), но
/// идентичность считается от ТЕГА, а патч тег не трогает: правило, меняющее
/// server/uuid, отметку больше не срывает.
///
/// §652 — top-level, а не метод контроллера: зовётся и из воркера
/// регидрации, а замыкание поймало бы контроллер.
({Set<String> disable, Set<String> enable}) applyRulesToNodes(
    List<NodeSpec> nodes, List<ImportRule> rules) {
  // §307 — правила НЕ инкрементальны: каждый прогон стартует с чистого
  // узла (движок читает `emitRaw`), поэтому прошлый патч всегда сбрасываем.
  // Сегодня узлы в обоих call-site'ах свежераспарсенные и сброс — no-op,
  // но если сюда когда-нибудь придёт живой список, накопления не будет.
  for (final n in nodes) {
    n.patchedJson = null;
    n.ruleTrail = const [];
  }
  if (rules.isEmpty || nodes.isEmpty) return (disable: const {}, enable: const {});
  final result = applyImportRules(nodes, rules);
  if (result.isEmpty) return (disable: const {}, enable: const {});

  final disable = <String>{};
  final enable = <String>{};
  // §400 — идентичность узла от его тега, поэтому REPLACE-патч её НЕ
  // меняет: правило может переписать server/uuid, отметка остаётся на том
  // же ключе. Карта считается один раз на весь список.
  final identities = sourceNodeIdentities(nodes);
  result.outcomes.forEach((i, outcome) {
    if (i < 0 || i >= nodes.length) return;
    final node = nodes[i];
    if (outcome.patchedJson != null) {
      node.patchedJson = outcome.patchedJson;
      node.ruleTrail = outcome.replacements;
    }
    final identity = identities[node];
    if (identity == null) return; // группа/безымянный — отметок не имеет
    if (outcome.disabled == true) disable.add(identity);
    if (outcome.disabled == false) enable.add(identity);
  });

  // §322 — правила могли переписать `server`/`uuid`, и тогда идентичность
  // узла другая, а синонимы группы указывают на прежнюю. Пересобираем
  // таблицу по патченым узлам: тег провайдера тот же, ключ новый.
  _remapAutoSelectSynonyms(nodes);
  return (disable: disable, enable: enable);
}

/// §322 — пересчёт таблицы синонимов после §302-правил. Тег провайдера
/// (ключ таблицы) правила не трогают — меняется только идентичность, на
/// которую он указывает.
void _remapAutoSelectSynonyms(List<NodeSpec> nodes) {
  final autos = nodes.whereType<AutoSelectSpec>().toList();
  if (autos.isEmpty) return;
  // Старая идентичность → новая. Считаем по узлам, которые правила задели.
  final moved = <String, String>{};
  for (final n in nodes) {
    if (n.patchedJson == null) continue;
    final before = nodeIdentityKeyRaw(n);
    final after = nodeIdentityKey(n);
    if (before != null && after != null && before != after) {
      moved[before] = after;
    }
  }
  if (moved.isEmpty) return;
  for (var i = 0; i < nodes.length; i++) {
    final a = nodes[i];
    if (a is! AutoSelectSpec || a.tagSynonyms.isEmpty) continue;
    nodes[i] = a.copyWith(tagSynonyms: {
      for (final e in a.tagSynonyms.entries) e.key: moved[e.value] ?? e.value,
    });
  }
}
