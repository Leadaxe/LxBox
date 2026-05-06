// §043: parseLevel — sing-box log format level extraction.

import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/models/debug_entry.dart';
import 'package:lxbox/services/clash_log_pump.dart';

void main() {
  group('ClashLogPump.parseLevel (§043)', () {
    test('WARN → DebugLevel.warning', () {
      const line = '+0300 2026-05-06 12:34:56 WARN  outbound/vless[vpn-1]: dial failed: i/o timeout';
      expect(ClashLogPump.parseLevel(line), DebugLevel.warning);
    });

    test('ERROR → DebugLevel.error', () {
      const line = '+0300 2026-05-06 12:34:56 ERROR  inbound/tun: read packet: bad descriptor';
      expect(ClashLogPump.parseLevel(line), DebugLevel.error);
    });

    test('FATAL → DebugLevel.error', () {
      const line = '+0000 2026-01-01 00:00:00 FATAL  router: initialization failed';
      expect(ClashLogPump.parseLevel(line), DebugLevel.error);
    });

    test('PANIC → DebugLevel.error', () {
      const line = '+0000 2026-01-01 00:00:00 PANIC  unrecoverable: ...';
      expect(ClashLogPump.parseLevel(line), DebugLevel.error);
    });

    test('INFO → DebugLevel.info', () {
      const line = '+0300 2026-05-06 12:34:56 INFO  router: rule[0]: domain_suffix';
      expect(ClashLogPump.parseLevel(line), DebugLevel.info);
    });

    test('DEBUG → DebugLevel.debug (хотя в проде filter в Kotlin не доходит)', () {
      const line = '+0300 2026-05-06 12:34:56 DEBUG  some component: details';
      expect(ClashLogPump.parseLevel(line), DebugLevel.debug);
    });

    test('TRACE → DebugLevel.debug', () {
      const line = '+0300 2026-05-06 12:34:56 TRACE  trace info';
      expect(ClashLogPump.parseLevel(line), DebugLevel.debug);
    });

    test('неизвестный/некорректный формат → fallback DebugLevel.info', () {
      expect(ClashLogPump.parseLevel('plain message without level'),
          DebugLevel.info);
      expect(ClashLogPump.parseLevel(''), DebugLevel.info);
      expect(ClashLogPump.parseLevel('xxxx'), DebugLevel.info);
    });

    test('error приоритетнее warn в смешанной строке (защита от спорных случаев)', () {
      // Если по какой-то причине строка содержит и WARN и ERROR token'ы,
      // ERROR имеет приоритет.
      const line = '+0300 2026-05-06 12:34:56 ERROR  WARN was reported earlier';
      expect(ClashLogPump.parseLevel(line), DebugLevel.error);
    });

    // §043 fix — sing-box default formatter (после strip'а ANSI) выдаёт
    // уровень слитно с timer'ом: `INFO[0006]` без пробела перед `[`.
    test('default-formatter формат INFO[NNNN] → DebugLevel.info', () {
      const line = 'INFO[0006] [402815533 25ms] router: found package name: com.leadaxe.lxbox';
      expect(ClashLogPump.parseLevel(line), DebugLevel.info);
    });

    test('default-formatter формат WARN[NNNN] → DebugLevel.warning', () {
      const line = 'WARN[0017] outbound/vless[vpn-1]: dial failed: i/o timeout';
      expect(ClashLogPump.parseLevel(line), DebugLevel.warning);
    });

    test('default-formatter формат ERROR[NNNN] → DebugLevel.error', () {
      const line = 'ERROR[0023] router: initialization failed';
      expect(ClashLogPump.parseLevel(line), DebugLevel.error);
    });

    test('WARNING (substring внутри слова) — наш regex word-boundary матчит WARN', () {
      // Edge case: regex `\bWARN\b` НЕ матчит WARNING (там нет границы после
      // 4 букв). Hard guarantee для filter'а.
      const line = 'INFO[0006] router: WARNING substring should not flag warning';
      expect(ClashLogPump.parseLevel(line), DebugLevel.info);
    });
  });
}
