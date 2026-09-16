/// §445 — каталоги состояния узлов Tailscale: индекс «слот → ключ узла → имя
/// каталога» (`<root>/tailscale_state.json`) и файловые операции над
/// `<root>/tailscale/`. Спека: `docs/spec/tasks/445-tailscale-state-dir-lifecycle.md`.
///
/// Имя каталога выдаётся узлу один раз и не меняется: переименование и
/// перенос узла переписывают ключ записи, файлы не двигаются (каталог может
/// быть открыт живым ядром). Каталог удаляется, только когда на него не
/// ссылается ни один слот, и:
///
/// - при сборке и операции реестра — если ядро остановлено ([coreStopped]);
/// - при Save as и Delete слота — сразу: у слота, который не `current`, узлов
///   в работающем конфиге нет.
///
/// Пока в справочнике Workspaces есть слот без набора записей, каталоги,
/// найденные на диске при создании индекса ([_Index.legacy]), не удаляются:
/// это имена 2.24.0 по финальному тегу, и они могут принадлежать такому слоту.
///
/// Корень — native `filesDir`; у `WorkspaceStore` тот же каталог через
/// `getApplicationSupportDirectory()` (§417 §2.1). Все операции сериализованы.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../app_log.dart';
import 'state_keys.dart';

class TailscaleStateStore {
  TailscaleStateStore._();

  static final TailscaleStateStore I = TailscaleStateStore._();

  static const indexFileName = 'tailscale_state.json';
  static const dirName = 'tailscale';
  static const indexVersion = 1;

  Future<void> _lock = Future<void>.value();
  int _tmpSeq = 0;

  // ---------------------------------------------------------------------------
  // Сборка
  // ---------------------------------------------------------------------------

  /// Имена каталогов узлов Tailscale слота [slot] для сборки (карта по ссылке
  /// узла). Узлу без записи выдаётся имя; на первой сборке слота — каталог
  /// 2.24.0 по финальной форме, если он есть (миграция). Если ядро
  /// остановлено — сироты: записи без узлов, наборы слотов вне [slotNames],
  /// каталоги без ссылок.
  ///
  /// [slotNames] — имена справочника Workspaces (`current` включён).
  Future<Map<NodeSpec, String>> prepareForBuild({
    required String root,
    required String slot,
    required Set<String> slotNames,
    required List<ServerList> lists,
    required Future<bool> Function() coreStopped,
  }) =>
      _locked(() async {
        final scan = scanTailscaleStateNodes(lists);
        final tsDir = _dir(root);
        final read = await _read(root);
        final onDisk = await _entryNames(tsDir);
        if (read == null && scan.nodes.isEmpty && onDisk.all.isEmpty) {
          return Map<NodeSpec, String>.identity();
        }
        final index = read ?? _Index.created(onDisk.dirs);
        var changed = read == null;
        final names = {...slotNames, slot};

        final firstBuild = !index.slots.containsKey(slot);
        final records = Map<String, String>.of(index.slots[slot] ?? const {});
        final otherSlotsRefs = <String>{
          for (final e in index.slots.entries)
            if (e.key != slot && names.contains(e.key)) ...e.value.values,
        };
        final anySlotRefs = <String>{
          for (final e in index.slots.entries) ...e.value.values,
        };

        final out = Map<NodeSpec, String>.identity();
        final taken = <String>{};
        for (final n in scan.nodes) {
          final d = records[n.key];
          if (d != null && taken.add(d)) out[n.node] = d;
        }
        for (final n in scan.nodes) {
          if (out.containsKey(n.node)) continue;
          String? name;
          if (firstBuild) {
            name = _adopt(n.baseName, taken, index.legacy, otherSlotsRefs);
            if (name != null) {
              AppLog.I.info('Tailscale state of node "${n.node.tag}" kept: '
                  '$dirName/$name');
            }
          }
          name ??= _allocate(
              n.baseName, taken, onDisk.all, {...anySlotRefs, ...records.values});
          records[n.key] = name;
          taken.add(name);
          out[n.node] = name;
          changed = true;
        }

        // Сироты — только при остановленном ядре.
        final keys = scan.keys;
        final prunable = [
          for (final k in records.keys)
            if (!keys.contains(k) &&
                !scan.unresolvedContainers
                    .any((id) => tailscaleKeyInContainer(k, id)))
              k,
        ];
        final ghosts = [
          for (final s in index.slots.keys)
            if (s != slot && !names.contains(s)) s,
        ];
        final protectedDirs = _explicitNames(root, scan.explicitDirs);
        Set<String> orphansAfter(Map<String, String> current) {
          final refs = <String>{
            ...current.values,
            for (final e in index.slots.entries)
              if (e.key != slot && !ghosts.contains(e.key)) ...e.value.values,
          };
          final guard = _hasUnindexed(index, names, except: slot)
              ? index.legacy
              : const <String>{};
          return {
            for (final d in onDisk.dirs)
              if (!refs.contains(d) &&
                  !protectedDirs.contains(d) &&
                  !guard.contains(d))
                d,
          };
        }

        final pruned = Map<String, String>.of(records)
          ..removeWhere((k, _) => prunable.contains(k));
        final orphans = orphansAfter(pruned);
        if ((prunable.isNotEmpty || ghosts.isNotEmpty || orphans.isNotEmpty) &&
            await coreStopped()) {
          records
            ..clear()
            ..addAll(pruned);
          for (final g in ghosts) {
            index.slots.remove(g);
          }
          changed = changed || prunable.isNotEmpty || ghosts.isNotEmpty;
          await _deleteDirs(root, orphans);
        }

        if (firstBuild || !_sameMap(index.slots[slot], records)) changed = true;
        index.slots[slot] = records;
        if (!_hasUnindexed(index, names) && index.legacy.isNotEmpty) {
          index.legacy.clear();
          changed = true;
        }
        if (changed) await _write(root, index);
        return out;
      });

  /// Каталог 2.24.0 для узла: [base], `-1`, `-2`… в порядке узлов (порядок
  /// суффиксов `allocateTag`). Имя, уже выданное в этой сборке, пропускается;
  /// существующий каталог чужого слота — тоже; первого отсутствующего на диске
  /// имени — конец поиска.
  String? _adopt(
    String base,
    Set<String> taken,
    Set<String> legacy,
    Set<String> otherSlotsRefs,
  ) {
    for (final c in _candidates(base)) {
      if (taken.contains(c)) continue;
      if (!legacy.contains(c)) return null;
      if (otherSlotsRefs.contains(c)) continue;
      return c;
    }
    return null;
  }

  /// Свободное имя: [base], `-1`, `-2`… — не выдано в этой сборке, нет на
  /// диске (сирота, ждущая удаления, не наследуется) и не записано у слотов.
  String _allocate(
    String base,
    Set<String> taken,
    Set<String> onDisk,
    Set<String> refs,
  ) {
    for (final c in _candidates(base)) {
      if (taken.contains(c) || onDisk.contains(c) || refs.contains(c)) {
        continue;
      }
      return c;
    }
    throw StateError('no free tailscale state name for "$base"');
  }

  Iterable<String> _candidates(String base) sync* {
    yield base;
    for (var i = 1; i < 100000; i++) {
      yield '$base-$i';
    }
  }

  // ---------------------------------------------------------------------------
  // Реестр
  // ---------------------------------------------------------------------------

  /// Операция контроллера над источниками: записи слота [slot] идут за узлами
  /// ([diffTailscaleStateKeys]). Удалённый узел или источник снимает запись
  /// сразу (иначе тёзка, добавленный следом, унаследовал бы личность), его
  /// каталог удаляется, если на него больше никто не ссылается и ядро
  /// остановлено. Слот без набора записей не трогается — его первая сборка
  /// всё выдаст сама.
  Future<void> relink({
    required String root,
    required String slot,
    required Set<String> slotNames,
    required List<ServerList> before,
    required List<ServerList> after,
    Map<NodeSpec, NodeSpec> renamed = const {},
    required Future<bool> Function() coreStopped,
  }) =>
      _locked(() async {
        final index = await _read(root);
        final records = index?.slots[slot];
        if (index == null || records == null) return;
        final diff = diffTailscaleStateKeys(before, after, renamed: renamed);
        if (diff.moves.isEmpty &&
            diff.gone.isEmpty &&
            diff.goneContainers.isEmpty) {
          return;
        }

        final next = <String, String>{};
        final dropped = <String>{};
        records.forEach((k, d) {
          if (diff.moves.containsKey(k)) return;
          if (diff.gone.contains(k) ||
              diff.goneContainers.any((id) => tailscaleKeyInContainer(k, id))) {
            dropped.add(d);
            return;
          }
          next[k] = d;
        });
        diff.moves.forEach((from, to) {
          final d = records[from];
          if (d == null) return;
          final stale = next[to];
          if (stale != null && stale != d) {
            AppLog.I.warning('Tailscale state record "$to" was taken by '
                '$dirName/$stale; node moved from "$from" keeps $dirName/$d');
            dropped.add(stale);
          }
          next[to] = d;
        });
        if (_sameMap(records, next)) return;
        index.slots[slot] = next;
        await _write(root, index);

        final candidates =
            _unreferenced(index, {...slotNames, slot}, dropped);
        if (candidates.isNotEmpty && await coreStopped()) {
          await _deleteDirs(root, candidates);
        }
      });

  // ---------------------------------------------------------------------------
  // Workspaces
  // ---------------------------------------------------------------------------

  /// Save as: набор записей [to] := копия набора [from] (`current`). Каталоги
  /// не копируются: узлы-копии в обоих слотах — одно устройство. Каталоги
  /// прежнего набора [to], на которые больше никто не ссылается, удаляются
  /// сразу ([to] не `current`). [slotNames] — справочник после операции.
  Future<void> forkSlot({
    required String root,
    required String from,
    required String to,
    required Set<String> slotNames,
  }) =>
      _locked(() async {
        if (from == to) return;
        final index = await _read(root);
        if (index == null) return;
        final old = index.slots[to];
        final src = index.slots[from];
        if (src == null) {
          if (old == null) return;
          index.slots.remove(to);
        } else {
          index.slots[to] = Map<String, String>.of(src);
        }
        await _write(root, index);
        if (old != null) {
          await _deleteDirs(
              root, _unreferenced(index, {...slotNames, to}, old.values));
        }
      });

  /// Rename слота: набор записей переезжает под новое имя, каталоги те же.
  Future<void> renameSlot({
    required String root,
    required String from,
    required String to,
  }) =>
      _locked(() async {
        if (from == to) return;
        final index = await _read(root);
        final set = index?.slots.remove(from);
        if (index == null || set == null) return;
        index.slots[to] = set;
        await _write(root, index);
      });

  /// Delete слота: набор записей снимается, каталоги без других ссылок
  /// удаляются сразу (удалить можно только не `current`). [slotNames] —
  /// справочник после операции.
  Future<void> dropSlot({
    required String root,
    required String name,
    required Set<String> slotNames,
  }) =>
      _locked(() async {
        final index = await _read(root);
        final set = index?.slots.remove(name);
        if (index == null || set == null) return;
        await _write(root, index);
        await _deleteDirs(root, _unreferenced(index, slotNames, set.values));
      });

  // ---------------------------------------------------------------------------
  // Общее
  // ---------------------------------------------------------------------------

  /// Имена из [dirs], на которые не ссылается ни один набор [index]; при слоте
  /// справочника без набора — кроме каталогов 2.24.0.
  Set<String> _unreferenced(
    _Index index,
    Set<String> names,
    Iterable<String> dirs,
  ) {
    final refs = {for (final s in index.slots.values) ...s.values};
    final guard =
        _hasUnindexed(index, names) ? index.legacy : const <String>{};
    return {
      for (final d in dirs)
        if (!refs.contains(d) && !guard.contains(d)) d,
    };
  }

  /// Есть слот справочника (кроме [except]) без набора записей.
  bool _hasUnindexed(_Index index, Set<String> names, {String? except}) =>
      names.any((n) => n != except && !index.slots.containsKey(n));

  Future<void> _deleteDirs(String root, Iterable<String> names) async {
    for (final name in names) {
      if (name.isEmpty || name == '.' || name == '..' || name.contains('/')) {
        continue;
      }
      final d = Directory('${_dir(root).path}/$name');
      try {
        if (await FileSystemEntity.type(d.path, followLinks: false) !=
            FileSystemEntityType.directory) {
          continue;
        }
        await d.delete(recursive: true);
        AppLog.I.info('Tailscale state of a removed node deleted: '
            '$dirName/$name');
      } catch (e) {
        AppLog.I.warning('Tailscale state $dirName/$name not deleted: $e');
      }
    }
  }

  /// Имена каталогов в `tailscale/`, заданных узлам явно (абсолютный путь под
  /// корнем или относительный `tailscale/<имя>`).
  Set<String> _explicitNames(String root, Set<String> explicit) {
    final out = <String>{};
    final abs = '${_dir(root).path}/';
    final rel = '$dirName/';
    for (final raw in explicit) {
      final rest = raw.startsWith(abs)
          ? raw.substring(abs.length)
          : raw.startsWith(rel)
              ? raw.substring(rel.length)
              : null;
      if (rest == null || rest.isEmpty) continue;
      out.add(rest.split('/').first);
    }
    return out;
  }

  Directory _dir(String root) => Directory('$root/$dirName');

  Future<({Set<String> dirs, Set<String> all})> _entryNames(
      Directory dir) async {
    final dirs = <String>{};
    final all = <String>{};
    try {
      if (!await dir.exists()) return (dirs: dirs, all: all);
      await for (final e in dir.list(followLinks: false)) {
        final name = e.path.substring(dir.path.length + 1);
        all.add(name);
        if (e is Directory) dirs.add(name);
      }
    } catch (e) {
      AppLog.I.warning('Tailscale state directory unreadable: $e');
    }
    return (dirs: dirs, all: all);
  }

  Future<_Index?> _read(String root) async {
    final f = File('$root/$indexFileName');
    try {
      if (!await f.exists()) return null;
      final raw = jsonDecode(await f.readAsString());
      if (raw is Map) return _Index.fromJson(raw);
    } catch (e) {
      AppLog.I.warning('Tailscale state index unreadable, rebuilding: $e');
    }
    return null;
  }

  Future<void> _write(String root, _Index index) async {
    final f = File('$root/$indexFileName');
    try {
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.${_tmpSeq++}.tmp');
      await tmp.writeAsString(
          const JsonEncoder.withIndent('  ').convert(index.toJson()),
          flush: true);
      await tmp.rename(f.path);
    } catch (e) {
      AppLog.I.warning('Tailscale state index not saved: $e');
    }
  }

  static bool _sameMap(Map<String, String>? a, Map<String, String> b) {
    if (a == null || a.length != b.length) return false;
    for (final e in b.entries) {
      if (a[e.key] != e.value) return false;
    }
    return true;
  }

  Future<T> _locked<T>(Future<T> Function() body) {
    final prev = _lock;
    final completer = Completer<void>();
    _lock = completer.future;
    return prev.then((_) => body()).whenComplete(completer.complete);
  }
}

/// Индекс `tailscale_state.json`.
class _Index {
  _Index(this.slots, this.legacy);

  /// Индекс создаётся впервые: каталоги на диске — имена 2.24.0.
  factory _Index.created(Set<String> onDisk) =>
      _Index(<String, Map<String, String>>{}, {...onDisk});

  factory _Index.fromJson(Map<dynamic, dynamic> j) {
    final slots = <String, Map<String, String>>{};
    final raw = j['slots'];
    if (raw is Map) {
      raw.forEach((name, set) {
        if (name is! String || set is! Map) return;
        final records = <String, String>{};
        set.forEach((k, v) {
          if (k is String && v is String && v.isNotEmpty) records[k] = v;
        });
        slots[name] = records;
      });
    }
    final legacy = <String>{
      if (j['legacy'] is List)
        for (final v in j['legacy'] as List)
          if (v is String) v,
    };
    return _Index(slots, legacy);
  }

  /// Имя слота → ключ узла → имя каталога.
  final Map<String, Map<String, String>> slots;

  /// Каталоги, найденные при создании индекса (имена 2.24.0). Нужны, пока в
  /// справочнике есть слот без набора записей; потом очищаются.
  final Set<String> legacy;

  Map<String, dynamic> toJson() => {
        'version': TailscaleStateStore.indexVersion,
        'slots': slots,
        if (legacy.isNotEmpty) 'legacy': (legacy.toList()..sort()),
      };
}
