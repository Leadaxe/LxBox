import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'app_log.dart';
import 'settings_storage.dart';

/// Light-weight GitHub Releases polling. Pings `/releases/latest` once a day
/// max, surfaces new versions via [latest] notifier. UI subscribes and shows
/// a SnackBar / About-section. No in-app APK install — opens release page in
/// browser, user downloads APK manually (standard sideload flow).
///
/// Spec: docs/spec/features/036 update check/spec.md
class UpdateChecker {
  UpdateChecker._();
  static final UpdateChecker I = UpdateChecker._();

  static const _repoApi =
      'https://api.github.com/repos/Leadaxe/LxBox/releases/latest';
  /// Fallback — own manifest, committed to repo on every release by CI.
  /// Используется когда api.github.com даёт 403/429/5xx/timeout (типичный
  /// сценарий — shared VPN exit IP исчерпал anonymous 60 req/h cap).
  /// Schema контролируем сами; raw-endpoint cdn-cached, anti-abuse лояльнее.
  static const _repoFallback =
      'https://raw.githubusercontent.com/Leadaxe/LxBox/main/docs/latest.json';
  static const _userAgent = 'LxBox';
  static const _httpTimeout = Duration(seconds: 10);
  static const _minCheckInterval = Duration(hours: 24);

  /// Latest release info, populated after [maybeCheck] / [forceCheck] success.
  /// Null until first successful check; null after dismiss (per spec — banner
  /// hides only for the dismissed tag, not forever).
  final ValueNotifier<UpdateInfo?> latest = ValueNotifier<UpdateInfo?>(null);

  bool _inFlight = false;

  /// Гидратирует [latest] из cached `last_known_version` (если он newer
  /// чем [localVersion] и не dismissed). Вызывается одноразово при старте,
  /// чтобы UI мгновенно показал известный апдейт без сетевого запроса.
  Future<void> hydrate({required String localVersion}) async {
    final tag = await SettingsStorage.getLastKnownVersion();
    if (tag.isEmpty) return;
    final dismissed = await SettingsStorage.getDismissedUpdateVersion();
    if (tag == dismissed) return;
    if (!isNewer(tag, localVersion)) return;
    latest.value = UpdateInfo(
      tag: tag,
      name: tag,
      htmlUrl: 'https://github.com/Leadaxe/LxBox/releases/tag/$tag',
      publishedAt: null,
    );
  }

  /// Проверка с учётом throttle / toggle. Тихо пропускает если:
  /// - `auto_check_updates` выключен
  /// - последний успешный check был < 24h назад
  /// - сеть недоступна / GitHub вернул не-200
  Future<void> maybeCheck({required String localVersion}) async {
    if (_inFlight) return;
    final enabled = await SettingsStorage.getAutoCheckUpdates();
    if (!enabled) return;
    final last = await SettingsStorage.getLastUpdateCheck();
    if (last != null && DateTime.now().toUtc().difference(last) < _minCheckInterval) {
      return;
    }
    await _check(localVersion: localVersion, source: 'auto');
  }

  /// Принудительная проверка — bypass cap и toggle. Вызывается из UI кнопки
  /// "Check now" (About / App Settings). Возвращает результат для caller'а
  /// (показать snackbar "you're up to date" / "checking..." и т.п.).
  Future<UpdateCheckResult> forceCheck({required String localVersion}) async {
    if (_inFlight) return UpdateCheckResult.skipped('check already in flight');
    return _check(localVersion: localVersion, source: 'manual');
  }

  Future<UpdateCheckResult> _check({
    required String localVersion,
    required String source,
  }) async {
    _inFlight = true;
    try {
      // 1. Primary — api.github.com (canonical, full meta).
      var info = await _fetchPrimary(source);
      // 2. Fallback — raw манифест (избегает 403 при shared VPN exit IP).
      info ??= await _fetchFallback(source);
      if (info == null) {
        // Friendly message — оба источника недоступны. Конкретный HTTP/network
        // error логирован в подметодах.
        return UpdateCheckResult.failed(
            "Couldn't reach GitHub — check network or try later");
      }

      // Persist throttle / cache regardless of newer-or-not.
      await SettingsStorage.setLastUpdateCheck(DateTime.now().toUtc());
      if (info.tag.isNotEmpty) {
        await SettingsStorage.setLastKnownVersion(info.tag);
      }

      AppLog.I.info(
          'UpdateChecker[$source]: latest=${info.tag} local=$localVersion');

      if (!isNewer(info.tag, localVersion)) {
        latest.value = null;
        return UpdateCheckResult.upToDate(localVersion);
      }

      final dismissed = await SettingsStorage.getDismissedUpdateVersion();
      latest.value = info;
      return UpdateCheckResult.newer(info, dismissed: dismissed == info.tag);
    } finally {
      _inFlight = false;
    }
  }

  /// Primary source: api.github.com. Возвращает [UpdateInfo] на 200,
  /// `null` на любую ошибку — caller тогда пробует fallback.
  Future<UpdateInfo?> _fetchPrimary(String source) async {
    try {
      final resp = await http
          .get(Uri.parse(_repoApi), headers: {
            'User-Agent': '$_userAgent/${_userAgentSafeVersion()}',
            'Accept': 'application/vnd.github+json',
          })
          .timeout(_httpTimeout);
      if (resp.statusCode != 200) {
        AppLog.I.warning(
            'UpdateChecker[$source]: api.github.com HTTP ${resp.statusCode} — '
            'will try fallback');
        return null;
      }
      final json = jsonDecode(resp.body);
      if (json is! Map<String, dynamic>) {
        AppLog.I.warning('UpdateChecker[$source]: malformed primary JSON');
        return null;
      }
      final tag = (json['tag_name'] as String?) ?? '';
      if (tag.isEmpty) return null;
      final name = (json['name'] as String?) ?? tag;
      final htmlUrl = (json['html_url'] as String?) ??
          'https://github.com/Leadaxe/LxBox/releases/tag/$tag';
      final publishedRaw = json['published_at'] as String?;
      final publishedAt =
          publishedRaw != null ? DateTime.tryParse(publishedRaw) : null;
      return UpdateInfo(
        tag: tag,
        name: name,
        htmlUrl: htmlUrl,
        publishedAt: publishedAt,
      );
    } catch (e) {
      AppLog.I.warning('UpdateChecker[$source]: api.github.com $e');
      return null;
    }
  }

  /// Fallback source: own manifest at raw.githubusercontent.com.
  /// Schema мы контролируем (см. docs/latest.json в repo). Этот endpoint
  /// CDN-кэширован GitHub'ом — anti-abuse намного лояльнее API.
  Future<UpdateInfo?> _fetchFallback(String source) async {
    try {
      final resp = await http
          .get(Uri.parse(_repoFallback), headers: {
            'User-Agent': '$_userAgent/${_userAgentSafeVersion()}',
          })
          .timeout(_httpTimeout);
      if (resp.statusCode != 200) {
        AppLog.I.warning(
            'UpdateChecker[$source]: fallback HTTP ${resp.statusCode}');
        return null;
      }
      final json = jsonDecode(resp.body);
      if (json is! Map<String, dynamic>) {
        AppLog.I.warning('UpdateChecker[$source]: malformed fallback JSON');
        return null;
      }
      final tag = (json['tag'] as String?) ?? '';
      if (tag.isEmpty) return null;
      final name = (json['name'] as String?) ?? tag;
      final htmlUrl = (json['html_url'] as String?) ??
          'https://github.com/Leadaxe/LxBox/releases/tag/$tag';
      final publishedRaw = json['published_at'] as String?;
      final publishedAt =
          publishedRaw != null ? DateTime.tryParse(publishedRaw) : null;
      AppLog.I.info('UpdateChecker[$source]: fallback hit tag=$tag');
      return UpdateInfo(
        tag: tag,
        name: name,
        htmlUrl: htmlUrl,
        publishedAt: publishedAt,
      );
    } catch (e) {
      AppLog.I.warning('UpdateChecker[$source]: fallback $e');
      return null;
    }
  }

  /// Strips weird chars from version for User-Agent header. Не должно быть
  /// CR/LF/whitespace; localVersion теоретически "1.5.0" чистый, но на
  /// всякий случай.
  String _userAgentSafeVersion() {
    return '1.x'; // stable UA, не утекаем точную версию (privacy chrome)
  }

  /// Юзер сказал "Not now" в snackbar для текущей версии. Persist + clear
  /// notifier чтобы snackbar не показался повторно в этой сессии.
  Future<void> dismissCurrent() async {
    final cur = latest.value;
    if (cur == null) return;
    await SettingsStorage.setDismissedUpdateVersion(cur.tag);
    latest.value = null;
  }
}

/// Снаружи иммутабельный snapshot релиза. `publishedAt` null если из cache
/// (без сетевого fetch'а).
@immutable
class UpdateInfo {
  const UpdateInfo({
    required this.tag,
    required this.name,
    required this.htmlUrl,
    this.publishedAt,
  });

  final String tag;
  final String name;
  final String htmlUrl;
  final DateTime? publishedAt;
}

/// Outcome of a check — для UI кнопки "Check now" чтобы показать toast'ом.
@immutable
class UpdateCheckResult {
  const UpdateCheckResult._({
    required this.kind,
    this.info,
    this.localVersion,
    this.message,
    this.dismissed = false,
  });

  factory UpdateCheckResult.newer(UpdateInfo info, {required bool dismissed}) =>
      UpdateCheckResult._(
        kind: UpdateCheckKind.newer,
        info: info,
        dismissed: dismissed,
      );

  factory UpdateCheckResult.upToDate(String local) => UpdateCheckResult._(
        kind: UpdateCheckKind.upToDate,
        localVersion: local,
      );

  factory UpdateCheckResult.failed(String msg) => UpdateCheckResult._(
        kind: UpdateCheckKind.failed,
        message: msg,
      );

  factory UpdateCheckResult.skipped(String msg) => UpdateCheckResult._(
        kind: UpdateCheckKind.skipped,
        message: msg,
      );

  final UpdateCheckKind kind;
  final UpdateInfo? info;
  final String? localVersion;
  final String? message;
  final bool dismissed;
}

enum UpdateCheckKind { newer, upToDate, failed, skipped }

/// Pure semver compare — `vX.Y.Z` vs `X.Y.Z` (или с `v`-префиксом). Возвращает
/// `true` если remote строго newer, `false` иначе или при malformed input.
///
/// Поддерживает X.Y.Z и X.Y. Не поддерживает pre-release suffix'ы
/// (`-rc1`, `-beta`) — `/releases/latest` GitHub'а возвращает только stable,
/// так что в нормальном flow таких не бывает. Если всё-таки приходит — суффикс
/// игнорируется (`v1.4.3-dirty` парсится как `1.4.3`).
bool isNewer(String remote, String local) {
  final r = _parseSemver(remote);
  final l = _parseSemver(local);
  if (r == null || l == null) return false;
  for (var i = 0; i < 3; i++) {
    final ri = i < r.length ? r[i] : 0;
    final li = i < l.length ? l[i] : 0;
    if (ri > li) return true;
    if (ri < li) return false;
  }
  return false;
}

/// Парсит `vX.Y.Z` / `X.Y.Z` / `X.Y` в `[X, Y, Z]`. Возвращает null если
/// невалидно. Игнорирует suffix после первого не-числового / не-точечного
/// символа.
List<int>? _parseSemver(String raw) {
  if (raw.isEmpty) return null;
  var s = raw.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  // отрезаем суффикс типа "-dirty", "+build7", "-rc1"
  final cutAt = s.indexOf(RegExp(r'[^0-9.]'));
  if (cutAt >= 0) s = s.substring(0, cutAt);
  if (s.isEmpty) return null;
  final parts = s.split('.');
  if (parts.length < 2 || parts.length > 3) return null;
  final out = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0) return null;
    out.add(n);
  }
  return out;
}
