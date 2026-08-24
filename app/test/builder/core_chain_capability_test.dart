import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/builder/core_chain_capability.dart';

// §393 C5 — гейт поддержки цепочек по версии ядра.
//
// Ядро без `with_lx_chain` отвергает конфиг ЦЕЛИКОМ на неизвестном типе
// outbound'а, то есть одна цепочка оставила бы пользователя вообще без VPN.
// На мобиле список тегов сборки libbox наружу не отдаёт — единственный шов
// это `Libbox.version()`, и сравнивать версии строкой нельзя (лексикографика
// ставит `rc.10` перед `rc.5`).

void main() {
  group('CoreVersion.parse', () {
    test('релиз форка с rc', () {
      final v = CoreVersion.parse('1.14.0-lx.27-rc.6')!;
      expect(v.major, 1);
      expect(v.minor, 14);
      expect(v.patch, 0);
      expect(v.lx, 27);
      expect(v.rc, 6);
      expect(v.toString(), '1.14.0-lx.27-rc.6');
    });

    test('финальный релиз форка (без rc)', () {
      expect(CoreVersion.parse('1.14.0-lx.27')!.rc, isNull);
    });

    test('ведущий v тега репозитория снимается', () {
      expect(CoreVersion.parse('v1.14.0-lx.27-rc.5')!.lx, 27);
    });

    test('сборка не с тега (хвост -g<hash>) читается по номеру rc', () {
      // `build_shared/tag.go` дописывает короткий хеш коммита. Хвост значит
      // «после этого rc», а не «до», поэтому игнорируется.
      final v = CoreVersion.parse('1.14.0-lx.27-rc.5-g1a2b3c4')!;
      expect(v.rc, 5);
    });

    test('апстрим и мусор не разбираются', () {
      expect(CoreVersion.parse('1.13.11'), isNull);
      expect(CoreVersion.parse(''), isNull);
      expect(CoreVersion.parse('unknown'), isNull);
      expect(CoreVersion.parse('lx.27'), isNull);
    });
  });

  group('CoreVersion.compareTo', () {
    test('rc сравниваются ЧИСЛАМИ, а не строками', () {
      // Ровно та ошибка, ради которой гейт не сравнивает строки:
      // 'rc.10'.compareTo('rc.5') < 0.
      final ten = CoreVersion.parse('1.14.0-lx.27-rc.10')!;
      final five = CoreVersion.parse('1.14.0-lx.27-rc.5')!;
      expect(ten.compareTo(five), greaterThan(0));
    });

    test('финальный релиз старше любого своего rc', () {
      final rel = CoreVersion.parse('1.14.0-lx.27')!;
      final rc99 = CoreVersion.parse('1.14.0-lx.27-rc.99')!;
      expect(rel.compareTo(rc99), greaterThan(0));
    });

    test('старшинство по осям: major → minor → patch → lx → rc', () {
      int cmp(String a, String b) =>
          CoreVersion.parse(a)!.compareTo(CoreVersion.parse(b)!);
      expect(cmp('2.0.0-lx.1', '1.99.99-lx.99'), greaterThan(0));
      expect(cmp('1.15.0-lx.1', '1.14.9-lx.99'), greaterThan(0));
      expect(cmp('1.14.1-lx.1', '1.14.0-lx.99'), greaterThan(0));
      expect(cmp('1.14.0-lx.28-rc.1', '1.14.0-lx.27'), greaterThan(0));
      expect(cmp('1.14.0-lx.27-rc.6', '1.14.0-lx.27-rc.6'), 0);
    });
  });

  group('coreSupportsChain', () {
    test('ядро НОВЕЕ порога — цепочки эмитятся', () {
      expect(coreSupportsChain('1.14.0-lx.27-rc.6'), isTrue);
      expect(coreSupportsChain('1.14.0-lx.28'), isTrue);
      expect(coreSupportsChain('2.0.0-lx.1'), isTrue);
    });

    test('ровно порог — поддержка есть (тег вошёл в AAR именно в rc.5)', () {
      expect(coreSupportsChain(kChainMinCoreVersion), isTrue);
      expect(coreSupportsChain('1.14.0-lx.27-rc.5'), isTrue);
    });

    test('ядро СТАРШЕ порога — цепочки не эмитятся', () {
      expect(coreSupportsChain('1.14.0-lx.27-rc.4'), isFalse);
      expect(coreSupportsChain('1.14.0-lx.26'), isFalse);
      expect(coreSupportsChain('1.13.11-lx.1'), isFalse);
    });

    test('кривая / пустая / апстримная строка — FAIL-OPEN', () {
      // Деградировать на догадке нельзя: это отняло бы у пользователя
      // рабочий маршрут, а отвергнутый ядром конфиг он хотя бы увидит
      // ошибкой старта.
      expect(coreSupportsChain(''), isTrue);
      expect(coreSupportsChain('   '), isTrue);
      expect(coreSupportsChain('unknown'), isTrue);
      expect(coreSupportsChain('1.13.11'), isTrue); // апстрим без -lx.N
      expect(coreSupportsChain('lx.27-rc.5'), isTrue);
    });
  });

  group('chainUnsupportedByCoreLine', () {
    test('называет версию ядра и порог — иначе следующий шаг не сделать', () {
      final line = chainUnsupportedByCoreLine('via-de', '1.14.0-lx.27-rc.4');
      expect(line, contains('via-de'));
      expect(line, contains('1.14.0-lx.27-rc.4'));
      expect(line, contains(kChainMinCoreVersion));
    });

    test('пустая версия не превращается в пустые скобки', () {
      expect(chainUnsupportedByCoreLine('c', ''), contains('unknown version'));
    });
  });

  group('CoreVersionCache', () {
    setUp(CoreVersionCache.resetForTest);

    test('спрашивает ядро один раз за сессию', () async {
      var calls = 0;
      Future<String> read() async {
        calls++;
        return '1.14.0-lx.27-rc.6';
      }

      expect(await CoreVersionCache.ensure(read), '1.14.0-lx.27-rc.6');
      expect(await CoreVersionCache.ensure(read), '1.14.0-lx.27-rc.6');
      expect(calls, 1);
    });

    test('пустой ответ НЕ кэшируется — следующая сборка спросит снова',
        () async {
      // Пусто значит «ядро не ответило», а не «версии нет». Закэшировав его,
      // мы бы навсегда зафиксировали fail-open вердикт по сорванному вызову.
      var calls = 0;
      Future<String> read() async {
        calls++;
        return calls == 1 ? '' : '1.14.0-lx.27-rc.6';
      }

      expect(await CoreVersionCache.ensure(read), '');
      expect(await CoreVersionCache.ensure(read), '1.14.0-lx.27-rc.6');
      expect(calls, 2);
    });

    test('исключение канала гасится в пустую строку (fail-open)', () async {
      expect(
          await CoreVersionCache.ensure(() async => throw StateError('no core')),
          '');
      expect(coreSupportsChain(CoreVersionCache.value), isTrue);
    });
  });
}
