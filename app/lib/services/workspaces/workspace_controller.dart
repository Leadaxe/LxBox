import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_log.dart';
import '../automation/event_emitter.dart';
import '../l10n/locale_controller.dart';
import '../settings_storage.dart';
import '../template_loader.dart';
import 'workspace_store.dart';

/// §417 — оркестрация Workspaces над [WorkspaceStore]: справочник для UI,
/// цикл загрузки и Save as.
///
/// Загрузка (спека §417 п. 2.3): стоп VPN (колбэк `HomeScreen`, он владеет
/// контроллером) → flush стораджа → файлы ([WorkspaceStore.load]) →
/// перечитать состояние ([_reloadStateFromDisk]) → [generation]++ →
/// `LxBoxApp` пересоздаёт `HomeScreen` со всеми его контроллерами → новый
/// `HomeScreen` на bootstrap'е видит «грязно», пересобирает конфиг и, если
/// VPN был поднят ([takePendingAutoConnect]), поднимает его снова.
///
/// Перезапуск процесса не нужен (спека п. 2.6): всё живое состояние либо
/// принадлежит `HomeScreen`, либо восстанавливается статическими вызовами
/// бутстрапа, либо от workspace не зависит.
class WorkspaceController extends ChangeNotifier {
  WorkspaceController._();

  static final WorkspaceController I = WorkspaceController._();

  WorkspaceStore get _store => WorkspaceStore.I;

  WorkspaceManifest _manifest = WorkspaceManifest.initial();

  /// Последний прочитанный справочник. Обновляется [refresh] и после каждой
  /// операции.
  WorkspaceManifest get manifest => _manifest;
  String get current => _manifest.current;
  List<WorkspaceSlot> get slots => _manifest.slots;

  int _generation = 0;

  /// Ключ `HomeScreen` в `LxBoxApp`: инкремент = пересоздать экран и все
  /// контроллеры, которыми он владеет.
  int get generation => _generation;

  bool _busy = false;
  bool get busy => _busy;

  String? _loadingName;

  /// Имя загружаемого слота на время операции (для прогресса в UI).
  String? get loadingName => _loadingName;

  bool _pendingAutoConnect = false;

  /// Одноразовый флаг «VPN был поднят до загрузки — поднять снова». Читает
  /// новый `HomeScreen` после bootstrap-пересборки.
  bool takePendingAutoConnect() {
    final v = _pendingAutoConnect;
    _pendingAutoConnect = false;
    return v;
  }

  Future<void> refresh() async {
    _manifest = await _store.readManifest();
    notifyListeners();
  }

  /// Загрузить слот [name]. [stopVpn] — колбэк экрана: остановить пробы и
  /// туннель, вернуть «был ли туннель поднят».
  Future<WorkspaceLoadOutcome> load(
    String name, {
    required Future<bool> Function() stopVpn,
  }) async {
    if (_busy) return WorkspaceLoadOutcome.busy;
    final target = name.trim();
    _busy = true;
    _loadingName = target;
    notifyListeners();
    try {
      final before = await _store.readManifest();
      if (before.current == target) return WorkspaceLoadOutcome.alreadyCurrent;
      final wasUp = await stopVpn();
      await SettingsStorage.flushToDisk();
      final changed = await _store.load(target);
      if (!changed) return WorkspaceLoadOutcome.alreadyCurrent;
      await _reloadStateFromDisk();
      _manifest = await _store.readManifest();
      _pendingAutoConnect = wasUp;
      _generation++;
      return WorkspaceLoadOutcome.loaded;
    } finally {
      _busy = false;
      _loadingName = null;
      // Один notify: новый generation и снятый busy приходят вместе —
      // пересозданный HomeScreen сразу без индикатора загрузки.
      notifyListeners();
    }
  }

  /// Скопировать сцену в слот [name] и сделать его `current`.
  Future<void> saveAs(String name) async {
    await SettingsStorage.flushToDisk();
    await _store.saveAs(name);
    await refresh();
  }

  Future<void> rename(String oldName, String newName) async {
    await _store.rename(oldName, newName);
    await refresh();
  }

  Future<void> delete(String name) async {
    await _store.delete(name);
    await refresh();
  }

  /// Статические шаги бутстрапа (`main.dart`), которые читают сторадж и
  /// не принадлежат `HomeScreen`. Каждый best-effort — как и в `main()`:
  /// провал одного не должен оставить сцену наполовину перечитанной.
  static Future<void> _reloadStateFromDisk() async {
    SettingsStorage.clearCache();
    await _step('native prefs', SettingsStorage.bootstrapAndSyncNativePrefs);
    await _step('locale', LocaleController.I.reloadFromStorage);
    await _step('directions migration', () async {
      final t = await TemplateLoader.load();
      await SettingsStorage.migrateDirectionsIfNeeded(
        t.groupTemplates,
        varDefaults: {for (final v in t.vars) v.name: v.defaultValue},
      );
    });
    await _step(
        'chain order migration', SettingsStorage.migrateChainOrderIfNeeded);
    await _step('automation gates', AutomationEventEmitter.I.reload);
  }

  static Future<void> _step(String what, Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      AppLog.I.error('workspaces: reload step "$what" failed: $e');
    }
  }
}

enum WorkspaceLoadOutcome { loaded, alreadyCurrent, busy }
