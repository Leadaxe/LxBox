import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'app_log.dart';
import 'settings_storage.dart';

/// §362 — способы поддержки проекта. До этого адреса кошельков были вшиты в
/// разметку донат-попапа (About): добавить сеть значило править виджет и
/// выпускать релиз.
///
/// Источник — `docs/donate.json` в репо, раздаётся через
/// raw.githubusercontent.com (паттерн §356 support.json): адреса правятся без
/// релиза. Порядок: сеть → кэш последнего удачного ответа
/// (`donate_cache_json`) → bundled-копия `assets/donate.json` (первый запуск
/// офлайн). Загрузка ленивая, кэш на процесс.
@immutable
class DonateMethod {
  const DonateMethod({
    required this.id,
    required this.kind,
    required this.title,
    required this.url,
    this.address,
    this.note,
  });

  final String id;

  /// `crypto` — адрес + копирование + кнопка оплаты; `link` — кнопка-ссылка.
  final String kind;

  /// Название сети/бренда — НЕ переводится (l10n-exempt by design).
  final String title;

  /// Deeplink кошелька (crypto) либо адрес страницы (link).
  final String url;

  /// Адрес кошелька — только у `crypto`.
  final String? address;

  /// Необязательная поясняющая строка.
  final String? note;

  bool get isCrypto => kind == 'crypto';

  static DonateMethod? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'] as String? ?? '';
    final title = raw['title'] as String? ?? '';
    final url = raw['url'] as String? ?? '';
    if (id.isEmpty || title.isEmpty || url.isEmpty) return null;
    final kind = raw['kind'] as String? ?? 'link';
    final address = raw['address'] as String?;
    // crypto без адреса нечего показывать — отбрасываем (битая запись).
    if (kind == 'crypto' && (address == null || address.isEmpty)) return null;
    return DonateMethod(
      id: id,
      kind: kind,
      title: title,
      url: url,
      address: address,
      note: raw['note'] as String?,
    );
  }
}

class DonateMethods {
  DonateMethods._();
  static final DonateMethods I = DonateMethods._();

  static const _asset = 'assets/donate.json';
  static const _url = String.fromEnvironment(
    'LXBOX_DONATE_URL',
    defaultValue:
        'https://raw.githubusercontent.com/Leadaxe/LxBox/main/docs/donate.json',
  );
  static const _httpTimeout = Duration(seconds: 10);
  static const _cacheKey = 'donate_cache_json';

  /// Test seam (паттерн §101 httpClientForTesting).
  @visibleForTesting
  http.Client? httpClientForTesting;

  List<DonateMethod>? _cache;

  /// Порядок как в файле. Повторный вызов отдаёт кэш процесса.
  Future<List<DonateMethod>> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    // §221 — закрываем самосозданный клиент (owned), иначе течёт на каждый показ.
    final owned = httpClientForTesting == null;
    final client = httpClientForTesting ?? http.Client();
    try {
      final resp = await client
          .get(Uri.parse(_url), headers: {'User-Agent': 'LxBox/1.x'})
          .timeout(_httpTimeout);
      if (resp.statusCode == 200) {
        final parsed = _parse(resp.body);
        if (parsed.isNotEmpty) {
          await SettingsStorage.setVar(_cacheKey, resp.body);
          return _cache = parsed;
        }
      }
    } catch (e) {
      AppLog.I.debug('DonateMethods: fetch failed ($e) — trying cache');
    } finally {
      if (owned) client.close();
    }
    final cachedRaw = await SettingsStorage.getVar(_cacheKey, '');
    if (cachedRaw.isNotEmpty) {
      final parsed = _parse(cachedRaw);
      if (parsed.isNotEmpty) return _cache = parsed;
    }
    // Первый запуск без сети — bundled-копия (адреса на момент сборки: хуже
    // свежих, но лучше пустого попапа).
    try {
      return _cache = _parse(await rootBundle.loadString(_asset));
    } catch (e) {
      AppLog.I.debug('DonateMethods: bundled asset failed ($e)');
      return _cache = const [];
    }
  }

  static List<DonateMethod> _parse(String body) {
    try {
      final raw = jsonDecode(body);
      final list = (raw is Map ? raw['methods'] : null);
      if (list is! List) return const [];
      return [for (final m in list) ?DonateMethod.fromJson(m)];
    } catch (_) {
      return const [];
    }
  }

  @visibleForTesting
  void resetCacheForTesting() => _cache = null;
}
