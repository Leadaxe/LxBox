// Общие пути контракта для тестов (§486).
//
// Реестр (`registry/**`, `VERSION`) закоммичен в зеркале `assets/contract` и
// едет в APK — тесты, которым нужен только реестр, грузят его оттуда и на CI
// не скипаются. Корпус и `schema/` живут только в gitignored `app/contract/`;
// тесты, которым они нужны, остаются за гейтом, но пропуск становится
// заметным (см. [corpusTestSkip], [corpus_skip_guard_test.dart]).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/contract/registry.dart';

/// Бандлируемое зеркало реестра (в git, в APK).
const kRegistryRoot = 'assets/contract';

/// Вендоренная копия контракта (gitignored). Корпус и schema/ — только здесь.
const kVendorRoot = 'contract';

/// Устаревшее имя — реестровые читатели корпуса (`corpus_warnings.dart`).
const kContractRoot = kRegistryRoot;

bool get hasRegistryMirror =>
    Directory('$kRegistryRoot/registry').existsSync();

bool get hasVendorContract => Directory(kVendorRoot).existsSync();

bool get hasContractCorpus =>
    Directory('$kVendorRoot/corpus').existsSync();

/// Загрузить [ContractRegistry] из зеркала, если ещё не загружен.
Future<void> loadTestRegistry() async {
  if (!ContractRegistry.I.isLoaded) {
    await ContractRegistry.I.loadFromDirectory(kRegistryRoot);
  }
}

// --- учёт пропусков корпуса (между изолятами — через файл) ---

const _skipRegistryPath = '.dart_tool/corpus_skip_registry.txt';

void _appendCorpusSkipRecord(String record) {
  if (hasContractCorpus) return;
  final f = File(_skipRegistryPath);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync('$record\n', mode: FileMode.append, flush: true);
}

/// Причина skip для одного corpus-зависимого теста, или `null` если корпус есть.
String? corpusTestSkip(String suite, {String subpath = 'corpus'}) {
  if (hasContractCorpus) return null;
  _appendCorpusSkipRecord('test:$suite');
  return 'нет $kVendorRoot/$subpath — синхронизируйте: bash app/tool/sync_contract.sh';
}

/// Ранний выход из `main()` corpus-сьюта: регистрирует файл и печатает сводку.
bool corpusSuiteUnavailable(String suite) {
  if (hasContractCorpus) return false;
  _appendCorpusSkipRecord('suite:$suite');
  printCorpusSkipSummary();
  return true;
}

/// Сьюты, зарегистрированные как пропущенные из-за отсутствия корпуса.
Set<String> readCorpusSkippedSuites() {
  final f = File(_skipRegistryPath);
  if (!f.existsSync()) return {};
  final suites = <String>{};
  for (final line in f.readAsLinesSync()) {
    final parts = line.split(':');
    if (parts.length < 2) continue;
    suites.add(parts.sublist(1).join(':'));
  }
  return suites;
}

int readCorpusSkippedTestCount() {
  final f = File(_skipRegistryPath);
  if (!f.existsSync()) return 0;
  return f
      .readAsLinesSync()
      .where((l) => l.startsWith('test:'))
      .length;
}

/// Одна строка «corpus skipped: …» — вызывается из guard и из corpusSuiteUnavailable.
void printCorpusSkipSummary() {
  if (hasContractCorpus) return;
  final n = readCorpusSkippedTestCount();
  final suites = readCorpusSkippedSuites();
  // Сьюты без поштучного test: — хотя бы один пропуск на файл.
  final effective = n > 0 ? n : suites.length;
  // ignore: avoid_print
  print(
      'corpus skipped: app/contract отсутствует, $effective тестов');
}

/// Corpus-сьюты (полный или частичный гейт). Сторож на CI перечисляет их, если
/// в текущем прогоне не успели зарегистрироваться (параллельные изоляты).
const kKnownCorpusGatedSuites = <String>[
  'test/contract/backup_corpus_test.dart',
  'test/contract/body_contract_test.dart',
  'test/contract/contract_test.dart',
  'test/contract/direction_corpus_test.dart',
  'test/contract/lx_backup_group_links_test.dart',
  'test/contract/lx_backup_roundtrip_test.dart',
  'test/contract/registry_invariant_test.dart',
  'test/contract/template_contract_test.dart',
  'test/contract/template_load_reject_test.dart',
  'test/parser/anytls_pipeline_invariants_test.dart',
  'test/parser/http_pipeline_invariants_test.dart',
  'test/parser/naive_pipeline_invariants_test.dart',
  'test/parser/shadowsocks_pipeline_invariants_test.dart',
  'test/parser/socks_pipeline_invariants_test.dart',
  'test/parser/ssh_pipeline_invariants_test.dart',
  'test/parser/trojan_pipeline_invariants_test.dart',
  'test/parser/vmess_pipeline_invariants_test.dart',
  'test/parser/hysteria2_pipeline_invariants_test.dart',
  'test/parser/masque_pipeline_invariants_test.dart',
  'test/parser/tuic_pipeline_invariants_test.dart',
  'test/parser/vless_pipeline_invariants_test.dart',
  'test/parser/wireguard_pipeline_invariants_test.dart',
];
