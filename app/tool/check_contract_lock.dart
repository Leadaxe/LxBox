// Проверка синхронизации общего контракта (SPEC 103, фаза 5).
//
// В CI репозитория лаунчера нет, поэтому пересинхронизировать контракт здесь
// нечем. Но одно проверить можно и нужно: если копия контракта в дереве ЕСТЬ,
// её содержимое обязано совпадать с зафиксированным в contract.lock хешем.
// Иначе кто-то правил копию руками — а копия не источник, и правка потерялась
// бы при следующей синхронизации.
//
// Копии нет вовсе — не ошибка: контрактные тесты сами пропускаются, а
// разработчик синхронизирует локально (tool/sync_contract.sh).
//
// Запуск: dart run tool/check_contract_lock.dart

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

void main(List<String> args) {
  final lockFile = File('contract.lock');
  final dir = Directory('contract');

  if (!dir.existsSync()) {
    stdout.writeln('contract/: копии нет — контрактные тесты пропускаются '
        '(синхронизируйте локально: bash tool/sync_contract.sh)');
    return;
  }
  if (!lockFile.existsSync()) {
    stderr.writeln('contract/ есть, а contract.lock нет: непонятно, какая '
        'версия контракта в дереве. Запустите tool/sync_contract.sh');
    exitCode = 1;
    return;
  }

  final expected = _lockHash(lockFile.readAsStringSync());
  if (expected == null) {
    stderr.writeln('contract.lock без поля sha256');
    exitCode = 1;
    return;
  }

  final actual = _treeHash(dir);
  if (actual != expected) {
    stderr.writeln('Копия контракта не совпадает с contract.lock:\n'
        '  в дереве: $actual\n'
        '  в lock:   $expected\n'
        'Копию не правят руками — источник живёт в репозитории лаунчера. '
        'Запустите tool/sync_contract.sh, чтобы обновить копию и lock.');
    exitCode = 1;
    return;
  }

  stdout.writeln('contract/: совпадает с contract.lock ($actual)');
}

String? _lockHash(String content) {
  for (final line in const LineSplitter().convert(content)) {
    if (line.startsWith('sha256=')) return line.substring('sha256='.length).trim();
  }
  return null;
}

/// Хеш дерева — ТОТ ЖЕ алгоритм, что в tool/sync_contract.sh:
/// `find -type f | sort | xargs cat | shasum -a 256`, то есть sha256 от
/// склеенного содержимого файлов в байтовом порядке путей. Имена в хеш не
/// входят. Считать иначе нельзя: проверка падала бы на каждом прогоне.
String _treeHash(Directory dir) {
  final paths = dir
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => f.path)
      .toList()
    ..sort(); // байтовый порядок, как LC_ALL=C sort

  // Склеиваем содержимое ровно так, как это делает `xargs cat`. Файлы
  // контракта — текстовые и мелкие (единицы мегабайт на всё дерево), поэтому
  // держать их в памяти дешевле, чем тянуть ради потокового хеша ещё один
  // пакет в зависимости.
  final bytes = <int>[];
  for (final path in paths) {
    bytes.addAll(File(path).readAsBytesSync());
  }
  return sha256.convert(bytes).toString();
}
