part of '../home_controller.dart';

/// Config persistence + import (clipboard / file). Вынесено `part`'ом из
/// `home_controller.dart` — та же библиотека и тот же `HomeController`,
/// поведение (_emit timing, parse/error handling, clash endpoint rebuild,
/// §070 pingBatchGen bump) идентично. Общие с контроллером поля/хелперы
/// объявлены абстрактно; реализацию даёт `HomeController`.
mixin _ConfigIoMixin on ChangeNotifier {
  // --- surface, предоставляемая HomeController / другими частями ---
  HomeState get _state;
  BoxVpnClient get _vpn;
  void _emit(HomeState next);
  void _addDebug(DebugSource source, String message);

  Future<void> _loadSavedConfig() async {
    try {
      final config = await _vpn.getConfig();
      if (config.isNotEmpty && config != '{}') {
        // §116 — успешная загрузка снимает аномалию (config_load_error).
        _emit(_state.copyWith(configRaw: config, configLoadError: false));
      }
    } catch (e) {
      _addDebug(DebugSource.app, 'Load config: $e');
    }
    // §100 — restore last node sort (mode + manual order) из storage.
    try {
      final saved = await SettingsStorage.getNodeSort();
      if (saved.mode.isNotEmpty) {
        final mode = NodeSortMode.values.firstWhere(
          (m) => m.name == saved.mode,
          orElse: () => _state.sortMode,
        );
        _emit(_state.copyWith(sortMode: mode, manualOrder: saved.order));
      }
    } catch (e) {
      _addDebug(DebugSource.app, 'Load sort: $e');
    }
  }

  /// §116 — пометить аномалию загрузки конфига (`configRaw` пустой при живом
  /// туннеле). Постоянный error-баннер до успешной загрузки; bootstrap НЕ
  /// пересобирает в этом случае. Идемпотентно.
  void markConfigLoadError() {
    if (_state.configLoadError) return;
    _emit(_state.copyWith(configLoadError: true));
  }

  Future<bool> saveParsedConfig(String canonicalJson, {String? displayRaw}) async {
    if (kDebugMode) {
      // StackTrace.current — аллокация + toString + split на каждый save,
      // на hot-path'е затратно (save дергается из routing apply, settings,
      // auto-updater, rebuild). В release выключено, оставляем для dev-диагностики.
      final callerFrames = StackTrace.current.toString().split('\n').take(4).join(' | ');
      _addDebug(DebugSource.app,
          '[vpn] saveParsedConfig ENTER tunnelUp=${_state.tunnelUp} need_restart_before=${_state.configChangedNeedRestart} caller=$callerFrames');
    } else {
      _addDebug(DebugSource.app,
          '[vpn] saveParsedConfig ENTER tunnelUp=${_state.tunnelUp} need_restart_before=${_state.configChangedNeedRestart}');
    }
    final ok = await _vpn.saveConfig(canonicalJson);
    if (!ok) {
      _emit(_state.copyWith(lastError: const ErrMsg(ErrKey.failedToSaveConfig)));
      _addDebug(DebugSource.app, 'Save config failed');
      return false;
    }
    final raw = displayRaw ?? canonicalJson;
    // §116 — дифф: меняется ли saved config относительно текущего (работающего)
    // `configRaw`. Если конфиг байт-в-байт тот же (canonical-to-canonical), эта
    // запись running config НЕ устаревает → restart не нужен. Убирает ложный
    // «Config changed» на bootstrap-пересборке при живом туннеле (репорт MIUI).
    // Сравнение sticky: prev=true (более раннее реальное изменение, ещё не
    // применённое рестартом) сохраняем.
    bool changed;
    try {
      changed = _state.configRaw.isEmpty ||
          canonicalJsonForSingbox(canonicalJson) !=
              canonicalJsonForSingbox(_state.configRaw);
    } catch (_) {
      changed = true; // не смогли сравнить → safe: показать баннер, не спрятать
    }
    // Если туннель уже крутит старый конфиг И конфиг реально изменился — флаг.
    // Флаг sticky до up↔down. saveConfig выше уже переписал файл (mtime=now),
    // так что отдельный touch не нужен — config новее settings, §113-bootstrap
    // не перепроверит.
    //
    // §323 — sticky отменяется при `changed == false`: гасим флаг, а не просто
    // не поднимаем. Если saved config совпал байт-в-байт с running, running НЕ
    // устарел — независимо от истории флага. Раньше prev=true переживал такую
    // пересборку, и плашка висела над конфигом, идентичным работающему (типовой
    // случай: подписка раз в час отдаёт тот же список нод → жалобы 4PDA).
    // `configRaw.isEmpty` в `changed` выше даёт true, так что пустое состояние
    // сюда не попадает и флаг не гасится вслепую.
    final needRestart =
        changed && (_state.tunnelUp || _state.configChangedNeedRestart);
    _addDebug(DebugSource.app,
        '[vpn] saveParsedConfig EXIT changed=$changed need_restart_after=$needRestart (tunnelUp=${_state.tunnelUp} prev=${_state.configChangedNeedRestart})');
    _emit(_state.copyWith(
      configRaw: raw,
      lastError: null,
      configChangedNeedRestart: needRestart,
      // §116 — configRaw стал непустым → аномалия загрузки снята.
      configLoadError: false,
      // §070: config change → новый pool возможно → sort заново. Только при
      // реальном изменении (§116) — идентичная пересборка sort не трогает.
      pingBatchGen:
          changed ? _state.pingBatchGen + 1 : _state.pingBatchGen,
    ));
    _addDebug(DebugSource.app, 'Config saved (${canonicalJson.length} bytes)');
    return true;
  }

  Future<bool> saveConfigRaw(String raw) async {
    if (raw.trim().isEmpty) {
      _emit(_state.copyWith(lastError: const ErrMsg(ErrKey.configIsEmpty)));
      _addDebug(DebugSource.app, 'Save rejected: empty config');
      return false;
    }
    try {
      final canonical = canonicalJsonForSingbox(raw);
      return saveParsedConfig(canonical, displayRaw: raw);
    } on FormatException catch (e) {
      _emit(_state.copyWith(lastError: PrefixedMsg(ErrPrefix.parseConfigFailed, RawMsg(e.message))));
      _addDebug(DebugSource.app, 'Config parse error: ${e.message}');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Config import (clipboard / file)
  // ---------------------------------------------------------------------------

  Future<bool> readFromClipboard() async {
    _emit(_state.copyWith(busy: true, lastError: null));
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (text.trim().isEmpty) {
        _emit(_state.copyWith(lastError: const ErrMsg(ErrKey.clipboardIsEmpty), busy: false));
        _addDebug(DebugSource.app, 'Clipboard is empty');
        return false;
      }
      final canonical = canonicalJsonForSingbox(text);
      final ok = await saveParsedConfig(canonical, displayRaw: text);
      _emit(_state.copyWith(busy: false));
      return ok;
    } on FormatException catch (e) {
      _emit(_state.copyWith(lastError: PrefixedMsg(ErrPrefix.parseConfigFailed, RawMsg(e.message)), busy: false));
      _addDebug(DebugSource.app, 'Clipboard parse error: ${e.message}');
      return false;
    } catch (_) {
      _emit(_state.copyWith(lastError: const ErrMsg(ErrKey.failedToParseConfig), busy: false));
      _addDebug(DebugSource.app, 'Clipboard parse failed');
      return false;
    }
  }

  Future<bool> readFromFile() async {
    _emit(_state.copyWith(busy: true, lastError: null));
    try {
      final result = await FilePicker.pickFiles(withData: true, allowMultiple: false);
      if (result == null || result.files.isEmpty) {
        _emit(_state.copyWith(busy: false));
        return false;
      }
      final file = result.files.single;
      final bytes = file.bytes;
      final path = file.path;
      late final String text;

      if (bytes != null && bytes.isNotEmpty) {
        text = utf8.decode(bytes, allowMalformed: true);
      } else if (path != null) {
        try {
          text = await File(path).readAsString();
        } on FileSystemException catch (e) {
          _emit(_state.copyWith(
              lastError: PrefixedMsg(ErrPrefix.readFileFailed, formatUserError(e)),
              busy: false));
          _addDebug(DebugSource.app, 'File read error: $e');
          return false;
        }
      } else {
        _emit(_state.copyWith(lastError: const ErrMsg(ErrKey.failedToReadFile), busy: false));
        _addDebug(DebugSource.app, 'File pick failed: no bytes and no path');
        return false;
      }

      if (text.trim().isEmpty) {
        _emit(_state.copyWith(lastError: const ErrMsg(ErrKey.fileIsEmpty), busy: false));
        _addDebug(DebugSource.app, 'Selected file is empty');
        return false;
      }

      final canonical = canonicalJsonForSingbox(text);
      final ok = await saveParsedConfig(canonical, displayRaw: text);
      _emit(_state.copyWith(busy: false));
      return ok;
    } on FormatException catch (e) {
      _emit(_state.copyWith(lastError: PrefixedMsg(ErrPrefix.parseConfigFailed, RawMsg(e.message)), busy: false));
      _addDebug(DebugSource.app, 'File parse error: ${e.message}');
      return false;
    } catch (e) {
      _emit(_state.copyWith(
          lastError: PrefixedMsg(ErrPrefix.fileError, formatUserError(e)), busy: false));
      _addDebug(DebugSource.app, 'File read error: $e');
      return false;
    }
  }
}
