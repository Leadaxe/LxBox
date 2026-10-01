import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';

/// Общая обвязка профиля для бенчей `test/perf/` (вынесена из §548, нужна
/// §550): сэмплирующий профилировщик VM через свой же VM service, голым
/// JSON-RPC по WebSocket. VM service `flutter test` поднимает только с
/// `--coverage` (или `--start-paused`).
///
/// Профиль сэмплирующим профилировщиком VM через свой же VM service.
///
/// [work] крутится [dur], затем `getCpuSamples` за это окно. Self — кадр на
/// вершине стека, inclusive — функция встречается в стеке хоть раз.
Future<String> vmProfile(
  void Function() work,
  Duration dur, {
  required String tag,
  required String unit,
  List<String> probes = const [],
  int topSelf = 25,
  int topOwn = 25,
  int topIncl = 40,
}) async {
  var info = await Service.getInfo();
  info.serverWebSocketUri ??
      (info = await Service.controlWebServer(enable: true));
  final uri = info.serverWebSocketUri;
  if (uri == null) return '$tag профиль: VM service недоступен';
  final ws = await WebSocket.connect(uri.toString());
  final pending = <String, Completer<Map<String, dynamic>>>{};
  var seq = 0;
  ws.listen((m) {
    final j = jsonDecode(m as String) as Map<String, dynamic>;
    pending.remove('${j['id']}')?.complete(j);
  });
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    final id = '${seq++}';
    final c = pending[id] = Completer<Map<String, dynamic>>();
    ws.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return c.future;
  }

  final isolateId = Service.getIsolateId(Isolate.current)!;
  await call('setFlag', {'name': 'profiler', 'value': 'true'});
  final period = await call('setFlag', {
    'name': 'profile_period',
    'value': '100',
  });
  await call('clearCpuSamples', {'isolateId': isolateId});
  final t0 = Timeline.now;
  var iters = 0;
  final sw = Stopwatch()..start();
  while (sw.elapsed < dur) {
    work();
    iters++;
  }
  final t1 = Timeline.now;
  final res = await call('getCpuSamples', {
    'isolateId': isolateId,
    'timeOriginMicros': t0,
    'timeExtentMicros': t1 - t0,
  });
  await ws.close();
  final r = res['result'] as Map<String, dynamic>?;
  if (r == null) return '$tag профиль: ошибка ${res['error']}';

  final fnList = r['functions'] as List;
  final fns = [for (final f in fnList) _fnName((f as Map)['function'] as Map)];
  final own = [for (final f in fnList) _isOwn('${(f as Map)['resolvedUrl']}')];
  final self = <String, int>{};
  final selfOwn = <String, int>{};
  final incl = <String, int>{};
  final samples = r['samples'] as List;
  for (final s in samples) {
    final stack = ((s as Map)['stack'] as List).cast<int>();
    if (stack.isEmpty) continue;
    self.update(fns[stack.first], (v) => v + 1, ifAbsent: () => 1);
    // Self, свёрнутый до кода приложения: время в `Map.[]`/`String.==`
    // приписывается ближайшему кадру lxbox, который их позвал.
    final firstOwn = stack.firstWhere((i) => own[i], orElse: () => -1);
    if (firstOwn >= 0) {
      selfOwn.update(fns[firstOwn], (v) => v + 1, ifAbsent: () => 1);
    }
    for (final name in {for (final i in stack) fns[i]}) {
      incl.update(name, (v) => v + 1, ifAbsent: () => 1);
    }
  }
  final total = samples.length;
  String pct(int v) => (100 * v / total).toStringAsFixed(1).padLeft(5);
  String top(Map<String, int> m, int k, [bool Function(String)? keep]) {
    final e = m.entries.where((x) => keep == null || keep(x.key)).toList()
      ..sort((a, b) => b.value - a.value);
    return [
      for (final x in e.take(k)) '  ${pct(x.value)}%  ${x.key}',
    ].join('\n');
  }

  final ownNames = {
    for (var i = 0; i < fns.length; i++)
      if (own[i]) fns[i],
  };
  return '$tag профиль: $iters прогонов $unit, $total сэмплов '
      '(profile_period=100 мкс: ${period['result'] ?? period['error']})\n'
      'self (кадр на вершине):\n${top(self, topSelf)}\n'
      'self, свёрнутый до кода lxbox:\n${top(selfOwn, topOwn)}\n'
      'inclusive, код lxbox:\n${top(incl, topIncl, ownNames.contains)}\n'
      'inclusive, точки гипотез:\n'
      '${top(incl, 30, (n) => probes.any(n.contains))}';
}

String _fnName(Map f) {
  final name = '${f['name']}';
  final owner = f['owner'];
  if (owner is Map && owner['type'] != '@Library' && owner['name'] != null) {
    final o = owner['type'] == '@Function'
        ? _fnName(owner)
        : '${owner['name']}';
    return '$o.$name';
  }
  return name;
}

/// Код приложения: `resolvedUrl` у профилировщика бывает и `package:`, и
/// `file://` — смотря как VM загрузила библиотеку.
bool _isOwn(String url) =>
    url.startsWith('package:lxbox/') || url.contains('/app/lib/');
