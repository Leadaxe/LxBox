import 'package:package_info_plus/package_info_plus.dart';

/// Single source of truth для текущей версии приложения. Версия живёт в
/// `pubspec.yaml` `version: X.Y.Z+N` (записывается CI из git tag при release
/// build'е и `scripts/build-local-apk.sh` — из `git describe` при локальной
/// сборке), Android compiler материализует её в `versionName`/`versionCode`,
/// `PackageInfo.fromPlatform()` отдаёт обратно в runtime.
///
/// `init()` зовётся **один раз** в `main()` перед `runApp` — после этого
/// [version] синхронно доступен из любого UI-кода без `FutureBuilder`.
///
/// Замещает прежний `AboutScreen._version` const + `AboutScreen.versionString`
/// pattern, в котором версия дублировалась в pubspec.yaml и hardcoded const
/// (см. §066 / v1.8.1 hotfix incident).
class VersionInfo {
  VersionInfo._();
  static final VersionInfo I = VersionInfo._();

  String _version = '0.0.0';
  String _buildNumber = '0';
  bool _initialized = false;

  /// Должен быть вызван один раз в `main()` перед `runApp`.
  /// Idempotent — повторный вызов no-op.
  Future<void> init() async {
    if (_initialized) return;
    try {
      final info = await PackageInfo.fromPlatform();
      _version = info.version;
      _buildNumber = info.buildNumber;
    } catch (_) {
      // Test environment / unsupported platform — оставляем default.
    }
    _initialized = true;
  }

  /// `X.Y.Z` — Android `versionName`. Для отображения в UI и сравнения
  /// с GitHub release tag (UpdateChecker).
  String get version => _version;

  /// `N` — Android `versionCode` как строка (monotonically increasing
  /// integer). Используется только в About screen для технической метки.
  String get buildNumber => _buildNumber;

  /// `X.Y.Z+N` — для backup `source_app_version` и DEV_REPORT.
  String get versionAndBuild => '$_version+$_buildNumber';
}
