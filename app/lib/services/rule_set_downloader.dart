import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Downloads and caches remote .srs rule set files locally.
/// On success returns the absolute path to the cached file.
/// On failure returns null (caller should fall back to remote).
class RuleSetDownloader {
  RuleSetDownloader._();

  static const _timeout = Duration(seconds: 30);
  static const _dirName = 'rule_sets';

  static Directory? _cacheDir;

  static Future<Directory> _getCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/$_dirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir;
    return dir;
  }

  /// Checks if a rule set is already cached.
  static Future<bool> isCached(String tag) async {
    try {
      final dir = await _getCacheDir();
      final file = File('${dir.path}/$tag.srs');
      return await file.exists();
    } catch (_) {
      return false;
    }
  }

  /// Returns the local path for a cached rule set, downloading if needed.
  /// [tag] is used as the filename (e.g. "ads-all" → "ads-all.srs").
  /// [maxAge] — skip download if cached file is younger than this.
  static Future<String?> ensureCached(
    String tag,
    String url, {
    Duration maxAge = const Duration(hours: 12),
  }) async {
    try {
      final dir = await _getCacheDir();
      final file = File('${dir.path}/$tag.srs');

      if (await file.exists()) {
        final stat = await file.stat();
        final age = DateTime.now().difference(stat.modified);
        if (age < maxAge) {
          return file.path;
        }
      }

      final response = await http
          .get(Uri.parse(url), headers: {'User-Agent': 'LxBox'})
          .timeout(_timeout);

      if (response.statusCode != 200) return null;
      if (response.bodyBytes.isEmpty) return null;

      await file.writeAsBytes(response.bodyBytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Downloads all remote rule sets from the provided entries.
  /// Returns a map of tag → local absolute path for successfully cached files.
  static Future<Map<String, String>> cacheAll(
    List<Map<String, dynamic>> ruleSetEntries, {
    Duration maxAge = const Duration(hours: 12),
    void Function(String tag)? onProgress,
  }) async {
    final results = <String, String>{};

    for (final entry in ruleSetEntries) {
      final tag = entry['tag'] as String?;
      final url = entry['url'] as String?;
      final type = entry['type'] as String?;

      if (tag == null || url == null || type != 'remote') continue;

      onProgress?.call(tag);
      final path = await ensureCached(tag, url, maxAge: maxAge);
      if (path != null) {
        results[tag] = path;
      }
    }

    return results;
  }
}
