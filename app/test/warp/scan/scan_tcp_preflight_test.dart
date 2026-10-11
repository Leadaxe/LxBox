// §838 — TCP-preflight MASQUE-h2.
//
// Зачем тест: в сети РФ оператор режет не только UDP/WG, но часто и TCP до
// MASQUE-адресов. Тогда probe-сессия ядра висит по ~8с на адрес и отдаёт
// `context deadline exceeded` — 32 кандидата это 4+ минуты «молчания», и
// пользователь видит «живых 0» без причины. Preflight (системный стек Dart,
// БЕЗ ядра) отделяет «порт закрыт» от «ядро не смогло» и пишет это в журнал.
//
// Здесь проверяется: (1) [probeTcpOpen] различает открытый и закрытый порт;
// (2) скан реально прогоняет preflight по h2-кандидатам и отчитывается в
// журнале — то есть механизм подключён, а не только объявлен.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/scan/endpoint_scanner.dart';
import 'package:lxbox/services/warp/scan/scan_log.dart';
import 'package:lxbox/services/warp/scan/scan_models.dart';
import 'package:lxbox/services/warp/scan/scan_wg_probe.dart';
import 'package:lxbox/vpn/cc_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('probeTcpOpen: слушающий порт → open=true', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close());
    final r = await probeTcpOpen(
      '127.0.0.1',
      server.port,
      timeout: const Duration(seconds: 2),
    );
    // ignore: avoid_print
    print('open-case: $r');
    expect(r.open, isTrue);
    expect(r.detail, contains('open'));
  });

  test('probeTcpOpen: закрытый порт → open=false', () async {
    // Занимаем эфемерный порт и сразу освобождаем — на нём никто не слушает.
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    final r = await probeTcpOpen(
      '127.0.0.1',
      port,
      timeout: const Duration(seconds: 2),
    );
    // ignore: avoid_print
    print('closed-case: $r');
    expect(r.open, isFalse);
  });

  test('scan: preflight h2-кандидатов отрабатывает и пишет в журнал', () async {
    // Прогреваем asset: пул берётся из bundled JSON (в тесте — из
    // build/unit_test_assets). Без него резервный пул всё равно даёт h2-блок.
    try {
      await rootBundle.loadString('assets/warp_endpoints.json');
    } catch (_) {}

    final log = ScanLog();
    final statuses = <ScanEndpointStatus>[];
    // Адрес из MASQUE-блока: классифицируется как h2 → попадает в preflight.
    final scanner = EndpointScanner();
    await scanner.scan(
      endpoints: const ['162.159.198.2'],
      concurrency: 4,
      timeout: const Duration(milliseconds: 400),
      // >0, иначе фаза 2 (и preflight вместе с ней) не запускается вовсе.
      maxGeoLookups: 4,
      log: log,
      onStatus: statuses.add,
    );

    final text = log.text;
    // ignore: avoid_print
    print(text);

    expect(
      text,
      contains('TCP-preflight MASQUE-h2'),
      reason: 'скан обязан прогнать preflight по MASQUE h2-кандидатам',
    );
    // Каждый h2-адрес получает явный вердикт preflight: либо `tcp-closed`
    // (TCP зарезан — это и есть диагноз), либо уходит дальше в probe-сессию.
    expect(
      statuses.any((s) => s.verdict == 'tcp-closed') ||
          text.contains('TCP открыт, подтверждаю') ||
          text.contains('→ кандидат на'),
      isTrue,
      reason: 'preflight должен дать вердикт по адресу, а не промолчать',
    );
  });

  // §839 (аудит Jules) — закрытый TCP у h2-кандидата БОЛЬШЕ НЕ выбрасывает
  // адрес. Живое доказательство из журнала пользователя: ответ
  // `http3: parsing frame failed: PROTOCOL_VIOLATION (remote)` означает, что
  // QUIC-пакеты до Cloudflare ДОШЛИ. Значит, путь закрыт только по TCP, и
  // такой адрес обязан уйти на проверку как MASQUE-h3, а не пропасть.
  test('§839: h2-кандидат с закрытым TCP уходит в h3, а не выбрасывается',
      () async {
    try {
      await rootBundle.loadString('assets/warp_endpoints.json');
    } catch (_) {}

    final log = ScanLog();
    final statuses = <ScanEndpointStatus>[];
    await EndpointScanner().scan(
      endpoints: const ['162.159.198.1', '162.159.198.2'],
      concurrency: 4,
      timeout: const Duration(milliseconds: 300),
      maxGeoLookups: 4,
      log: log,
      onStatus: statuses.add,
    );
    final text = log.text;
    // ignore: avoid_print
    print(text);

    // Старого поведения быть не должно: «пропускаю» = потеря живого адреса.
    expect(
      text,
      isNot(contains('пропускаю (TCP зарезан)')),
      reason: '§839: адрес с закрытым TCP не выбрасывается',
    );
    // Адрес, у которого TCP закрыт, обязан получить вердикт И уйти в h3.
    for (final s in statuses.where((s) => s.verdict == 'tcp-closed')) {
      expect(
        text,
        contains('fallback на MASQUE-h3'),
        reason: '§839: ${s.endpoint} — закрытый TCP ⇒ fallback на h3/QUIC',
      );
    }
    // Худший случай (сеть режет и TCP, и уводит всё в h3) — тоже валиден:
    // главное, что ни один h2-кандидат не потерян молча.
    expect(
      text.contains('→ кандидат на') ||
          text.contains('TCP открыт, подтверждаю') ||
          text.contains('fallback на MASQUE-h3'),
      isTrue,
      reason: 'preflight обязан вынести вердикт по каждому h2-адресу',
    );
  });

  // §839 — SNI ротируется по кандидатам. До правки ВСЕ MASQUE-узлы шли с
  // `masqueSniPool.first`, а это ровно родной `consumer-masque.cloudflareclient.com`
  // (он же `recommended_sni`): один «паливный» домен на весь батч, и DPI режет
  // по нему всё разом. Проверяем саму ротацию (чистая функция — не требует ни
  // ядра, ни аккаунта) и то, что настоящий пул снабжён приманками.
  test('§839: rotateMasqueSni разносит кандидатов по пулу, не повторяя первый',
      () {
    expect(rotateMasqueSni(const [], 0), '');
    expect(rotateMasqueSni(const ['a'], 0), 'a');
    expect(rotateMasqueSni(const ['a'], 7), 'a');
    // Ротация: индекс идёт по кругу — 10 кандидатов на пул из 3 дают a,b,c,a…
    const pool = ['a', 'b', 'c'];
    expect(
      [for (var i = 0; i < 10; i++) rotateMasqueSni(pool, i)],
      ['a', 'b', 'c', 'a', 'b', 'c', 'a', 'b', 'c', 'a'],
    );
    // Ключевое свойство §839: соседние кандидаты идут с РАЗНЫМИ SNI (до правки
    // все до одного получали pool[0]).
    expect(rotateMasqueSni(pool, 1), isNot(rotateMasqueSni(pool, 0)));
  });

  test('§839: родной SNI лежит в пуле первым — значит нужна ротация', () async {
    final raw = await rootBundle.loadString('assets/warp_endpoints.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final mq = json['masque'] as Map<String, dynamic>;
    final pool = (mq['sni_pool'] as List).cast<String>();
    expect(pool.length, greaterThan(1), reason: 'в пуле есть приманки');
    // Именно поэтому §839 обязателен: без ротации весь батч шёл под родным
    // доменом (легко узнаваемая подпись MASQUE-подключения к Cloudflare).
    expect(pool.first, mq['recommended_sni']);
    expect(pool.first, contains('consumer-masque'));
  });

  // §840 — повторные попытки по не ответившим адресам: классификатор одной
  // попытки «получено ли гео» — чистая функция, покрываю её напрямую.
  test('§840: probeGeoAttempt — ошибка, пустота и нет loc= = «не удалось»', () {
    const trace = 'ip=1.1.1.1\nloc=RU\ncolo=LED\n';
    // Нормальный ответ с гео → успех, контент сохраняется.
    expect(
      probeGeoAttempt(const CcGetUrlResult(
        status: 200, content: trace, truncated: false, contentType: 'text/plain',
        remoteAddr: '1.1.1.1:443', elapsedMs: 42, error: '')),
      (ok: true, content: trace),
    );
    // Ошибка транспорта (err) → неудача, повтор нужен.
    expect(
      probeGeoAttempt(const CcGetUrlResult(
        status: 0, content: '', truncated: false, contentType: '',
        remoteAddr: '', elapsedMs: 0, error: 'context deadline exceeded')),
      (ok: false, content: ''),
    );
    // Ответ БЕЗ loc=/colo= (CF не знает страну / не trace) → тоже неудача.
    expect(
      probeGeoAttempt(const CcGetUrlResult(
        status: 200, content: '<html>warp is on</html>', truncated: true,
        contentType: 'text/html', remoteAddr: 'x:443', elapsedMs: 5,
        error: '')),
      (ok: false, content: ''),
    );
  });

  test('§839: скан не теряет h2-кандидатов молча', () async {
    try {
      await rootBundle.loadString('assets/warp_endpoints.json');
    } catch (_) {}

    final log = ScanLog();
    await EndpointScanner().scan(
      endpoints: const [
        '162.159.198.1',
        '162.159.198.2',
        '162.159.199.1',
        '162.159.199.2',
      ],
      concurrency: 4,
      timeout: const Duration(milliseconds: 300),
      maxGeoLookups: 8,
      log: log,
      onStatus: (_) {},
    );
    final text = log.text;
    // ignore: avoid_print
    print(text);

    // Каждый h2-кандидат получает вердикт preflight — либо подтверждён, либо
    // переехал на другой порт, либо ушёл в h3. Молча выброшенных нет.
    final h2Candidates = const ['162.159.198.2', '162.159.199.2'];
    for (final ep in h2Candidates) {
      expect(
        text.contains('$ep ') &&
            (text.contains('$ep:443') ||
                text.contains('$ep tcp') ||
                text.contains('$ep →')),
        isTrue,
        reason: '§839: $ep обязан получить вердикт preflight',
      );
    }
    expect(text, isNot(contains('пропускаю (TCP зарезан)')));
  });
}
