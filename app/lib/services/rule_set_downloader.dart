import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Исход попытки скачивания (§366). До §366 метод возвращал `String?`, где
/// `null` = ошибка; условный GET добавил третий исход — `304 Not Modified`,
/// который **успех**, но файл не переписан. Смешивать его с ошибкой нельзя:
/// на 304 надо двигать `lastUpdated` (кэш подтверждённо свежий) и НЕ поднимать
/// configDirty (содержимое не изменилось).
enum DownloadOutcome {
  /// Файл скачан заново (200 + тело).
  downloaded,

  /// Сервер ответил 304 — локальная копия актуальна, файл не тронут.
  notModified,

  /// Не удалось (сеть, таймаут, 4xx/5xx). Старый файл, если был, сохранён.
  failed,
}

/// Результат [RuleSetDownloader.fetch]: исход + путь к файлу (null только при
/// [DownloadOutcome.failed] без ранее скачанного файла).
class DownloadResult {
  const DownloadResult(this.outcome, this.path);
  final DownloadOutcome outcome;
  final String? path;

  bool get ok => outcome != DownloadOutcome.failed;

  /// Содержимое кэша изменилось → конфиг надо пересобрать.
  bool get changed => outcome == DownloadOutcome.downloaded;
}

/// Метаданные кэшированного rule-set'а (§366). Живут sidecar-файлом
/// `<id>.meta.json` рядом с `.srs`, а НЕ полями модели: preset-рулсеты
/// (`preset__<presetId>__<tag>`) своей записи в `custom_rules` не имеют,
/// класть их метаданные некуда, а кэш и так вне бэкапа.
///
/// Почему не хватает mtime файла: при `304` файл не переписывается, mtime
/// остаётся старым → каждая следующая проверка снова считала бы кэш
/// протухшим. Нужен явный «когда последний раз подтвердили актуальность».
class RuleSetMeta {
  const RuleSetMeta({
    this.lastUpdated,
    this.lastAttempt,
    this.etag,
    this.lastError,
  });

  /// Последнее подтверждение актуальности: успешное скачивание ИЛИ 304.
  final DateTime? lastUpdated;

  /// Последняя попытка любого исхода — включая неудачную.
  final DateTime? lastAttempt;

  /// ETag из ответа сервера, для условного GET (`If-None-Match`).
  final String? etag;

  /// Короткое описание последней ошибки (код или тип). Null — последняя
  /// попытка удалась.
  final String? lastError;

  /// Была ли последняя попытка неудачной.
  bool get failing => lastError != null;

  Map<String, dynamic> toJson() => {
        if (lastUpdated != null)
          'lastUpdated': lastUpdated!.toUtc().toIso8601String(),
        if (lastAttempt != null)
          'lastAttempt': lastAttempt!.toUtc().toIso8601String(),
        if (etag != null) 'etag': etag,
        if (lastError != null) 'lastError': lastError,
      };

  factory RuleSetMeta.fromJson(Map<String, dynamic> j) => RuleSetMeta(
        lastUpdated: _parseDate(j['lastUpdated']),
        lastAttempt: _parseDate(j['lastAttempt']),
        etag: j['etag'] as String?,
        lastError: j['lastError'] as String?,
      );

  static DateTime? _parseDate(dynamic v) =>
      v is String ? DateTime.tryParse(v)?.toLocal() : null;
}

/// Кэширует удалённые `.srs` rule-set'ы локально. Файл = `$docs/rule_sets/<id>.srs`,
/// где `id` — `CustomRule.id` (стабильный UUID). Переименование правила или
/// правка URL'а не ломает кэш (удаление делает caller при URL-change).
///
/// Контракт: sing-box в конфиге получает `{type: "local", path: <abs>}` и
/// сам ничего не скачивает. В сеть за рулсетами ходит **только приложение** —
/// либо явно (☁/⟳ юзера), либо авто-обновлением по TTL (§366,
/// `RuleSetAutoUpdater`), но никогда ядро и никогда в фоне.
class RuleSetDownloader {
  RuleSetDownloader._();

  static const _timeout = Duration(seconds: 30);
  static const _dirName = 'rule_sets';

  static Directory? _cacheDir;

  /// Сбрасывает закэшированную директорию. Только для тестов: каждый
  /// `setUp` ставит свой `PathProviderPlatform.instance` + временную папку;
  /// без сброса `_dir()` продолжал бы писать в директорию первого теста
  /// (уже снесённую его `tearDown`) — источник flaky при параллельном suite.
  static void resetCacheForTesting() => _cacheDir = null;

  static Future<Directory> _dir() async {
    // Закэшированный путь мог исчезнуть (tearDown теста, очистка стораджа) —
    // не доверяем закэшу слепо, гарантируем существование на каждом вызове.
    final cached = _cacheDir;
    if (cached != null) {
      if (!await cached.exists()) await cached.create(recursive: true);
      return cached;
    }
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    _cacheDir = dir;
    return dir;
  }

  static Future<File> _file(String id) async =>
      File('${(await _dir()).path}/$id.srs');

  /// Sidecar с метаданными (§366). Расширение НЕ `.srs` — `pruneOrphans`
  /// различает их по суффиксу.
  static Future<File> _metaFile(String id) async =>
      File('${(await _dir()).path}/$id$_metaSuffix');

  static const _metaSuffix = '.meta.json';

  /// Метаданные обновления. Пустой [RuleSetMeta] если файла нет или он битый —
  /// вызывающая сторона трактует «нет lastUpdated» как «пора обновить».
  static Future<RuleSetMeta> readMeta(String id) async {
    try {
      final f = await _metaFile(id);
      if (!await f.exists()) return const RuleSetMeta();
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return const RuleSetMeta();
      return RuleSetMeta.fromJson(raw);
    } catch (_) {
      return const RuleSetMeta();
    }
  }

  /// No-throw: провал записи метаданных не должен ронять само скачивание —
  /// файл уже на диске и работает, метаданные лишь информационные.
  static Future<void> _writeMeta(String id, RuleSetMeta meta) async {
    try {
      await (await _metaFile(id)).writeAsString(jsonEncode(meta.toJson()),
          flush: true);
    } catch (_) {}
  }

  /// Есть ли кэш для правила.
  static Future<bool> isCached(String id) async {
    try {
      return await (await _file(id)).exists();
    } catch (_) {
      return false;
    }
  }

  /// Абсолютный путь к cached-файлу или null если нет.
  static Future<String?> cachedPath(String id) async {
    final f = await _file(id);
    return await f.exists() ? f.path : null;
  }

  /// Время последней модификации (mtime). Null если нет.
  static Future<DateTime?> lastUpdated(String id) async {
    final f = await _file(id);
    if (!await f.exists()) return null;
    return (await f.stat()).modified;
  }

  /// Скачать и сохранить. Атомарно: пишем во временный файл и `rename` на
  /// финальный, чтобы при сетевом обрыве не остаться с частично записанным
  /// кэшем.
  ///
  /// 3 попытки с exp backoff (1s, 3s) — total worst case ~34s.
  /// Retry только на transient (timeout/network/5xx); 4xx = permanent skip.
  ///
  /// `client` инжектится только в тестах (night T3-1); в проде `http.get`.
  /// `backoffs` тоже только для тестов — нулевые задержки убирают реальный
  /// сон 1s+3s, который в параллельном suite (§T3) делал тест flaky.
  /// Возвращает абсолютный путь при успехе, null при финальной ошибке.
  static const _prodBackoffs = [Duration(seconds: 1), Duration(seconds: 3)];

  /// Обратно-совместимая обёртка над [fetch]: путь при успехе, `null` при
  /// ошибке. `304` тоже успех — возвращает путь к существующему файлу.
  static Future<String?> download(
    String id,
    String url, {
    http.Client? client,
    List<Duration>? backoffs,
  }) async {
    final r = await fetch(id, url, client: client, backoffs: backoffs);
    return r.ok ? r.path : null;
  }

  /// Скачать с полным исходом (§366).
  ///
  /// `conditional: true` — послать `If-None-Match` с сохранённым ETag, чтобы
  /// сервер мог ответить `304` без тела. Так авто-обновление по TTL стоит
  /// почти нулевого трафика. Ручной ⟳ юзера зовёт с `false`: «обновить»
  /// должно перекачивать, даже если сервер считает копию свежей.
  ///
  /// **Файл при неудаче не трогается.** Устаревший, но рабочий rule-set лучше
  /// выключенного правила: `_refreshSrsCache` force-disable'ит правило только
  /// когда файла нет вовсе, и терять его на сетевом сбое или 404 нельзя.
  static Future<DownloadResult> fetch(
    String id,
    String url, {
    bool conditional = false,
    http.Client? client,
    List<Duration>? backoffs,
  }) async {
    backoffs ??= _prodBackoffs;
    final now = DateTime.now();
    final prev = await readMeta(id);

    // Сохранить метаданные и вернуть исход. `error == null` = успех.
    Future<DownloadResult> finish(
      DownloadOutcome outcome, {
      String? etag,
      String? error,
    }) async {
      await _writeMeta(
        id,
        RuleSetMeta(
          // На успехе (200/304) — момент подтверждения актуальности.
          lastUpdated: error == null ? now : prev.lastUpdated,
          lastAttempt: now,
          // ETag держим прежний, если новый не пришёл: сервер мог не
          // прислать его на 304 — старый остаётся валидным ключом.
          etag: etag ?? prev.etag,
          lastError: error,
        ),
      );
      return DownloadResult(outcome, await cachedPath(id));
    }

    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final f = await _file(id);
        final tmp = File('${f.path}.tmp');

        final headers = <String, String>{'User-Agent': 'LxBox'};
        // Условный GET имеет смысл только когда файл реально лежит: с
        // etag'ом от снесённого кэша сервер ответил бы 304 на пустоту.
        final etag = prev.etag;
        if (conditional && etag != null && etag.isNotEmpty && await f.exists()) {
          headers['If-None-Match'] = etag;
        }

        final resp = await (client != null
                ? client.get(Uri.parse(url), headers: headers)
                : http.get(Uri.parse(url), headers: headers))
            .timeout(_timeout);

        if (resp.statusCode == 304) {
          return await finish(DownloadOutcome.notModified);
        }
        if (resp.statusCode >= 400 && resp.statusCode < 500) {
          return await finish(DownloadOutcome.failed,
              error: 'HTTP ${resp.statusCode}');
        }
        if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) {
          if (attempt < backoffs.length) {
            await Future<void>.delayed(backoffs[attempt]);
            continue;
          }
          return await finish(DownloadOutcome.failed,
              error: resp.bodyBytes.isEmpty && resp.statusCode == 200
                  ? 'empty body'
                  : 'HTTP ${resp.statusCode}');
        }
        await tmp.writeAsBytes(resp.bodyBytes, flush: true);
        if (await f.exists()) await f.delete();
        await tmp.rename(f.path);
        return await finish(DownloadOutcome.downloaded,
            etag: resp.headers['etag']);
      } catch (e) {
        if (attempt < backoffs.length) {
          await Future<void>.delayed(backoffs[attempt]);
          continue;
        }
        return await finish(DownloadOutcome.failed, error: _shortError(e));
      }
    }
    return await finish(DownloadOutcome.failed, error: 'retries exhausted');
  }

  /// Тип исключения без стектрейса и без URL — строка попадает в UI.
  static String _shortError(Object e) {
    if (e is TimeoutException) return 'timeout';
    if (e is SocketException) return 'network unreachable';
    return e.runtimeType.toString();
  }

  /// Удалить cached-файл и его метаданные (noop если нет). Вызывать при
  /// delete rule или change URL.
  ///
  /// §366 — метаданные сносим вместе с файлом: осиротевший `.meta.json` с
  /// чужим etag'ом заставил бы следующий условный GET получить `304` на
  /// пустой кэш.
  static Future<void> delete(String id) async {
    try {
      final f = await _file(id);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    try {
      final m = await _metaFile(id);
      if (await m.exists()) await m.delete();
    } catch (_) {}
  }

  // ─── Preset bundles (spec §033 / task 011) ─────────────────────────────
  //
  // Для bundle-пресетов с remote `rule_set` в шаблоне мы кэшируем файл
  // локально по составному ключу `preset__<presetId>__<tag>`. Тот же
  // принцип spec 011: sing-box получает `type: local, path: <кэш>`,
  // никаких auto-download в рантайме.
  //
  // Ключ namespace'ится префиксом `preset__` чтобы не столкнуться с
  // UUID'ами `CustomRuleSrs.id`. Два двойных-подчёркивания в роли
  // разделителя — UUID'ы не содержат их подряд.

  static String presetCacheId(String presetId, String ruleSetTag) =>
      'preset__${presetId}__$ruleSetTag';

  static Future<String?> cachedPathForPreset(
    String presetId,
    String ruleSetTag,
  ) =>
      cachedPath(presetCacheId(presetId, ruleSetTag));

  static Future<String?> downloadForPreset(
    String presetId,
    String ruleSetTag,
    String url,
  ) =>
      download(presetCacheId(presetId, ruleSetTag), url);

  /// §366 — [fetch] для preset-рулсета (условный GET авто-обновления).
  static Future<DownloadResult> fetchForPreset(
    String presetId,
    String ruleSetTag,
    String url, {
    bool conditional = false,
    http.Client? client,
    List<Duration>? backoffs,
  }) =>
      fetch(presetCacheId(presetId, ruleSetTag), url,
          conditional: conditional, client: client, backoffs: backoffs);

  /// §366 — метаданные preset-рулсета.
  static Future<RuleSetMeta> readMetaForPreset(
          String presetId, String ruleSetTag) =>
      readMeta(presetCacheId(presetId, ruleSetTag));

  static Future<void> deleteForPreset(String presetId, String ruleSetTag) =>
      delete(presetCacheId(presetId, ruleSetTag));

  /// Удаляет `.srs`-файлы, чей id не присутствует в [activeCacheIds].
  ///
  /// Мотивация: после миграций схемы (inline → preset bundle, smena
  /// RuleSet'ов в шаблоне), удаления правил и т.п. в каталоге остаются
  /// osiротевшие файлы, занимая место без пользы. UI чистит по конкретным
  /// id (`delete`), но не видит «мусор» неизвестного происхождения.
  ///
  /// Принцип: список всех `.srs`-файлов, сравнить basename с
  /// [activeCacheIds], удалить всё чего нет в наборе. Идемпотентно:
  /// повторный вызов с тем же набором — noop.
  ///
  /// §366 — заодно чистит co-located метаданные (`<id>.meta.json`) по тому же
  /// набору активных id. Файлы прочих расширений не трогает.
  ///
  /// Возвращает число удалённых файлов.
  static Future<int> pruneOrphans(Set<String> activeCacheIds) async {
    try {
      final dir = await _dir();
      var pruned = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final String id;
        if (name.endsWith(_metaSuffix)) {
          id = name.substring(0, name.length - _metaSuffix.length);
        } else if (name.endsWith('.srs')) {
          id = name.substring(0, name.length - '.srs'.length);
        } else {
          continue;
        }
        if (activeCacheIds.contains(id)) continue;
        try {
          await entity.delete();
          pruned++;
        } catch (_) {}
      }
      return pruned;
    } catch (_) {
      return 0;
    }
  }
}
