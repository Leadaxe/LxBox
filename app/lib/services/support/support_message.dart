import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app_log.dart';
import 'active_time_tracker.dart';
import 'support_state.dart';

/// §105 — remote-managed сообщение «поддержи автора».
///
/// Контент — `docs/support.json` в репо, раздаётся через
/// raw.githubusercontent.com (паттерн §036 latest.json): автор меняет
/// текст/ссылки/пороги без релиза. Удачный fetch кэшируется ([SupportState]
/// `cache_json`) — показ работает и офлайн. Ни сети, ни кэша → не
/// показываем (сообщение без актуальных ссылок бессмысленно).
@immutable
class SupportMessage {
  const SupportMessage({
    required this.id,
    required this.minActiveHours,
    required this.snoozeActiveHours,
    required this.title,
    required this.message,
    required this.links,
  });

  final String id;
  final int minActiveHours;
  final int snoozeActiveHours;
  final String title;
  final String message;

  /// `(label, url)` — кнопки в порядке списка.
  final List<(String, String)> links;

  static SupportMessage? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final id = raw['id'] as String? ?? '';
    if (id.isEmpty) return null;
    final links = <(String, String)>[];
    for (final l in raw['links'] as List? ?? const []) {
      if (l is! Map) continue;
      final label = l['label'] as String? ?? '';
      final url = l['url'] as String? ?? '';
      if (label.isEmpty || url.isEmpty) continue;
      links.add((label, url));
    }
    return SupportMessage(
      id: id,
      minActiveHours: (raw['min_active_hours'] as num?)?.toInt() ?? 3,
      snoozeActiveHours: (raw['snooze_active_hours'] as num?)?.toInt() ?? 10,
      title: raw['title'] as String? ?? '',
      message: raw['message'] as String? ?? '',
      links: links,
    );
  }
}

class SupportMessageService {
  SupportMessageService._();
  static final SupportMessageService I = SupportMessageService._();

  /// Прод-канал — main. Для проверки кампании до публикации можно собрать
  /// тестовый APK с override'ом:
  /// `--dart-define=LXBOX_SUPPORT_URL=https://raw.githubusercontent.com/Leadaxe/LxBox/develop/docs/support.test.json`
  static const _url = String.fromEnvironment(
    'LXBOX_SUPPORT_URL',
    defaultValue:
        'https://raw.githubusercontent.com/Leadaxe/LxBox/main/docs/support.json',
  );
  static const _httpTimeout = Duration(seconds: 10);

  /// Test seam (паттерн §101 httpClientForTesting).
  @visibleForTesting
  http.Client? httpClientForTesting;

  /// Сеть (best-effort, кэшируем) → кэш → null.
  Future<SupportMessage?> fetchOrCached() async {
    try {
      final client = httpClientForTesting ?? http.Client();
      final resp = await client
          .get(Uri.parse(_url), headers: {'User-Agent': 'LxBox/1.x'})
          .timeout(_httpTimeout);
      if (resp.statusCode == 200) {
        final m = SupportMessage.fromJson(jsonDecode(resp.body));
        if (m != null) {
          await SupportState.I.set('cache_json', resp.body);
          return m;
        }
      }
    } catch (e) {
      AppLog.I.debug('SupportMessage: fetch failed ($e) — trying cache');
    }
    final cached = await SupportState.I.getString('cache_json');
    if (cached.isEmpty) return null;
    try {
      return SupportMessage.fromJson(jsonDecode(cached));
    } catch (_) {
      return null;
    }
  }

  /// Pure-решение о показе — для тестов без IO.
  static bool decide({
    required SupportMessage m,
    required int totalActiveSeconds,
    required String dismissedId,
    required int snoozeAfterSeconds,
  }) {
    if (m.id == dismissedId) return false;
    if (totalActiveSeconds < m.minActiveHours * 3600) return false;
    if (totalActiveSeconds < snoozeAfterSeconds) return false;
    return true;
  }

  Future<bool> shouldShow(SupportMessage m) async => decide(
        m: m,
        totalActiveSeconds: await ActiveTimeTracker.I.totalSeconds(),
        dismissedId: await SupportState.I.getString('dismissed_id'),
        snoozeAfterSeconds: await SupportState.I.getInt('snooze_after_seconds'),
      );

  /// «Позже» — повтор через +snooze часов АКТИВНОГО времени (не календарных).
  Future<void> snooze(SupportMessage m) async {
    final total = await ActiveTimeTracker.I.totalSeconds();
    await SupportState.I
        .set('snooze_after_seconds', total + m.snoozeActiveHours * 3600);
  }

  /// «Не показывать» — навсегда для этой кампании (id). Новая кампания
  /// (другой id в support.json) покажется заново.
  Future<void> dismissForever(SupportMessage m) async {
    await SupportState.I.set('dismissed_id', m.id);
  }
}
