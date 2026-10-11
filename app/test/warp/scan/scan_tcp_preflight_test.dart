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

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/scan/endpoint_scanner.dart';
import 'package:lxbox/services/warp/scan/scan_log.dart';
import 'package:lxbox/services/warp/scan/scan_models.dart';
import 'package:lxbox/services/warp/scan/scan_wg_probe.dart';

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
}
