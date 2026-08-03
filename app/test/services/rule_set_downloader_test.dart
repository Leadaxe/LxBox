// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/services/rule_set_downloader.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'dart:io';

class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String tempRoot;
  _FakePathProvider(this.tempRoot);
  @override
  Future<String?> getApplicationDocumentsPath() async => tempRoot;
}

/// Те же 2 ретрая что в проде, но без реального сна — иначе тест спал бы
/// 1s+3s и в параллельном suite (§T3) сдвигался к таймауту → flaky.
const _noBackoff = [Duration.zero, Duration.zero];

void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('rsd_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    // _cacheDir переживает между тестами — без сброса download() пишет в
    // директорию первого setUp (уже снесённую его tearDown). §T3.
    RuleSetDownloader.resetCacheForTesting();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('RuleSetDownloader.download retry (night T3-1)', () {
    test('3rd attempt succeeds after 2 transient 503s', () async {
      var attempts = 0;
      final client = MockClient((req) async {
        attempts++;
        if (attempts < 3) return http.Response('boom', 503);
        return http.Response.bytes([1, 2, 3, 4], 200);
      });
      final id = 'test-id-${DateTime.now().microsecondsSinceEpoch}';
      final path = await RuleSetDownloader.download(id, 'http://x/r.srs',
          client: client, backoffs: _noBackoff);
      expect(path, isNotNull);
      expect(attempts, 3);
      expect(await File(path!).readAsBytes(), [1, 2, 3, 4]);
    });

    test('404 → returns null immediately, no retry', () async {
      var attempts = 0;
      final client = MockClient((req) async {
        attempts++;
        return http.Response('gone', 404);
      });
      final id = 'test-id-${DateTime.now().microsecondsSinceEpoch}';
      final path = await RuleSetDownloader.download(id, 'http://x/r.srs',
          client: client, backoffs: _noBackoff);
      expect(path, isNull);
      expect(attempts, 1, reason: '4xx is permanent — no retry');
    });

    test('все 3 попытки 503 → null', () async {
      var attempts = 0;
      final client = MockClient((req) async {
        attempts++;
        return http.Response('x', 503);
      });
      final id = 'test-id-${DateTime.now().microsecondsSinceEpoch}';
      final path = await RuleSetDownloader.download(id, 'http://x/r.srs',
          client: client, backoffs: _noBackoff);
      expect(path, isNull);
      expect(attempts, 3);
    });

    test('empty body (200) → retries, eventually returns null', () async {
      var attempts = 0;
      final client = MockClient((req) async {
        attempts++;
        return http.Response.bytes([], 200);
      });
      final id = 'test-id-${DateTime.now().microsecondsSinceEpoch}';
      final path = await RuleSetDownloader.download(id, 'http://x/r.srs',
          client: client, backoffs: _noBackoff);
      expect(path, isNull);
      expect(attempts, 3);
    });
  });

  group('§366 — условный GET + метаданные', () {
    String freshId() => 'ttl-${DateTime.now().microsecondsSinceEpoch}';

    test('200 сохраняет ETag и время обновления', () async {
      final client = MockClient((req) async => http.Response.bytes(
            [1, 2, 3],
            200,
            headers: {'etag': '"abc"'},
          ));
      final id = freshId();
      final r = await RuleSetDownloader.fetch(id, 'http://x/r.srs',
          client: client, backoffs: _noBackoff);
      expect(r.outcome, DownloadOutcome.downloaded);
      expect(r.changed, isTrue);

      final meta = await RuleSetDownloader.readMeta(id);
      expect(meta.etag, '"abc"');
      expect(meta.lastUpdated, isNotNull);
      expect(meta.lastError, isNull);
      expect(meta.failing, isFalse);
    });

    test('If-None-Match уходит в запрос, когда etag сохранён', () async {
      final id = freshId();
      final seenHeaders = <Map<String, String>>[];
      final client = MockClient((req) async {
        seenHeaders.add(Map.of(req.headers));
        return http.Response.bytes([9], 200, headers: {'etag': '"v1"'});
      });
      // Первый заход: etag'а ещё нет — заголовка быть не должно.
      await RuleSetDownloader.fetch(id, 'http://x/r.srs',
          client: client, backoffs: _noBackoff, conditional: true);
      expect(seenHeaders.first.containsKey('If-None-Match'), isFalse);

      // Второй: etag сохранён, файл на месте → шлём условный GET.
      await RuleSetDownloader.fetch(id, 'http://x/r.srs',
          client: client, backoffs: _noBackoff, conditional: true);
      expect(seenHeaders.last['If-None-Match'], '"v1"');
    });

    test('conditional:false не шлёт If-None-Match (ручной ⟳ качает всегда)',
        () async {
      final id = freshId();
      final seen = <Map<String, String>>[];
      final client = MockClient((req) async {
        seen.add(Map.of(req.headers));
        return http.Response.bytes([9], 200, headers: {'etag': '"v1"'});
      });
      await RuleSetDownloader.fetch(id, 'http://x/r.srs',
          client: client, backoffs: _noBackoff, conditional: true);
      await RuleSetDownloader.fetch(id, 'http://x/r.srs',
          client: client, backoffs: _noBackoff);
      expect(seen.last.containsKey('If-None-Match'), isFalse);
    });

    test('304 — файл не переписан, но lastUpdated сдвинут', () async {
      final id = freshId();
      var serve304 = false;
      final client = MockClient((req) async => serve304
          ? http.Response('', 304)
          : http.Response.bytes([1, 2, 3], 200, headers: {'etag': '"v1"'}));

      await RuleSetDownloader.fetch(id, 'http://x/r.srs',
          client: client, backoffs: _noBackoff, conditional: true);
      final path = (await RuleSetDownloader.cachedPath(id))!;
      final firstUpdated = (await RuleSetDownloader.readMeta(id)).lastUpdated!;

      // Разводим по времени, чтобы сдвиг было видно.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      serve304 = true;
      final r = await RuleSetDownloader.fetch(id, 'http://x/r.srs',
          client: client, backoffs: _noBackoff, conditional: true);

      expect(r.outcome, DownloadOutcome.notModified);
      expect(r.ok, isTrue, reason: '304 — успех, кэш подтверждённо свежий');
      expect(r.changed, isFalse, reason: 'содержимое не менялось');
      expect(await File(path).readAsBytes(), [1, 2, 3]);

      final meta = await RuleSetDownloader.readMeta(id);
      expect(meta.lastUpdated!.isAfter(firstUpdated), isTrue);
      expect(meta.etag, '"v1"', reason: '304 без etag — держим прежний');
      expect(meta.lastError, isNull);
    });

    test('404 не удаляет уже скачанный файл и пишет ошибку', () async {
      final id = freshId();
      var serve404 = false;
      final client = MockClient((req) async => serve404
          ? http.Response('gone', 404)
          : http.Response.bytes([7, 7], 200));

      await RuleSetDownloader.fetch(id, 'http://x/r.srs',
          client: client, backoffs: _noBackoff);
      serve404 = true;
      final r = await RuleSetDownloader.fetch(id, 'http://x/r.srs',
          client: client, backoffs: _noBackoff, conditional: true);

      expect(r.outcome, DownloadOutcome.failed);
      // Главный инвариант §366: устаревший рабочий rule-set лучше пустоты.
      expect(r.path, isNotNull);
      expect(await File(r.path!).readAsBytes(), [7, 7]);

      final meta = await RuleSetDownloader.readMeta(id);
      expect(meta.failing, isTrue);
      expect(meta.lastError, 'HTTP 404');
      expect(meta.lastUpdated, isNotNull,
          reason: 'время прошлого успеха не затирается неудачей');
    });

    test('download() остаётся обратно-совместимым: 304 → путь, не null',
        () async {
      final id = freshId();
      var serve304 = false;
      final client = MockClient((req) async => serve304
          ? http.Response('', 304)
          : http.Response.bytes([5], 200, headers: {'etag': '"e"'}));
      await RuleSetDownloader.download(id, 'http://x/r.srs',
          client: client, backoffs: _noBackoff);
      serve304 = true;
      final path = await RuleSetDownloader.fetch(id, 'http://x/r.srs',
          client: client, backoffs: _noBackoff, conditional: true);
      expect(path.path, isNotNull);
    });

    test('delete() сносит и метаданные', () async {
      final id = freshId();
      final client = MockClient(
          (req) async => http.Response.bytes([1], 200, headers: {'etag': '"e"'}));
      await RuleSetDownloader.fetch(id, 'http://x/r.srs',
          client: client, backoffs: _noBackoff);
      expect((await RuleSetDownloader.readMeta(id)).etag, isNotNull);

      await RuleSetDownloader.delete(id);
      final meta = await RuleSetDownloader.readMeta(id);
      // Иначе следующий условный GET получил бы 304 на пустой кэш.
      expect(meta.etag, isNull);
      expect(meta.lastUpdated, isNull);
    });

    test('pruneOrphans чистит осиротевшие .meta.json', () async {
      final keep = freshId();
      final orphan = '$keep-orphan';
      final client = MockClient(
          (req) async => http.Response.bytes([1], 200, headers: {'etag': '"e"'}));
      await RuleSetDownloader.fetch(keep, 'http://x/a.srs',
          client: client, backoffs: _noBackoff);
      await RuleSetDownloader.fetch(orphan, 'http://x/b.srs',
          client: client, backoffs: _noBackoff);

      await RuleSetDownloader.pruneOrphans({keep});

      expect(await RuleSetDownloader.isCached(keep), isTrue);
      expect((await RuleSetDownloader.readMeta(keep)).etag, isNotNull);
      expect(await RuleSetDownloader.isCached(orphan), isFalse);
      expect((await RuleSetDownloader.readMeta(orphan)).etag, isNull);
    });
  });
}
