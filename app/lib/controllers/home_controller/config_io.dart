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
  // `_rebuildClashEndpoint` живёт в HomeController (общий с clash-секцией).
  void _rebuildClashEndpoint();

  Future<void> _loadSavedConfig() async {
    try {
      final config = await _vpn.getConfig();
      if (config.isNotEmpty && config != '{}') {
        _emit(_state.copyWith(configRaw: config));
        _rebuildClashEndpoint();
      }
    } catch (e) {
      _addDebug(DebugSource.app, 'Load config: $e');
    }
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
      _emit(_state.copyWith(lastError: 'Failed to save config'));
      _addDebug(DebugSource.app, 'Save config failed');
      return false;
    }
    final raw = displayRaw ?? canonicalJson;
    // Если туннель уже крутит старый конфиг, поставим флаг — UI покажет
    // warning "Restart VPN to apply changes". Флаг sticky до up↔down.
    final needRestart = _state.tunnelUp || _state.configChangedNeedRestart;
    _addDebug(DebugSource.app,
        '[vpn] saveParsedConfig EXIT need_restart_after=$needRestart (tunnelUp=${_state.tunnelUp} || prev=${_state.configChangedNeedRestart})');
    _emit(_state.copyWith(
      configRaw: raw,
      lastError: '',
      configChangedNeedRestart: needRestart,
      // §070: config change → новый pool возможно → sort заново.
      pingBatchGen: _state.pingBatchGen + 1,
    ));
    _rebuildClashEndpoint();
    _addDebug(DebugSource.app, 'Config saved (${canonicalJson.length} bytes)');
    return true;
  }

  Future<bool> saveConfigRaw(String raw) async {
    if (raw.trim().isEmpty) {
      _emit(_state.copyWith(lastError: 'Config is empty'));
      _addDebug(DebugSource.app, 'Save rejected: empty config');
      return false;
    }
    try {
      final canonical = canonicalJsonForSingbox(raw);
      return saveParsedConfig(canonical, displayRaw: raw);
    } on FormatException catch (e) {
      _emit(_state.copyWith(lastError: 'Failed to parse config: ${e.message}'));
      _addDebug(DebugSource.app, 'Config parse error: ${e.message}');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Config import (clipboard / file)
  // ---------------------------------------------------------------------------

  Future<bool> readFromClipboard() async {
    _emit(_state.copyWith(busy: true, lastError: ''));
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (text.trim().isEmpty) {
        _emit(_state.copyWith(lastError: 'Clipboard is empty', busy: false));
        _addDebug(DebugSource.app, 'Clipboard is empty');
        return false;
      }
      final canonical = canonicalJsonForSingbox(text);
      final ok = await saveParsedConfig(canonical, displayRaw: text);
      _emit(_state.copyWith(busy: false));
      return ok;
    } on FormatException catch (e) {
      _emit(_state.copyWith(lastError: 'Failed to parse config: ${e.message}', busy: false));
      _addDebug(DebugSource.app, 'Clipboard parse error: ${e.message}');
      return false;
    } catch (_) {
      _emit(_state.copyWith(lastError: 'Failed to parse config', busy: false));
      _addDebug(DebugSource.app, 'Clipboard parse failed');
      return false;
    }
  }

  Future<bool> readFromFile() async {
    _emit(_state.copyWith(busy: true, lastError: ''));
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
              lastError: 'Failed to read file: ${formatUserError(e)}',
              busy: false));
          _addDebug(DebugSource.app, 'File read error: $e');
          return false;
        }
      } else {
        _emit(_state.copyWith(lastError: 'Failed to read file', busy: false));
        _addDebug(DebugSource.app, 'File pick failed: no bytes and no path');
        return false;
      }

      if (text.trim().isEmpty) {
        _emit(_state.copyWith(lastError: 'File is empty', busy: false));
        _addDebug(DebugSource.app, 'Selected file is empty');
        return false;
      }

      final canonical = canonicalJsonForSingbox(text);
      final ok = await saveParsedConfig(canonical, displayRaw: text);
      _emit(_state.copyWith(busy: false));
      return ok;
    } on FormatException catch (e) {
      _emit(_state.copyWith(lastError: 'Failed to parse config: ${e.message}', busy: false));
      _addDebug(DebugSource.app, 'File parse error: ${e.message}');
      return false;
    } catch (e) {
      _emit(_state.copyWith(
          lastError: 'File error: ${formatUserError(e)}', busy: false));
      _addDebug(DebugSource.app, 'File read error: $e');
      return false;
    }
  }
}
