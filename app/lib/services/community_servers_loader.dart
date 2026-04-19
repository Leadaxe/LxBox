import 'dart:convert';

import 'package:http/http.dart' as http;

/// Один список тестовых серверов из комьюнити-манифеста.
class CommunityServerList {
  const CommunityServerList({required this.source});
  final String source;
}

/// Блок атрибуции (автор подборки + ссылка). Опциональный.
class CommunityAttribution {
  const CommunityAttribution({required this.text, required this.link});
  final String text;
  final String link;
}

/// Распарсенный манифест. Может быть пустым (`lists.isEmpty`) — UI в этом
/// случае должен показать disabled-state / тост.
class CommunityManifest {
  const CommunityManifest({this.attribution, required this.lists});
  final CommunityAttribution? attribution;
  final List<CommunityServerList> lists;
}

/// Загружает remote-манифест комьюнити-курируемых подборок серверов для
/// тестирования поведения клиента в различных сетевых условиях. Манифест
/// живёт в репозитории проекта — удаление файла = instant kill-switch.
///
/// Ничего не кэшируется на диск: если манифест удалён, клиент сразу теряет
/// доступ к подборкам, а не обращается к устаревшему кэшу.
class CommunityServersLoader {
  CommunityServersLoader._();

  static const manifestUrl =
      'https://raw.githubusercontent.com/Leadaxe/LxBox/main/public-servers-manifest.json';
  static const _timeout = Duration(seconds: 5);

  static CommunityManifest? _cached;

  /// Грузит манифест. 404 / timeout / parse-error → пробрасывается наверх,
  /// UI решает как сообщить пользователю.
  static Future<CommunityManifest> load({http.Client? client}) async {
    if (_cached != null) return _cached!;
    final c = client ?? http.Client();
    final resp = await c.get(Uri.parse(manifestUrl)).timeout(_timeout);
    if (resp.statusCode != 200) {
      throw Exception('Manifest HTTP ${resp.statusCode}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final attrJson = json['attribution'] as Map<String, dynamic>?;
    final attribution = attrJson != null
        ? CommunityAttribution(
            text: (attrJson['text'] as String? ?? '').trim(),
            link: (attrJson['link'] as String? ?? '').trim(),
          )
        : null;
    final lists = (json['lists'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map((e) => CommunityServerList(source: (e['source'] as String? ?? '').trim()))
        .where((l) => l.source.isNotEmpty)
        .toList(growable: false);
    _cached = CommunityManifest(attribution: attribution, lists: lists);
    return _cached!;
  }
}
