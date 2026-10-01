// §525 — снятие корпуса публичных подписок.
//
// Скачивает каждый URL из `urls.txt` тем же User-Agent, каким представляется
// приложение (`LxBox-android/<version>`, см.
// `app/lib/services/subscription/user_agent.dart`), и складывает тело ответа в
// `app/test/fixtures/public_subscriptions/bodies/<id>.txt.gz` плюс запись в
// `index.json`.
//
// ЧТО именно лежит в теле: сущность ответа ровно в том виде, в каком её видит
// `decode()` у приложения, — то есть транспортный `Content-Encoding: gzip`
// снят (`package:http` разжимает его сам, `resp.body`), а содержимое подписки
// НЕ тронуто: base64-обёртка, URI-список, JSON, INI ложатся как есть.
// Собственное `.gz` файла тела — сжатие КОРПУСА (10.4 МБ → 4.5 МБ), к
// транспорту отношения не имеет: `run.dart` снимает его перед разбором.
//
// Снимок ОДИН: обновление = новый коммит (история живёт в git, не в каталоге).
// Умерший URL тело не теряет — ему ставится `dead_since`, см.
// `docs/testing/PUBLIC_SUBSCRIPTIONS_CORPUS.md`.
//
// Запуск:
//   dart run tool/public_subs/fetch.dart                # только отсутствующие
//   dart run tool/public_subs/fetch.dart --refresh       # перекачать все
//   dart run tool/public_subs/fetch.dart --urls FILE     # другой список
//
// Сеть нужна ТОЛЬКО здесь. Прогон по снимкам (`run.dart`) в сеть не ходит.

import 'dart:convert';
import 'dart:io';

const _root = 'app/test/fixtures/public_subscriptions';
const _timeout = Duration(seconds: 30);
const _retries = 3;

/// Профильные заголовки подписки: их читает загрузчик приложения, поэтому они
/// часть снимка. Остальные (`date`, `server`, CDN-шум) в корпус не едут —
/// шумят диффом при каждом обновлении.
const _keepHeaders = <String>[
  'content-type',
  'content-disposition',
  'content-encoding',
  'profile-title',
  'profile-update-interval',
  'profile-web-page-url',
  'subscription-userinfo',
  'support-url',
  'routing',
  'announce',
  'expire',
];

void main(List<String> args) async {
  final refresh = args.contains('--refresh');
  final urlsIdx = args.indexOf('--urls');
  final urlsPath = urlsIdx >= 0 && urlsIdx + 1 < args.length
      ? args[urlsIdx + 1]
      : '$_root/urls.txt';

  final ua = _userAgent();
  stdout.writeln('UA: $ua');

  final urls = File(urlsPath)
      .readAsLinesSync()
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .toList();
  // Дубли URL — один раз.
  final seen = <String>{};
  urls.retainWhere(seen.add);
  stdout.writeln('urls: ${urls.length}');

  Directory('$_root/bodies').createSync(recursive: true);

  // Прежний индекс: снимок, который не перекачиваем, должен уцелеть.
  final indexFile = File('$_root/index.json');
  final prev = <String, Map<String, dynamic>>{};
  if (indexFile.existsSync()) {
    final decoded = jsonDecode(indexFile.readAsStringSync());
    final entries = decoded is Map ? decoded['subscriptions'] as List : decoded as List;
    for (final e in entries.cast<Map<String, dynamic>>()) {
      prev[e['url'] as String] = e;
    }
  }

  final client = HttpClient()
    ..connectionTimeout = _timeout
    ..userAgent = ua
    // Транспортный gzip РАЗЖИМАЕТСЯ: приложение ходит `package:http`, и его
    // `resp.body` — уже распакованная сущность. Корпус должен нести ровно то,
    // что видит `decode()`, иначе снимок был бы про транспорт, а не про разбор.
    ..autoUncompress = true;

  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < urls.length; i++) {
    final url = urls[i];
    final id = _idFor(url, i);
    final bodyFile = 'bodies/$id.txt.gz';
    final onDisk = File('$_root/$bodyFile');

    if (!refresh && onDisk.existsSync() && prev.containsKey(url)) {
      out.add(prev[url]!);
      stdout.writeln('[${i + 1}/${urls.length}] skip $id (есть)');
      continue;
    }

    final res = await _fetch(client, url);
    if (res == null) {
      // Мёртвый URL: запись остаётся, тело (если было) не трогаем.
      final old = prev[url];
      final rec = <String, dynamic>{
        ...?old,
        'id': id,
        'url': url,
        'source': _sourceOf(url),
        'dead_since': (old?['dead_since'] as String?) ??
            DateTime.now().toUtc().toIso8601String().split('T').first,
      };
      out.add(rec);
      stdout.writeln('[${i + 1}/${urls.length}] DEAD $id');
      continue;
    }

    onDisk.parent.createSync(recursive: true);
    onDisk.writeAsBytesSync(gzip.encode(res.bytes));

    out.add({
      'id': id,
      'url': url,
      'source': _sourceOf(url),
      'title': res.headers['profile-title'] ?? '',
      'fetched_at': DateTime.now().toUtc().toIso8601String(),
      'http_status': res.status,
      'content_type': res.headers['content-type'] ?? '',
      'headers': res.headers,
      'body_sha256': _sha256Hex(res.bytes),
      'body_file': bodyFile,
      'body_bytes': res.bytes.length,
      'body_kind_hint': _kindHint(res.bytes),
    });
    stdout.writeln(
        '[${i + 1}/${urls.length}] ok $id ${res.status} ${res.bytes.length}B');
  }
  client.close();

  out.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
  indexFile.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
            'schema': 1,
            'note': 'см. docs/testing/PUBLIC_SUBSCRIPTIONS_CORPUS.md',
            'subscriptions': out,
          })}\n');
  stdout.writeln('index.json: ${out.length} записей');
}

class _Res {
  _Res(this.status, this.headers, this.bytes);
  final int status;
  final Map<String, String> headers;
  final List<int> bytes;
}

Future<_Res?> _fetch(HttpClient client, String url) async {
  for (var attempt = 1; attempt <= _retries; attempt++) {
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(_timeout);
      req.followRedirects = true;
      final resp = await req.close().timeout(_timeout);
      final bytes = <int>[];
      await resp.forEach(bytes.addAll).timeout(_timeout);
      if (resp.statusCode != 200) {
        stderr.writeln('  $url → HTTP ${resp.statusCode}');
        if (resp.statusCode >= 400 && resp.statusCode < 500) return null;
        continue;
      }
      final headers = <String, String>{};
      resp.headers.forEach((name, values) {
        final n = name.toLowerCase();
        if (_keepHeaders.contains(n)) headers[n] = values.join(', ');
      });
      return _Res(resp.statusCode, headers, bytes);
    } catch (e) {
      stderr.writeln('  $url → попытка $attempt: $e');
      if (attempt < _retries) {
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      }
    }
  }
  return null;
}

/// Стабильный id: `<source>-<последний осмысленный сегмент>-<индекс>`. Индекс
/// держит уникальность для тёзок (`whitelist` у пяти зеркал).
String _idFor(String url, int i) {
  final u = Uri.parse(url);
  var last = u.pathSegments.isEmpty
      ? u.host
      : u.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => u.host);
  // Процентные последовательности бывают битые (кириллица в чужой кодировке) —
  // на id это влиять не должно, поэтому декодируем мягко.
  try {
    last = Uri.decodeComponent(last);
  } catch (_) {
    // оставляем как есть
  }
  last = last.replaceAll(RegExp(r'\.(txt|json|yaml|yml)$'), '');
  final slug = last
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  final n = (i + 1).toString().padLeft(2, '0');
  return '$n-${_sourceOf(url)}-${slug.isEmpty ? 'body' : slug}';
}

String _sourceOf(String url) {
  final h = Uri.parse(url).host.toLowerCase();
  if (h.contains('githubusercontent') || h.contains('github.com')) return 'github';
  if (h.contains('codeberg')) return 'codeberg';
  if (h.contains('gitverse')) return 'gitverse';
  if (h.contains('gitlab')) return 'gitlab';
  if (h.contains('bitbucket')) return 'bitbucket';
  if (h.contains('hub.mos.ru')) return 'moshub';
  return 'domain';
}

/// Грубая догадка о роде тела — для навигации по индексу, не для разбора.
/// Истину о роде говорит `decode()` при прогоне.
String _kindHint(List<int> bytes) {
  if (bytes.isEmpty) return 'empty';
  String head;
  try {
    head = utf8.decode(bytes.take(4096).toList(), allowMalformed: true).trimLeft();
  } catch (_) {
    return 'binary';
  }
  if (head.isEmpty) return 'empty';
  if (head.startsWith('{') || head.startsWith('[')) return 'json';
  if (head.startsWith('[Interface]') || head.startsWith('[Peer]')) return 'ini';
  if (RegExp(r'^[a-z0-9+]+://', caseSensitive: false).hasMatch(head)) {
    return 'uri_lines';
  }
  if (RegExp(r'^(proxies|proxy-groups|port|mixed-port|mode):').hasMatch(head)) {
    return 'clash_yaml';
  }
  if (RegExp(r'^[A-Za-z0-9+/=\s-]+$').hasMatch(head)) return 'base64';
  return 'unknown';
}

/// SHA-256 без пакетов: `crypto` в dev-зависимостях приложения, а скрипт
/// должен запускаться и голым `dart run`.
String _sha256Hex(List<int> data) {
  final k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
  var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
  const mask = 0xffffffff;
  int rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & mask;

  final len = data.length;
  final padded = <int>[...data, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  final bitLen = len * 8;
  for (var i = 7; i >= 0; i--) {
    padded.add((bitLen >>> (i * 8)) & 0xff);
  }

  final w = List<int>.filled(64, 0);
  for (var off = 0; off < padded.length; off += 64) {
    for (var i = 0; i < 16; i++) {
      final j = off + i * 4;
      w[i] = (padded[j] << 24) |
          (padded[j + 1] << 16) |
          (padded[j + 2] << 8) |
          padded[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & mask;
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, hh = h7;
    for (var i = 0; i < 64; i++) {
      final S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ (~e & g);
      final t1 = (hh + S1 + ch + k[i] + w[i]) & mask;
      final S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (S0 + maj) & mask;
      hh = g; g = f; f = e; e = (d + t1) & mask;
      d = c; c = b; b = a; a = (t1 + t2) & mask;
    }
    h0 = (h0 + a) & mask; h1 = (h1 + b) & mask; h2 = (h2 + c) & mask;
    h3 = (h3 + d) & mask; h4 = (h4 + e) & mask; h5 = (h5 + f) & mask;
    h6 = (h6 + g) & mask; h7 = (h7 + hh) & mask;
  }
  return [h0, h1, h2, h3, h4, h5, h6, h7]
      .map((x) => x.toRadixString(16).padLeft(8, '0'))
      .join();
}

/// UA приложения. Версия — из `app/pubspec.yaml`, чтобы снимок соответствовал
/// тому, что видит панель от настоящего клиента.
String _userAgent() {
  final pub = File('app/pubspec.yaml').readAsLinesSync();
  final line = pub.firstWhere((l) => l.startsWith('version:'), orElse: () => '');
  var ver = line.split(':').last.trim().split('+').first.trim();
  if (ver.startsWith('v')) ver = ver.substring(1);
  ver = ver.replaceAll(RegExp(r'[()\s;]+'), '');
  return 'LxBox-android/${ver.isEmpty ? 'unknown' : ver}';
}
