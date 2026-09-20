// Страж dart-ссылок реестра контракта (§491).
//
// У записей реестра поле `refs.dart` указывает на файлы LxBox, где живёт
// правило. После снятия рукописных мапперов (фича 480) часть ссылок
// указывает на удалённые пути. Зеркало `assets/contract` править нельзя —
// правки идут у лаунчера. Тест не валит протухшие ссылки сразу, а сверяет их
// с allowlist `registry_dart_refs_known_stale.txt`: новая протухшая ссылка вне
// списка — красный; запись из списка, ставшая живой или исчезнувшая из
// реестра — красный (список самоочищается).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _registryRoot = 'assets/contract/registry';
const _knownStaleFile =
    'test/contract/registry_dart_refs_known_stale.txt';

/// Одна ссылка `refs.dart` с контекстом в реестре.
typedef RegistryDartRef = ({
  String registryFile,
  String entry,
  String ref,
});

/// Путь к `.dart`-файлу из строки ссылки реестра.
///
/// Ссылки пишутся относительно каталога `app/` (`lib/...`) или корня
/// репозитория (`app/lib/...`). После `:строка`, `(` или `#` — комментарий
/// (символ, диапазон строк, пояснение).
String? dartFilePathFromRef(String ref) {
  var s = ref.trim();
  if (s.isEmpty) return null;
  if (s.startsWith('app/')) s = s.substring(4);
  final match = RegExp(r'^lib/[^\s:(#]+').firstMatch(s);
  return match?.group(0);
}

/// Собирает все `refs.dart` из зеркала реестра.
List<RegistryDartRef> collectRegistryDartRefs(String registryRoot) {
  final root = Directory(registryRoot);
  final out = <RegistryDartRef>[];

  void walk(dynamic node, String registryFile, String path) {
    if (node is Map) {
      final refs = node['refs'];
      if (refs is Map && refs['dart'] is List) {
        final entry = path.isEmpty ? '(root)' : path;
        for (final raw in refs['dart'] as List) {
          final ref = raw.toString();
          out.add((
            registryFile: registryFile,
            entry: entry,
            ref: ref,
          ));
        }
      }
      for (final e in node.entries) {
        final childPath =
            path.isEmpty ? e.key.toString() : '$path.${e.key}';
        walk(e.value, registryFile, childPath);
      }
    } else if (node is List) {
      for (var i = 0; i < node.length; i++) {
        walk(node[i], registryFile, '$path[$i]');
      }
    }
  }

  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.json')) continue;
    final rel = entity.path
        .replaceFirst('$registryRoot/', 'registry/')
        .replaceFirst('assets/contract/registry/', 'registry/');
    final data = jsonDecode(entity.readAsStringSync());
    walk(data, rel, '');
  }

  return out;
}

Set<String> loadKnownStaleRefs(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue,
      reason: 'нет allowlist протухших ссылок: $path');
  final out = <String>{};
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    out.add(trimmed);
  }
  return out;
}

void main() {
  final synced = Directory(_registryRoot).existsSync();
  final skip = synced ? null : 'зеркало реестра отсутствует';

  group('§491 — dart-ссылки реестра', () {
    test('refs.dart указывают на существующие файлы или в allowlist', () {
      final refs = collectRegistryDartRefs(_registryRoot);
      expect(refs, isNotEmpty, reason: 'в реестре нет refs.dart');

      final allRefStrings = refs.map((r) => r.ref).toSet();
      final staleNow = <String>{};
      final unparseable = <RegistryDartRef>[];

      for (final r in refs) {
        final path = dartFilePathFromRef(r.ref);
        if (path == null) {
          unparseable.add(r);
          continue;
        }
        if (!File(path).existsSync()) staleNow.add(r.ref);
      }

      expect(
        unparseable,
        isEmpty,
        reason: 'refs.dart без пути к .dart-файлу — поправьте парсер или '
            'формат ссылки: $unparseable',
      );

      final knownStale = loadKnownStaleRefs(_knownStaleFile);

      final unexpected = staleNow.difference(knownStale).toList()..sort();
      expect(
        unexpected,
        isEmpty,
        reason: 'новые протухшие dart-ссылки вне allowlist — добавьте в '
            'registry_dart_refs_known_stale.txt и передайте лаунчеру '
            '(docs/spec/tasks/491-registry-dart-refs.md): $unexpected',
      );

      final resolved = knownStale
          .where((ref) => allRefStrings.contains(ref) && !staleNow.contains(ref))
          .toList()
        ..sort();
      expect(
        resolved,
        isEmpty,
        reason: 'эти ссылки снова живы — уберите из '
            'registry_dart_refs_known_stale.txt: $resolved',
      );

      final orphaned = knownStale.difference(allRefStrings).toList()..sort();
      expect(
        orphaned,
        isEmpty,
        reason: 'эти записи allowlist больше не встречаются в реестре — '
            'уберите из registry_dart_refs_known_stale.txt: $orphaned',
      );
    }, skip: skip);
  });
}
