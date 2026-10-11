// §834 — почему loadPools() падает в fallback (12 адресов) вместо asset-пула.
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/scan/scan_pool.dart';

import 'dart:convert';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('asset warp_endpoints.json читается и парсится', () async {
    String raw;
    try {
      raw = await rootBundle.loadString('assets/warp_endpoints.json');
      // ignore: avoid_print
      print('ASSET OK, длина ${raw.length}');
    } catch (e) {
      // ignore: avoid_print
      print('ASSET FAIL: $e');
      rethrow;
    }
    final pool = ScanPool.fromFullJson(jsonDecode(raw) as Map<String, dynamic>);
    // ignore: avoid_print
    print('pool null? ${pool == null}');
    if (pool != null) {
      // ignore: avoid_print
      print('wgV4Cidr=${pool.wgV4Cidr}');
      // ignore: avoid_print
      print('wgPorts=${pool.wgPorts}');
      // ignore: avoid_print
      print('masqueH3Hosts=${pool.masqueH3Hosts}');
      // ignore: avoid_print
      print('masqueV4Cidr=${pool.masqueV4Cidr}');
      // ignore: avoid_print
      print('hasData=${pool.hasData}');
    }
  });
}
