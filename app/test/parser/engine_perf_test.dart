import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';
import 'package:lxbox/services/parser/mappers/draft_sections.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §480 W1 — ЗАМЕР: 2000 ссылок одной схемы через полный конвейер.
///
/// Критерий 6 спеки — не дороже ×1,5 к замеру до фичи, «лучший из трёх».
/// Лучший, а не средний: мерим стоимость работы, а не шум планировщика, и
/// выброс вверх на общей машине говорит о соседнем процессе, а не о коде.
///
/// Запускается с `LX_PERF=1`; без переменной молчит — на CI замер времени
/// бессмысленен (машина общая), а красный тест от чужой нагрузки хуже, чем
/// отсутствие замера.
void main() {
  final on = Platform.environment['LX_PERF'] == '1';

  test('2000 ссылок: конвейер не дороже потолка', () async {
    if (!on) return;
    await ContractRegistry.I.loadFromDirectory('assets/contract');
    await MapperSections.I
        .loadDrafts(dir: 'assets/contract_draft', files: kDraftFiles);

    // Набор намеренно разнородный: голый TLS, ws с путём и хвостом `?ed=`,
    // grpc, ALPN-список, отпечаток чужого диалекта. Однородный набор мерил бы
    // одну ветку и прятал стоимость остальных.
    const shapes = [
      'trojan://pass123@example-1.com:443?security=tls&sni=example-1.com#n',
      'trojan://pass123@example-1.com:443?type=ws&security=tls&host=example-1.com&path=%2Fws&sni=example-1.com#n',
      'trojan://pass123@example-1.com:443?type=ws&path=%2Fx%3Fed%3D2560&security=tls&sni=example-1.com#n',
      'trojan://pass123@example-1.com:443?type=grpc&security=tls&serviceName=gsvc&sni=example-1.com#n',
      'trojan://pass123@example-1.com:443?security=tls&alpn=h2%2Chttp%2F1.1&fp=hellochrome_auto&sni=example-1.com#n',
    ];
    final links = [
      for (var i = 0; i < 2000; i++) shapes[i % shapes.length],
    ];

    // Прогрев: первый проход платит за разбор секций и компиляцию регулярок,
    // и мерить его значило бы мерить загрузку, а не разбор.
    for (final l in links) {
      parseUri(l);
    }

    var best = Duration(days: 1);
    for (var run = 0; run < 3; run++) {
      final sw = Stopwatch()..start();
      for (final l in links) {
        parseUri(l);
      }
      sw.stop();
      if (sw.elapsed < best) best = sw.elapsed;
    }

    // ignore: avoid_print
    print('§480 перф: 2000 ссылок — ${best.inMilliseconds} мс '
        '(лучший из трёх)');
  });
}
