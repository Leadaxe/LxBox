import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import '../app_log.dart';

/// §417 — Workspaces: именованные копии состояния приложения.
///
/// Модель — слоты сохранения. **Сцена** — рабочие пути (те же, что и без
/// фичи, ничего не переезжает). **Слот** — папка `workspaces/<имя>/` с
/// копией состояния. `current` в справочнике — имя слота, который сейчас
/// на сцене; до первого использования фичи это «Default» без папки.
///
/// Состав слота перечислен в ОДНОМ месте — [kSlotEntries]. Новый файл
/// состояния приложения обязан либо попасть сюда, либо быть явно отнесён
/// к «свойствам устройства» (спека §417 п. 2.1).
///
/// Операции:
///   - [saveAs] — копия сцены в слот, `current` = слот.
///   - [load] — сохранить сцену в слот `current`, скопировать целевой слот на
///     сцену, `current` = цель. Терять нечего, подтверждений не нужно.
///     Стоп VPN, flush стораджа и перечитывание состояния — на вызывающей
///     стороне (`HomeScreen`), здесь только файлы.
///   - [recover] — на старте приложения: доводит загрузку, убитую посреди
///     копирования (журнал `pending`, шаги идемпотентны).
///
/// Все операции сериализованы одной очередью ([_locked]).
class WorkspaceStore {
  WorkspaceStore._();

  static final WorkspaceStore I = WorkspaceStore._();

  static const manifestFileName = 'workspaces.json';
  static const slotsDirName = 'workspaces';
  static const defaultName = 'Default';
  static const manifestVersion = 1;
  static const nameMaxLength = 64;

  /// Состав слота. Порядок = порядок копирования.
  ///
  /// Корни: `documents` = `getApplicationDocumentsDirectory()` (`app_flutter/`
  /// на Android), `support` = `getApplicationSupportDirectory()` (`files/`,
  /// тот же каталог, куда пишет ядро). Пути совпадают с владельцами файлов:
  /// `settings_storage/io.dart`, `rule_set_downloader.dart`,
  /// `subscription/http_cache.dart`.
  ///
  /// НЕ в слоте (спека §417 п. 2.1): `singbox_config.json` (пересобирается
  /// после загрузки всегда), `cache.db` ядра (открыт под живым VPN, копия
  /// может быть битой), `.bak`/`.tmp` io-слоя, `support_state.json`, логи,
  /// crash/oom-репорты, тема.
  static const List<SlotEntry> kSlotEntries = [
    SlotEntry(SlotRoot.documents, 'lxbox_settings.json', isDir: false),
    SlotEntry(SlotRoot.documents, 'rule_sets', isDir: true),
    SlotEntry(SlotRoot.support, 'sub_cache', isDir: true),
  ];

  /// Имя файла настроек — для touch после загрузки и удаления `.bak`.
  static const _settingsFileName = 'lxbox_settings.json';
  static const _settingsBakName = 'lxbox_settings.json.bak';
  static const _tmpSuffix = '.tmp';

  Future<void> _lock = Future<void>.value();
  int _tmpSeq = 0;

  // ---------------------------------------------------------------------------
  // Имена
  // ---------------------------------------------------------------------------

  /// Имя слота = имя папки. `null` — валидно. Проверять ДО [saveAs]/[rename];
  /// сами операции бросают [WorkspaceError] с `invalidName`.
  static WorkspaceNameError? validateName(String raw) {
    final name = raw.trim();
    if (name.isEmpty) return WorkspaceNameError.empty;
    if (name.length > nameMaxLength) return WorkspaceNameError.tooLong;
    if (name == '.' || name == '..' || name.startsWith('.')) {
      return WorkspaceNameError.leadingDot;
    }
    for (final cu in name.codeUnits) {
      if (cu < 0x20 || cu == 0x2F /* / */ || cu == 0x5C /* \ */ || cu == 0x7F) {
        return WorkspaceNameError.forbiddenChars;
      }
    }
    return null;
  }

  static String _requireValid(String raw) {
    final err = validateName(raw);
    if (err != null) {
      throw WorkspaceError(WorkspaceErrorKind.invalidName, raw, nameError: err);
    }
    return raw.trim();
  }

  // ---------------------------------------------------------------------------
  // Справочник
  // ---------------------------------------------------------------------------

  /// Текущий справочник. Без файла — дефолт: `current` = «Default», слотов
  /// нет. Ничего на диск не пишет.
  Future<WorkspaceManifest> readManifest() async {
    final f = await _manifestFile();
    if (!await f.exists()) return WorkspaceManifest.initial();
    try {
      final raw = jsonDecode(await f.readAsString());
      if (raw is Map<String, dynamic>) return WorkspaceManifest.fromJson(raw);
    } catch (e) {
      AppLog.I.error('workspaces: manifest unreadable, treating as absent: $e');
    }
    return WorkspaceManifest.initial();
  }

  Future<bool> manifestExists() async => (await _manifestFile()).exists();

  Future<List<WorkspaceSlot>> listSlots() async =>
      (await readManifest()).slots;

  Future<String> currentName() async => (await readManifest()).current;

  Future<void> _writeManifest(WorkspaceManifest m) async {
    final f = await _manifestFile();
    await _writeStringAtomic(
        f, const JsonEncoder.withIndent('  ').convert(m.toJson()));
  }

  // ---------------------------------------------------------------------------
  // Операции
  // ---------------------------------------------------------------------------

  /// Скопировать сцену в слот [rawName] и сделать его `current`.
  /// Существующий слот перезаписывается — подтверждение спрашивает UI.
  Future<void> saveAs(String rawName) => _locked(() async {
        final name = _requireValid(rawName);
        var m = await readManifest();
        await _copySceneToSlot(name);
        m = m.withSlotSaved(name, DateTime.now()).copyWith(current: name);
        await _writeManifest(m);
        AppLog.I.info('workspaces: saved scene as "$name"');
      });

  /// Загрузить слот [rawName]. Сначала сцена уходит в слот `current`
  /// (папка создаётся, если её ещё нет — так появляется «Default»).
  ///
  /// Возвращает `false`, если [rawName] уже `current` (no-op). Бросает
  /// [WorkspaceError.notFound], если слота нет.
  ///
  /// Вызывающая сторона обязана ДО вызова опустить VPN и сбросить сторадж на
  /// диск, а ПОСЛЕ — перечитать состояние (спека §417 п. 2.3/2.6).
  Future<bool> load(String rawName) => _locked(() async {
        final name = rawName.trim();
        var m = await readManifest();
        if (name == m.current) return false;
        if (!await _slotExists(name)) {
          throw WorkspaceError(WorkspaceErrorKind.notFound, name);
        }
        // Журнал: с этого момента убийство процесса доводится в [recover].
        m = m.copyWith(pending: WorkspacePending.load(name));
        await _writeManifest(m);
        await _performLoad(m);
        return true;
      });

  /// Доводка загрузки, убитой посреди копирования. Зовётся на старте ДО
  /// первого чтения `SettingsStorage`. Без справочника — один `exists()`.
  /// Возвращает `true`, если что-то доводили.
  Future<bool> recover() => _locked(() async {
        final f = await _manifestFile();
        if (!await f.exists()) return false;
        final m = await readManifest();
        final p = m.pending;
        if (p == null) return false;
        if (p.op == WorkspacePending.opLoad && await _slotExists(p.target)) {
          AppLog.I.warning(
              'workspaces: unfinished load of "${p.target}" — redoing');
          await _performLoad(m);
          return true;
        }
        // Неизвестная операция или цель исчезла — журнал снимаем, сцена
        // остаётся как есть (последнее известное состояние `current`).
        AppLog.I.warning(
            'workspaces: dropping stale pending ${p.op} → "${p.target}"');
        await _writeManifest(m.copyWith(clearPending: true));
        return false;
      });

  /// Шаги 5–7 спеки: сцена → слот `current`, слот цели → сцена,
  /// `current` = цель, журнал снят. Идемпотентны: [recover] повторяет их
  /// целиком.
  Future<void> _performLoad(WorkspaceManifest m) async {
    final target = m.pending!.target;
    final now = DateTime.now();
    await _copySceneToSlot(m.current);
    var next = m.withSlotSaved(m.current, now);
    await _copySlotToScene(target);
    await _touchSettings();
    next = next.copyWith(current: target, clearPending: true);
    await _writeManifest(next);
    AppLog.I.info('workspaces: loaded "$target" (previous "${m.current}" saved)');
  }

  /// Переименовать слот. `current` переименовывается вместе с папкой.
  Future<void> rename(String rawOld, String rawNew) => _locked(() async {
        final oldName = rawOld.trim();
        final newName = _requireValid(rawNew);
        if (oldName == newName) return;
        var m = await readManifest();
        if (!m.hasSlot(oldName)) {
          throw WorkspaceError(WorkspaceErrorKind.notFound, oldName);
        }
        if (m.hasSlot(newName) || await _slotExists(newName)) {
          throw WorkspaceError(WorkspaceErrorKind.exists, newName);
        }
        final dir = await _slotDir(oldName);
        if (await dir.exists()) {
          await dir.rename((await _slotDir(newName)).path);
        }
        m = m.withSlotRenamed(oldName, newName);
        if (m.current == oldName) m = m.copyWith(current: newName);
        await _writeManifest(m);
      });

  /// Удалить слот. `current` удалить нельзя — это адрес автосохранения.
  Future<void> delete(String rawName) => _locked(() async {
        final name = rawName.trim();
        final m = await readManifest();
        if (name == m.current) {
          throw WorkspaceError(WorkspaceErrorKind.isCurrent, name);
        }
        if (!m.hasSlot(name)) {
          throw WorkspaceError(WorkspaceErrorKind.notFound, name);
        }
        final dir = await _slotDir(name);
        if (await dir.exists()) await dir.delete(recursive: true);
        await _writeManifest(m.withSlotRemoved(name));
      });

  /// Размер слота на диске в байтах (для экрана управления). 0 — папки нет.
  Future<int> slotSizeBytes(String name) async {
    final dir = await _slotDir(name.trim());
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  // ---------------------------------------------------------------------------
  // Копирование
  // ---------------------------------------------------------------------------

  /// Сцена → слот. Слот после копии равен сцене: позиции, которых на сцене
  /// нет, из слота удаляются.
  Future<void> _copySceneToSlot(String name) async {
    final slot = await _slotDir(name);
    await slot.create(recursive: true);
    for (final e in kSlotEntries) {
      final src = await _scenePath(e);
      final dst = '${slot.path}/${e.name}';
      if (e.isDir) {
        await _replaceDir(Directory(src), Directory(dst));
      } else {
        await _replaceFile(File(src), File(dst));
      }
    }
  }

  /// Слот → сцена. Сцена после копии равна слоту. `.bak` настроек удаляется:
  /// это снимок ПРЕЖНЕГО слота, и восстановление из него при битом main
  /// молча подменило бы состояние.
  Future<void> _copySlotToScene(String name) async {
    final slot = await _slotDir(name);
    for (final e in kSlotEntries) {
      final src = '${slot.path}/${e.name}';
      final dst = await _scenePath(e);
      if (e.isDir) {
        await _replaceDir(Directory(src), Directory(dst));
      } else {
        await _replaceFile(File(src), File(dst));
      }
    }
    final bak = File('${(await _docs()).path}/$_settingsBakName');
    if (await bak.exists()) await bak.delete();
  }

  /// Настройки заведомо новее `singbox_config.json` → bootstrap-проверка
  /// §076 скажет «грязно» и новый `HomeScreen` пересоберёт конфиг штатной
  /// воронкой (спека §417 п. 2.3 шаг 8).
  Future<void> _touchSettings() async {
    final f = File('${(await _docs()).path}/$_settingsFileName');
    if (await f.exists()) await f.setLastModified(DateTime.now());
  }

  /// Файл: tmp рядом с целью + rename — на сцене никогда нет полуфайла.
  /// Нет источника → цели тоже не должно быть.
  Future<void> _replaceFile(File src, File dst) async {
    if (!await src.exists()) {
      if (await dst.exists()) await dst.delete();
      return;
    }
    await dst.parent.create(recursive: true);
    final tmp = File('${dst.path}.${_tmpSeq++}$_tmpSuffix');
    await tmp.writeAsBytes(await src.readAsBytes(), flush: true);
    await tmp.rename(dst.path);
  }

  /// Папка: целевая сносится целиком и копируется заново — в источнике
  /// может быть меньше файлов. `.tmp` атомарных писателей (`http_cache`,
  /// `rule_set_downloader`) не копируются: это сироты, не состояние.
  Future<void> _replaceDir(Directory src, Directory dst) async {
    if (await dst.exists()) await dst.delete(recursive: true);
    if (!await src.exists()) return;
    await dst.create(recursive: true);
    await for (final e in src.list(recursive: true, followLinks: false)) {
      final rel = e.path.substring(src.path.length + 1);
      if (e is Directory) {
        await Directory('${dst.path}/$rel').create(recursive: true);
      } else if (e is File) {
        if (rel.endsWith(_tmpSuffix)) continue;
        final out = File('${dst.path}/$rel');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(await e.readAsBytes(), flush: true);
      }
    }
  }

  Future<void> _writeStringAtomic(File f, String content) async {
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.${_tmpSeq++}$_tmpSuffix');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(f.path);
  }

  // ---------------------------------------------------------------------------
  // Пути
  // ---------------------------------------------------------------------------

  Future<Directory> _docs() => getApplicationDocumentsDirectory();
  Future<Directory> _support() => getApplicationSupportDirectory();

  Future<File> _manifestFile() async =>
      File('${(await _docs()).path}/$manifestFileName');

  Future<Directory> _slotDir(String name) async =>
      Directory('${(await _docs()).path}/$slotsDirName/$name');

  Future<bool> _slotExists(String name) async => (await _slotDir(name)).exists();

  Future<String> _scenePath(SlotEntry e) async {
    final root = switch (e.root) {
      SlotRoot.documents => await _docs(),
      SlotRoot.support => await _support(),
    };
    return '${root.path}/${e.name}';
  }

  /// Путь папки слота — для тестов и экрана управления.
  @visibleForTesting
  Future<Directory> slotDirForTesting(String name) => _slotDir(name);

  Future<T> _locked<T>(Future<T> Function() body) {
    final prev = _lock;
    final completer = Completer<void>();
    _lock = completer.future;
    return prev.then((_) => body()).whenComplete(completer.complete);
  }
}

enum SlotRoot { documents, support }

class SlotEntry {
  const SlotEntry(this.root, this.name, {required this.isDir});
  final SlotRoot root;
  final String name;
  final bool isDir;
}

enum WorkspaceNameError { empty, tooLong, forbiddenChars, leadingDot }

enum WorkspaceErrorKind { notFound, exists, isCurrent, invalidName }

class WorkspaceError implements Exception {
  const WorkspaceError(this.kind, this.name, {this.nameError});
  final WorkspaceErrorKind kind;
  final String name;
  final WorkspaceNameError? nameError;

  @override
  String toString() => 'WorkspaceError(${kind.name}, "$name"'
      '${nameError == null ? '' : ', ${nameError!.name}'})';
}

class WorkspaceSlot {
  const WorkspaceSlot({required this.name, required this.savedAt});
  final String name;
  final DateTime savedAt;

  Map<String, dynamic> toJson() =>
      {'name': name, 'saved_at': savedAt.toIso8601String()};

  static WorkspaceSlot? fromJson(dynamic j) {
    if (j is! Map) return null;
    final name = j['name'];
    if (name is! String || name.isEmpty) return null;
    final savedAt =
        DateTime.tryParse((j['saved_at'] as String?) ?? '') ?? DateTime(1970);
    return WorkspaceSlot(name: name, savedAt: savedAt);
  }
}

/// Журнал незавершённой операции. v1 — только `load`.
class WorkspacePending {
  const WorkspacePending(this.op, this.target);
  const WorkspacePending.load(String target) : this(opLoad, target);

  static const opLoad = 'load';

  final String op;
  final String target;

  Map<String, dynamic> toJson() => {'op': op, 'target': target};

  static WorkspacePending? fromJson(dynamic j) {
    if (j is! Map) return null;
    final op = j['op'];
    final target = j['target'];
    if (op is! String || target is! String || target.isEmpty) return null;
    return WorkspacePending(op, target);
  }
}

class WorkspaceManifest {
  const WorkspaceManifest({
    required this.version,
    required this.current,
    required this.slots,
    this.pending,
  });

  factory WorkspaceManifest.initial() => const WorkspaceManifest(
        version: WorkspaceStore.manifestVersion,
        current: WorkspaceStore.defaultName,
        slots: [],
      );

  final int version;
  final String current;
  final List<WorkspaceSlot> slots;
  final WorkspacePending? pending;

  bool hasSlot(String name) => slots.any((s) => s.name == name);

  Map<String, dynamic> toJson() => {
        'version': version,
        'current': current,
        'slots': slots.map((s) => s.toJson()).toList(),
        'pending': pending?.toJson(),
      };

  factory WorkspaceManifest.fromJson(Map<String, dynamic> j) {
    final rawSlots = j['slots'];
    final slots = <WorkspaceSlot>[];
    if (rawSlots is List) {
      for (final s in rawSlots) {
        final slot = WorkspaceSlot.fromJson(s);
        if (slot != null) slots.add(slot);
      }
    }
    final current = j['current'];
    return WorkspaceManifest(
      version: (j['version'] as num?)?.toInt() ?? WorkspaceStore.manifestVersion,
      current: current is String && current.isNotEmpty
          ? current
          : WorkspaceStore.defaultName,
      slots: slots,
      pending: WorkspacePending.fromJson(j['pending']),
    );
  }

  WorkspaceManifest copyWith({
    String? current,
    List<WorkspaceSlot>? slots,
    WorkspacePending? pending,
    bool clearPending = false,
  }) =>
      WorkspaceManifest(
        version: version,
        current: current ?? this.current,
        slots: slots ?? this.slots,
        pending: clearPending ? null : (pending ?? this.pending),
      );

  WorkspaceManifest withSlotSaved(String name, DateTime at) {
    final next = slots.where((s) => s.name != name).toList()
      ..add(WorkspaceSlot(name: name, savedAt: at));
    return copyWith(slots: next);
  }

  WorkspaceManifest withSlotRenamed(String oldName, String newName) =>
      copyWith(
        slots: slots
            .map((s) => s.name == oldName
                ? WorkspaceSlot(name: newName, savedAt: s.savedAt)
                : s)
            .toList(),
      );

  WorkspaceManifest withSlotRemoved(String name) =>
      copyWith(slots: slots.where((s) => s.name != name).toList());
}
