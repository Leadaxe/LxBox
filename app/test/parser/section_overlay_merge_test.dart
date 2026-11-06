import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';

/// Ревью после v2.25.1 (движок), m3 — `_mergeOverlay` отличает запись от
/// группы по `source` у ЛЮБОЙ стороны.
///
/// Раньше решало только отсутствие `source` у оверлея: запись оверлея без
/// `source` при одноимённой записи реестра сливалась с ней как группа, и у
/// записи молча оставались `source`/`implies` реестра — вопреки «запись
/// оверлея замещает целиком».
Map<String, dynamic> _merge(Map<String, dynamic> b, Map<String, dynamic> o) =>
    MapperSections.mergeOverlayForTest(b, o);

void main() {
  test('m3: запись оверлея без source замещает запись реестра целиком', () {
    final base = {
      'a': {
        'source': ['query.a'],
        'maps_to': 'a',
        'implies': {'b': true},
      },
    };
    final overlay = {
      'a': {
        'sets': {'x': 1},
      },
    };
    expect(_merge(base, overlay)['a'], {
      'sets': {'x': 1},
    });
  });

  test('группа по-прежнему сливается поимённо', () {
    final base = {
      'ws': {
        'path': {'source': ['query.path'], 'maps_to': 'transport.path'},
        'host': {'source': ['query.host'], 'maps_to': 'transport.headers.Host'},
      },
    };
    final overlay = {
      'ws': {
        'path': {'source': ['query.p'], 'maps_to': 'transport.path'},
      },
    };
    final ws = _merge(base, overlay)['ws'] as Map;
    expect(ws.keys, containsAll(['path', 'host']));
    expect((ws['path'] as Map)['source'], ['query.p']);
  });
}
