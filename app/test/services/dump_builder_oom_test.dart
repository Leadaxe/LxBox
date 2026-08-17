// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/dump_builder.dart';
import 'package:lxbox/services/oom_reports.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

/// §397 — OOM-секция дампа: сводка у всех снимков, тела у kOomKeep
/// свежайших. База каталогов — как в oom_reports_test: MethodChannel в
/// тестах не поднят, `CrashReports.baseDir()` падает на path_provider.
void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('dump_oom_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Снимок как его кладёт ядро §397: metadata + профили + текстовые файлы.
  Future<Directory> writeSnapshot(
    String name, {
    DateTime? mtime,
    List<int>? heapPb,
    String? goLog,
    Map<String, Object?>? connections,
    Map<String, Object?>? configuration,
    String? cmdline,
  }) async {
    final dir = Directory('${tempDir.path}/$kOomArchiveDir/$name');
    await dir.create(recursive: true);
    if (heapPb != null) {
      await File('${dir.path}/heap.pb').writeAsBytes(heapPb);
    }
    if (goLog != null) {
      await File('${dir.path}/go.log').writeAsString(goLog);
    }
    if (connections != null) {
      await File('${dir.path}/connections.json')
          .writeAsString(jsonEncode(connections));
    }
    if (configuration != null) {
      await File('${dir.path}/configuration.json')
          .writeAsString(jsonEncode(configuration));
    }
    if (cmdline != null) {
      await File('${dir.path}/cmdline').writeAsString(cmdline);
    }
    final meta = File('${dir.path}/$kOomMetaName');
    await meta.writeAsString(jsonEncode({
      'coreVersion': '1.14.0-lx.25',
      'memoryUsage': '512 MB',
      'heapInuse': '160 MB',
      'numGoroutine': '200',
      'sys': '190 MB',
      'stackInuse': '4 MB',
    }));
    if (mtime != null) await meta.setLastModified(mtime);
    return dir;
  }

  test('body carries all files: text readable, binaries gzip+base64',
      () async {
    final heap = List<int>.generate(4096, (i) => i % 251);
    await writeSnapshot(
      '2026-08-12T14-03-51',
      heapPb: heap,
      goLog: 'line1\nline2\n',
      connections: {
        'connections': [
          {'id': '1', 'outbound': 'proxy'}
        ]
      },
      configuration: {'log': {}},
      cmdline: 'libbox\x00run',
    );

    final section = await DumpBuilder.oomReportsSection();
    expect(section, hasLength(1));
    final entry = section.single;

    // Сводка на месте, как до §397.
    expect(entry['name'], '2026-08-12T14-03-51');
    expect(entry['memory_usage'], '512 MB');
    expect(entry['heap_inuse'], '160 MB');
    expect(entry['num_goroutine'], 200);

    // Полный metadata.json — с полями, которых в сводке нет.
    final meta = entry['metadata'] as Map;
    expect(meta['sys'], '190 MB');
    expect(meta['stackInuse'], '4 MB');

    expect(entry['go_log'], 'line1\nline2\n');
    expect(entry['go_log_truncated'], isNull);
    expect((entry['connections'] as Map)['connections'], hasLength(1));
    expect(entry['configuration'], {'log': {}});
    expect(entry['cmdline'], 'libbox run');

    // heap.pb: gzip+base64 разворачивается в исходные байты.
    final files = entry['files'] as Map;
    final pb = files['heap.pb'] as Map;
    expect(pb['encoding'], 'gzip+base64');
    expect(pb['raw_size'], heap.length);
    expect(gzip.decode(base64Decode(pb['data'] as String)), heap);
  });

  test('bodies only for kOomKeep freshest, tail stays summary-only',
      () async {
    final base = DateTime(2026, 8, 1, 12);
    for (var i = 0; i < kOomKeep + 2; i++) {
      await writeSnapshot(
        '2026-08-0${i + 1}T00-00-00',
        mtime: base.add(Duration(days: i)),
        heapPb: [1, 2, 3],
      );
    }

    final section = await DumpBuilder.oomReportsSection();
    expect(section, hasLength(kOomKeep + 2));
    // list() отдаёт новые первыми: тела у первых kOomKeep записей.
    for (final (i, entry) in section.indexed) {
      final hasBody = entry.containsKey('metadata');
      expect(hasBody, i < kOomKeep,
          reason: 'entry $i (${entry['name']})');
      expect(entry.containsKey('files'), i < kOomKeep);
      expect(entry['memory_usage'], '512 MB');
    }
  });

  test('go.log over the limit keeps the tail and sets the flag', () async {
    final limit = 64 * 1024;
    final log = '${'x' * limit}TAIL';
    await writeSnapshot('2026-08-12T15-00-00', goLog: log);

    final entry = (await DumpBuilder.oomReportsSection()).single;
    final kept = entry['go_log'] as String;
    expect(entry['go_log_truncated'], isTrue);
    expect(kept.length, limit);
    expect(kept, endsWith('TAIL'));
  });

  test('whole section is JSON-encodable', () async {
    await writeSnapshot('2026-08-12T16-00-00',
        heapPb: List<int>.filled(64, 7), goLog: 'ok');
    final section = await DumpBuilder.oomReportsSection();
    expect(() => jsonEncode(section), returnsNormally);
  });
}
