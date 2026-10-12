// §841 — батч-проверка ТЕМ ЖЕ кодом, что в APK: scanAwgBatch по реальной
// выборке пула приложения (CIDR из assets/warp_endpoints.json).
// Запуск: cd app && dart run tool/scan_pool_live.dart <base64-priv> [sample]
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:lxbox/services/warp/scan/scan_awg_probe.dart';
import 'package:lxbox/services/warp/scan/scan_wg_probe.dart';

List<String> expandCidr(String cidr, int max) {
  final out = <String>[];
  final slash = cidr.indexOf('/');
  final base = cidr.substring(0, slash);
  final mask = int.parse(cidr.substring(slash + 1));
  if (mask != 24) return out; // для проб берём только /24
  final p = base.split('.').map(int.parse).toList();
  for (var i = 1; i < 255 && out.length < max; i++) {
    out.add('${p[0]}.${p[1]}.${p[2]}.$i');
  }
  return out;
}

Future<void> main(List<String> a) async {
  if (a.isEmpty) {
    stderr.writeln('usage: dart run tool/scan_pool_live.dart <base64-priv> [sample]');
    exit(2);
  }
  final priv = base64Decode(a[0]);
  final sample = a.length > 1 ? int.parse(a[1]) : 256;
  final rng = Random(42);
  const cidrs = [
    '162.159.192.0/24',
    '162.159.193.0/24',
    '162.159.195.0/24',
    '188.114.96.0/24',
    '188.114.97.0/24',
  ];
  final ips = <String>[];
  for (final c in cidrs) {
    ips.addAll(expandCidr(c, 60));
  }
  ips.shuffle(rng);
  final pick = ips.take(sample).map((ip) => '$ip:2408').toList();
  stdout.writeln('== pool batch: ${pick.length} адресов (порт 2408), ключ=аккаунт ==');

  final plain = await scanWgBatch(
    endpoints: pick,
    concurrency: 32,
    timeout: const Duration(seconds: 3),
  );
  final plainAlive = plain.values.where((r) => r.alive).length;
  stdout.writeln('plain wg-init : живых $plainAlive / ${plain.length}');

  final awg = await scanAwgBatch(
    endpoints: pick,
    staticPrivRaw: priv,
    concurrency: 32,
    timeout: const Duration(seconds: 3),
  );
  final awgAlive = awg.values.where((r) => r.alive).length;
  stdout.writeln('awg burst §841 : живых $awgAlive / ${awg.length}');
  for (final e in awg.entries.where((e) => e.value.alive).take(6)) {
    stdout.writeln('  ${e.key} → ${e.value.kind.name} '
        '${e.value.rttMs}мс ${e.value.detail}');
  }
  exit(0);
}
