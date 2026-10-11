// §841 — живая проверка на РЕАЛЬНОЙ сети: голый WG-init vs AWG-залп.
// Запуск: cd app && dart run tool/scan_live_check.dart [ip] [port]
//
// Использует ТУ ЖЕ реализацию, что уходит в APK (scan_wire.dart +
// scan_awg_probe.dart), поэтому результат — это ответ на вопрос «что увидит
// телефон», а не отдельный python-эксперимент.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lxbox/services/warp/scan/scan_awg_probe.dart';
import 'package:lxbox/services/warp/scan/scan_i1.dart';
import 'package:lxbox/services/warp/scan/scan_wg_probe.dart';

Future<void> main(List<String> args) async {
  final ip = args.isNotEmpty ? args[0] : '162.159.192.74';
  final port = args.length > 1 ? int.parse(args[1]) : 2408;
  // Ключ аккаунта передаётся 3-м аргументом (base64) — для проверки, что
  // пробивает именно он; без него видно разницу «случайный ключ vs аккаунт».
  final accPriv = args.length > 2 ? base64Decode(args[2]) : null;
  stdout.writeln('== live probe $ip:$port '
      'ключ=${accPriv != null ? "аккаунт" : "случайный"} ==');

  // 1. Голый WG-init (то, что делала фаза 1 до §841).
  final plain = await probeWgEndpoint(ip, port,
      timeout: const Duration(seconds: 3));
  stdout.writeln('${'plain wg-init'.padRight(28)}: '
      '${plain.kind.name} ${plain.rttMs}ms  ${plain.detail}');

  // 2. AWG-залп: I1 + junk + init.
  for (final profile in ['default', ...kI1Profiles]) {
    final chain = profile == 'default' ? kI1DefaultChain : genI1(profile);
    final res = await probeAwgEndpoint(ip, port,
        timeout: const Duration(seconds: 3),
        i1Chain: chain,
        staticPrivRaw: accPriv);
    stdout.writeln('${'awg i1=$profile'.padRight(28)}: '
        '${res.kind.name} ${res.rttMs}ms  ${res.detail}');
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  // 3. Только junk, без I1 (`-i1 none` у эталона: 2/70).
  final noI1 = await probeAwgEndpoint(ip, port,
      timeout: const Duration(seconds: 3),
      obfuscate: false,
      staticPrivRaw: accPriv);
  stdout.writeln('${'awg i1=none'.padRight(28)}: '
      '${noI1.kind.name} ${noI1.rttMs}ms  ${noI1.detail}');

  // Контроль: живой ли вообще канал — DNS/QUIC-ответы.
  exit(0);
}
