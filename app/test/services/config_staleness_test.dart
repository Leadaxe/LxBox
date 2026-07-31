import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/config_staleness.dart';
import 'package:lxbox/services/platform_channels.dart';

/// §324 — зеркало `OverrideOptions` и сравнение канонических форм.
///
/// Зеркало обязано повторять `BoxService.buildOverrideOptions` (Kotlin) и
/// `daemon/instance.go:92-101` (Go) с точностью до порядка элементов: сравнение
/// побайтовое, поэтому `append` vs `merge` и «первый tun» vs «все tun» —
/// не стилистика, а корректность.

Map<String, dynamic> _decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Map<String, dynamic>? _firstTun(String json) {
  final inbounds = _decode(json)['inbounds'];
  if (inbounds is! List) return null;
  for (final i in inbounds) {
    if (i is Map<String, dynamic> && i['type'] == 'tun') return i;
  }
  return null;
}

/// Конфиг с одним tun-inbound. [includePackage]/[excludePackage] — как их
/// положил бы §046 post-step (`applyTunPackages`).
String _config({
  List<String>? includePackage,
  List<String>? excludePackage,
  bool? autoRedirect,
  int tunCount = 1,
  bool withTun = true,
}) {
  final tuns = [
    for (var i = 0; i < tunCount; i++)
      <String, dynamic>{
        'type': 'tun',
        'tag': 'tun-in-$i',
        if (includePackage != null) 'include_package': includePackage,
        if (excludePackage != null) 'exclude_package': excludePackage,
        if (autoRedirect != null) 'auto_redirect': autoRedirect,
      },
  ];
  return jsonEncode({
    'inbounds': [
      {'type': 'mixed', 'tag': 'mixed-in'},
      if (withTun) ...tuns,
    ],
    'outbounds': [
      {'type': 'direct', 'tag': 'direct'},
    ],
  });
}

void main() {
  const self = PlatformChannels.packageName;

  group('§324 applyOverrides — allow-режим', () {
    test('свой пакет дописан В КОНЕЦ include_package (append, не merge)', () {
      final out = applyOverrides(
        _config(includePackage: ['com.a', 'com.b']),
        const OverrideSnapshot(includeSelfPackage: true),
      );
      // Порядок значим для байтового сравнения: ядро делает append, значит
      // пакеты профиля остаются первыми, свой — последним.
      expect(_firstTun(out)!['include_package'], ['com.a', 'com.b', self]);
    });

    test('не сортирует и не дедуплицирует', () {
      // Ядро — тупой append. Если пакет уже есть, он появится дважды; наша
      // задача повторить это, а не «исправить».
      final out = applyOverrides(
        _config(includePackage: ['com.z', self, 'com.a']),
        const OverrideSnapshot(includeSelfPackage: true),
      );
      expect(_firstTun(out)!['include_package'], ['com.z', self, 'com.a', self]);
    });

    test('include_package строкой (Listable с одним элементом) → список', () {
      // Ядро сериализует одноэлементный Listable голой строкой; на входе она
      // тоже может встретиться. Разворачиваем, чтобы append не склеил строки.
      final out = applyOverrides(
        _config().replaceFirst('"tag":"tun-in-0"',
            '"tag":"tun-in-0","include_package":"com.only"'),
        const OverrideSnapshot(includeSelfPackage: true),
      );
      expect(_firstTun(out)!['include_package'], ['com.only', self]);
    });
  });

  group('§324 applyOverrides — deny-режим и его отсутствие', () {
    test('deny (exclude_package) → свой пакет НЕ дописан', () {
      // §124: include + exclude в одном tun → Android бросает
      // UnsupportedOperationException. Native в deny свой пакет не добавляет.
      final out = applyOverrides(
        _config(excludePackage: ['com.a']),
        const OverrideSnapshot(includeSelfPackage: true),
      );
      final tun = _firstTun(out)!;
      expect(tun.containsKey('include_package'), isFalse);
      expect(tun['exclude_package'], ['com.a']);
    });

    test('режим off (нет ни include, ни exclude) → свой пакет НЕ дописан', () {
      final out = applyOverrides(
        _config(),
        const OverrideSnapshot(includeSelfPackage: true),
      );
      expect(_firstTun(out)!.containsKey('include_package'), isFalse);
    });

    test('includeSelfPackage=false → не дописан даже в allow', () {
      final out = applyOverrides(
        _config(includePackage: ['com.a']),
        const OverrideSnapshot(includeSelfPackage: false),
      );
      expect(_firstTun(out)!['include_package'], ['com.a']);
    });
  });

  group('§324 applyOverrides — auto_redirect', () {
    test('присваивается, а не мержится: true перетирает false профиля', () {
      final out = applyOverrides(
        _config(autoRedirect: false),
        const OverrideSnapshot(autoRedirect: true),
      );
      expect(_firstTun(out)!['auto_redirect'], isTrue);
    });

    test('РЕГРЕСС: false перетирает true профиля (ядро пишет безусловно)', () {
      // Ядро делает присваивание, а не `||`. Если пропустить запись при false,
      // профиль с auto_redirect:true даст расхождение с running.
      final out = applyOverrides(
        _config(autoRedirect: true),
        const OverrideSnapshot(autoRedirect: false),
      );
      expect(_firstTun(out)!['auto_redirect'], isFalse);
    });

    test('пишется, даже если в профиле ключа не было', () {
      final out = applyOverrides(
        _config(),
        const OverrideSnapshot(autoRedirect: true),
      );
      expect(_firstTun(out)!['auto_redirect'], isTrue);
    });
  });

  group('§324 applyOverrides — границы (грабли 1 и 4)', () {
    test('грабля 1: тронут только ПЕРВЫЙ tun-inbound', () {
      final out = applyOverrides(
        _config(includePackage: ['com.a'], tunCount: 2),
        const OverrideSnapshot(includeSelfPackage: true, autoRedirect: true),
      );
      final inbounds = _decode(out)['inbounds'] as List;
      final tuns =
          inbounds.whereType<Map<String, dynamic>>().where((i) => i['type'] == 'tun').toList();
      expect(tuns.length, 2);
      expect(tuns[0]['include_package'], ['com.a', self],
          reason: 'первый tun — тронут');
      expect(tuns[1]['include_package'], ['com.a'],
          reason: 'второй tun — НЕ тронут (в цикле ядра стоит break)');
      expect(tuns[1].containsKey('auto_redirect'), isFalse);
    });

    test('грабля 4: нет tun-inbound → конфиг не тронут вовсе', () {
      final src = _config(withTun: false);
      final out = applyOverrides(
        src,
        const OverrideSnapshot(includeSelfPackage: true, autoRedirect: true),
      );
      expect(out, src);
    });

    test('нет секции inbounds → конфиг не тронут', () {
      const src = '{"outbounds":[{"type":"direct","tag":"direct"}]}';
      expect(
        applyOverrides(src, const OverrideSnapshot(autoRedirect: true)),
        src,
      );
    });

    test('невалидный JSON → возвращаем как есть (решает formatConfig)', () {
      const src = 'not a json at all';
      expect(applyOverrides(src, const OverrideSnapshot()), src);
    });

    test('вход не мутируется', () {
      final src = _config(includePackage: ['com.a']);
      final before = jsonEncode(_decode(src));
      applyOverrides(src, const OverrideSnapshot(includeSelfPackage: true));
      expect(jsonEncode(_decode(src)), before);
    });
  });

  group('§324 инвариант: список зеркалимых полей', () {
    test('совпадает с buildOverrideOptions (Kotlin)', () {
      // Инвариант §324 (по образцу §221): OverrideOptions имеет ТРИ поля, но
      // native заполняет только два. Появилась третья докрутка в
      // buildOverrideOptions — обязана появиться и здесь, иначе компаратор
      // молча начнёт врать.
      //
      // exclude_package НЕ зеркалим осознанно: native не заполняет его никогда
      // (в deny-режиме пакеты кладёт §046 post-step в сам конфиг, а не
      // override).
      expect(OverrideSnapshot.mirroredFields,
          {'auto_redirect', 'include_package'});
    });
  });

  group('§324 compareCanonical', () {
    test('формы совпали → fresh', () {
      expect(
        compareCanonical(canonicalSaved: '{"a":1}', runningSnapshot: '{"a":1}'),
        StalenessVerdict.fresh,
      );
    });

    test('формы разошлись → stale', () {
      expect(
        compareCanonical(canonicalSaved: '{"a":1}', runningSnapshot: '{"a":2}'),
        StalenessVerdict.stale,
      );
    });

    test('нет канонической формы → unknown (НЕ fresh)', () {
      // Критично: на сбое ядра плашка не должна молча исчезнуть.
      expect(
        compareCanonical(canonicalSaved: null, runningSnapshot: '{"a":1}'),
        StalenessVerdict.unknown,
      );
      expect(
        compareCanonical(canonicalSaved: '', runningSnapshot: '{"a":1}'),
        StalenessVerdict.unknown,
      );
    });

    test('нет снапшота работающего → unknown', () {
      // Туннель up, но снапшота нет: старое ядро, attached-путь, окно между
      // connected и захватом (§311).
      expect(
        compareCanonical(canonicalSaved: '{"a":1}', runningSnapshot: null),
        StalenessVerdict.unknown,
      );
      expect(
        compareCanonical(canonicalSaved: '{"a":1}', runningSnapshot: ''),
        StalenessVerdict.unknown,
      );
    });

    test('оба null → unknown', () {
      expect(
        compareCanonical(canonicalSaved: null, runningSnapshot: null),
        StalenessVerdict.unknown,
      );
    });
  });
}
