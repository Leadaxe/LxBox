import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app_log.dart';
import '../update_checker.dart' show isNewer;
import '../version_info.dart';
import 'active_time_tracker.dart';
import 'support_state.dart';

/// §105/§356 — remote-managed лента сообщений «поддержи автора».
///
/// Контент — `docs/support.json` в репо, раздаётся через
/// raw.githubusercontent.com (паттерн §036 latest.json): автор меняет
/// тексты/ссылки/пороги/очередь без релиза. Удачный fetch кэшируется
/// ([SupportState] `cache_json`) — показ работает и офлайн. Ни сети, ни
/// кэша → не показываем (сообщение без актуальных ссылок бессмысленно).
///
/// v2 (§356): вместо одной кампании — очередь сообщений с локалями
/// (`i18n`, en — обязательный фолбэк) и версионным повторным показом
/// (`since_version`). Подробности выбора — [SupportMessageService.pick].
/// §357 — кнопка сообщения. [markRead] действует только для lxbox-кнопок
/// (`lxbox://route:…`/`add:…`): тап закрывает сообщение и по умолчанию
/// помечает его прочитанным; `"mark_read": false` — не помечать (придёт
/// снова). Для обычных https-кнопок флаг не используется (они не закрывают
/// сообщение).
@immutable
class SupportLinkSpec {
  const SupportLinkSpec(this.label, this.url, {this.markRead = true});

  final String label;
  final String url;
  final bool markRead;
}

@immutable
class SupportContent {
  const SupportContent({
    required this.title,
    required this.message,
    required this.links,
  });

  final String title;
  final String message;

  /// Кнопки в порядке списка. У каждой локали свои (en может вести на
  /// USER_GUIDE.md, ru — на USER_GUIDE_RU.md).
  final List<SupportLinkSpec> links;

  static SupportContent? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final title = raw['title'] as String? ?? '';
    final message = raw['message'] as String? ?? '';
    if (title.isEmpty || message.isEmpty) return null;
    final links = <SupportLinkSpec>[];
    for (final l in raw['links'] as List? ?? const []) {
      if (l is! Map) continue;
      final label = l['label'] as String? ?? '';
      final url = l['url'] as String? ?? '';
      if (label.isEmpty || url.isEmpty) continue;
      links.add(SupportLinkSpec(label, url, markRead: l['mark_read'] != false));
    }
    return SupportContent(title: title, message: message, links: links);
  }
}

@immutable
class SupportMessage {
  const SupportMessage({
    required this.id,
    required this.sinceVersion,
    required this.skip,
    required this.minActiveHours,
    required this.minSessionMinutes,
    required this.i18n,
    this.readDelaySeconds = 10,
  });

  /// Постоянный ключ сообщения — по нему хранится «прочитано».
  final String id;

  /// С какой версии приложения сообщение существует. Двойная роль:
  /// (а) таргетинг — версии старше не видят; (б) повторный показ — бамп выше
  /// версии, записанной в `read` при «Прочитал», делает сообщение
  /// непрочитанным для обновившихся (и только для них).
  final String sinceVersion;

  /// Авторский вывод из ротации: true = никому не показывать.
  final bool skip;

  /// Порог наработки туннеля ОТ BASELINE (не от нуля): сколько часов VPN
  /// должен наработать после последнего «Прочитал»/обновления приложения.
  final int minActiveHours;

  /// Минимум для ТЕКУЩЕЙ сессии туннеля: показываем только когда юзер
  /// реально пользуется VPN прямо сейчас (не дёргаем в момент подключения).
  final int minSessionMinutes;

  /// §357 — кнопка «Got it» первые N секунд неактивна и тикает обратный
  /// отсчёт: защита от смахивания не глядя. «Later» и ссылки активны сразу.
  final int readDelaySeconds;

  /// Локаль → контент. `en` гарантирован парсером ([fromJson] отбрасывает
  /// сообщение без валидного en-блока).
  final Map<String, SupportContent> i18n;

  /// Контент для локали [tag] с фолбэком на en.
  SupportContent contentFor(String tag) => i18n[tag] ?? i18n['en']!;

  static SupportMessage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'] as String? ?? '';
    if (id.isEmpty) return null;
    final i18n = <String, SupportContent>{};
    final i18nRaw = raw['i18n'];
    if (i18nRaw is Map) {
      for (final e in i18nRaw.entries) {
        final c = SupportContent.fromJson(e.value);
        if (c != null) i18n[e.key.toString()] = c;
      }
    }
    if (!i18n.containsKey('en')) return null; // en обязателен (фолбэк)
    return SupportMessage(
      id: id,
      sinceVersion: raw['since_version'] as String? ?? '0.0.0',
      skip: raw['skip'] == true,
      minActiveHours: (raw['min_active_hours'] as num?)?.toInt() ?? 3,
      minSessionMinutes: (raw['min_session_minutes'] as num?)?.toInt() ?? 5,
      readDelaySeconds: (raw['read_delay_seconds'] as num?)?.toInt() ?? 10,
      i18n: i18n,
    );
  }
}

@immutable
class SupportFeed {
  const SupportFeed({required this.snoozeActiveHours, required this.messages});

  /// «Later» — общий для всей ленты: +N часов наработки тишины.
  final int snoozeActiveHours;

  /// Порядок массива = очередь показа (строгая, см. [SupportMessageService.pick]).
  final List<SupportMessage> messages;

  static SupportFeed? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final list = raw['messages'];
    if (list is! List) return null;
    final messages = <SupportMessage>[];
    for (final m in list) {
      final parsed = SupportMessage.fromJson(m);
      if (parsed != null) messages.add(parsed);
    }
    return SupportFeed(
      snoozeActiveHours: (raw['snooze_active_hours'] as num?)?.toInt() ?? 10,
      messages: messages,
    );
  }
}

/// §357 — одноразовый запрос показа сообщения от Debug API
/// (`POST /support/preview`): сообщение вне гейтов ленты; [dryRun] —
/// кнопки работают, но `markRead`/`snooze` не пишутся в state.
@immutable
class SupportPreviewRequest {
  const SupportPreviewRequest({
    required this.feed,
    required this.message,
    required this.dryRun,
  });

  final SupportFeed feed;
  final SupportMessage message;
  final bool dryRun;
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

  /// Test seam — версия приложения (VersionInfo в тестах '0.0.0').
  @visibleForTesting
  String? appVersionForTesting;

  String get _appVersion => appVersionForTesting ?? VersionInfo.I.version;

  /// Сеть (best-effort, кэшируем) → кэш → null.
  Future<SupportFeed?> fetchOrCached() async {
    // §221 — закрываем самосозданный http.Client (owned): иначе течёт на каждый
    // fetch с главного экрана (тот же паттерн, что sources/community в §219).
    final owned = httpClientForTesting == null;
    final client = httpClientForTesting ?? http.Client();
    try {
      final resp = await client
          .get(Uri.parse(_url), headers: {'User-Agent': 'LxBox/1.x'})
          .timeout(_httpTimeout);
      if (resp.statusCode == 200) {
        final f = SupportFeed.fromJson(jsonDecode(resp.body));
        if (f != null) {
          await SupportState.I.set('cache_json', resp.body);
          return f;
        }
      }
    } catch (e) {
      AppLog.I.debug('SupportMessage: fetch failed ($e) — trying cache');
    } finally {
      if (owned) client.close();
    }
    final cached = await SupportState.I.getString('cache_json');
    if (cached.isEmpty) return null;
    try {
      return SupportFeed.fromJson(jsonDecode(cached));
    } catch (_) {
      return null;
    }
  }

  /// §356 — точка отсчёта `min_active_hours`. Сдвигается при смене версии
  /// приложения (вкл. первый запуск) и при «Прочитал» ([markRead]). Гарантия
  /// анти-спама: после обновления любое сообщение ждёт свои часы наработки
  /// заново — очередь не вываливается разом даже при огромном total.
  Future<void> _syncBaseline() async {
    final ver = _appVersion;
    if (await SupportState.I.getString('baseline_version') == ver) return;
    await SupportState.I.setAll({
      'baseline_seconds': await ActiveTimeTracker.I.totalSeconds(),
      'baseline_version': ver,
    });
  }

  /// Pure-выбор сообщения — для тестов без IO.
  ///
  /// Первое ВИДИМОЕ (не skip, версия приложения доросла до `since_version`)
  /// непрочитанное сообщение ленты. Непрочитанное: нет в [read] ИЛИ
  /// `since_version` подняли выше записанной там версии. Очередь строгая:
  /// гейты этого одного кандидата не пройдены → null (вперёд по ленте не
  /// перескакиваем — порядок показа гарантирован).
  static SupportMessage? pick({
    required SupportFeed feed,
    required String appVersion,
    required Map<String, String> read,
    required int totalActiveSeconds,
    required int baselineSeconds,
    required int currentSessionSeconds,
    required int snoozeAfterSeconds,
  }) {
    if (totalActiveSeconds < snoozeAfterSeconds) return null; // «Later»
    for (final m in feed.messages) {
      if (m.skip) continue;
      if (isNewer(m.sinceVersion, appVersion)) continue; // версия не доросла
      final readAt = read[m.id];
      if (readAt != null && !isNewer(m.sinceVersion, readAt)) continue; // прочитано
      if (currentSessionSeconds < m.minSessionMinutes * 60) return null;
      if (totalActiveSeconds - baselineSeconds < m.minActiveHours * 3600) {
        return null;
      }
      return m;
    }
    return null;
  }

  /// Выбор с учётом persist-состояния. [currentSessionSeconds] — длительность
  /// ТЕКУЩЕЙ сессии туннеля (0, если VPN не подключён).
  Future<SupportMessage?> nextToShow(
    SupportFeed feed, {
    required int currentSessionSeconds,
  }) async {
    await _syncBaseline();
    return pick(
      feed: feed,
      appVersion: _appVersion,
      read: await SupportState.I.getStringMap('read'),
      totalActiveSeconds: await ActiveTimeTracker.I.totalSeconds(),
      baselineSeconds: await SupportState.I.getInt('baseline_seconds'),
      currentSessionSeconds: currentSessionSeconds,
      snoozeAfterSeconds: await SupportState.I.getInt('snooze_after_seconds'),
    );
  }

  /// «Got it» — версия приложения в `read` + сдвиг baseline: следующее
  /// сообщение очереди ждёт свои `min_active_hours` наработки от этого
  /// момента.
  Future<void> markRead(SupportMessage m) async {
    final read = await SupportState.I.getStringMap('read');
    read[m.id] = _appVersion;
    await SupportState.I.setAll({
      'read': read,
      'baseline_seconds': await ActiveTimeTracker.I.totalSeconds(),
    });
  }

  /// «Later» — вся лента молчит ещё `snooze_active_hours` наработки (не
  /// календарных). Baseline не трогаем — иначе отложенное отодвигалось бы
  /// дважды.
  Future<void> snooze(SupportFeed feed) async {
    final total = await ActiveTimeTracker.I.totalSeconds();
    await SupportState.I
        .set('snooze_after_seconds', total + feed.snoozeActiveHours * 3600);
  }
}
