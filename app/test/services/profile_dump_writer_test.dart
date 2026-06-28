import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/profile_dump_writer.dart';
import 'package:lxbox/vpn/pprof_profile.dart';

/// §207 — `ProfileDumpWriter`: goroutine-дамп → `.txt`, CPU-профиль → `.pb`,
/// оба в temp с timestamp-именем. Round-trip содержимого.
void main() {
  late Directory tmp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_profile_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getTemporaryDirectory' ||
          call.method == 'getTemporaryPath') {
        return tmp.path;
      }
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('writeGoroutines writes a .txt under temp with the text content',
      () async {
    const text = 'goroutine 1 [running]:\nmain.main()\n';
    final path = await ProfileDumpWriter.writeGoroutines(text);

    expect(path, startsWith(tmp.path));
    final name = path.split('/').last;
    expect(name, startsWith('goroutines-'));
    expect(name, endsWith('.txt'));
    expect(await File(path).readAsString(), text);
  });

  test('writeCpuProfile writes a .pb under temp with the raw bytes', () async {
    final bytes = Uint8List.fromList([0x0a, 0x00, 0xff, 0x42, 0x13]);
    final path = await ProfileDumpWriter.writeCpuProfile(bytes);

    expect(path, startsWith(tmp.path));
    final name = path.split('/').last;
    expect(name, startsWith('cpu-'));
    expect(name, endsWith('.pb'));
    expect(await File(path).readAsBytes(), bytes);
  });

  test('timestamped names: filename has no colons (path-safe)', () async {
    final path = await ProfileDumpWriter.writeGoroutines('x');
    expect(path.split('/').last, isNot(contains(':')));
  });

  test('writeProfile uses descriptor fileBase + ext (heap → .pb)', () async {
    final heap = PprofProfile.all.firstWhere((p) => p.id == 'heap');
    final bytes = Uint8List.fromList([0x05, 0x06, 0x07]);
    final path = await ProfileDumpWriter.writeProfile(heap, bytes);
    final name = path.split('/').last;
    expect(name, startsWith('heap-'));
    expect(name, endsWith('.pb'));
    expect(await File(path).readAsBytes(), bytes);
  });

  test('PprofProfile.all: ids are in the native allowlist, goroutine is text',
      () {
    const allowed = {
      'goroutine', 'profile', 'heap', 'allocs', 'block', 'mutex',
      'threadcreate'
    };
    for (final p in PprofProfile.all) {
      expect(allowed, contains(p.id), reason: '${p.id} not in native allowlist');
      // pathAndQuery must start with the id (native splits on '?').
      expect(p.pathAndQuery.split('?').first, p.id);
      // Only goroutine summaries/full are text.
      expect(p.isText, p.id == 'goroutine');
      // Only CPU profile is blocking.
      expect(p.blockingSeconds > 0, p.id == 'profile');
    }
  });
}
