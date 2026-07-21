import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/import_rule.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/subscription/import_rules.dart';

/// §302 — pure applyImportRules: REPLACE + DISABLE-пометка + origin-карта.

UriLines _uri(List<String> lines) => UriLines(lines, 0);

ImportRule _replace(String pattern, String replacement,
        {bool isRegex = false, bool caseSensitive = false, bool enabled = true}) =>
    ImportRule(
      action: ImportRuleAction.replace,
      pattern: pattern,
      replacement: replacement,
      isRegex: isRegex,
      caseSensitive: caseSensitive,
      enabled: enabled,
    );

ImportRule _disable(String pattern,
        {bool isRegex = true, bool caseSensitive = false}) =>
    ImportRule(
      action: ImportRuleAction.disable,
      pattern: pattern,
      isRegex: isRegex,
      caseSensitive: caseSensitive,
    );

List<String> _lines(ImportRulesResult r) => (r.body as UriLines).lines;

void main() {
  group('applyImportRules — пустой/no-op', () {
    test('пустой список правил → тело как есть, сеты пусты', () {
      final input = _uri(['vless://a@h:443#N1', 'vless://b@h:443#N2']);
      final r = applyImportRules(input, const []);
      expect(_lines(r), ['vless://a@h:443#N1', 'vless://b@h:443#N2']);
      expect(r.disabledLines, isEmpty);
      expect(r.originByRewritten, isEmpty);
    });

    test('выключенное правило пропускается', () {
      final input = _uri(['vless://a@h:443?fp=hellochrome_120#N1']);
      final r = applyImportRules(
          input, [_replace('hellochrome_120', 'chrome', enabled: false)]);
      expect(_lines(r), ['vless://a@h:443?fp=hellochrome_120#N1']);
      expect(r.originByRewritten, isEmpty);
    });
  });

  group('REPLACE', () {
    test('literal — все вхождения в строке', () {
      final input = _uri(['a=x&b=x&c=y']);
      final r = applyImportRules(input, [_replace('x', 'Z')]);
      expect(_lines(r), ['a=Z&b=Z&c=y']);
    });

    test('regex fingerprint hellochrome_120 → chrome', () {
      final input = _uri(['vless://a@h:443?fp=hellochrome_120#NL']);
      final r = applyImportRules(
          input, [_replace(r'hellochrome_\d+', 'chrome', isRegex: true)]);
      expect(_lines(r).single, 'vless://a@h:443?fp=chrome#NL');
    });

    test('пустая замена вырезает фрагмент (&type=raw → "")', () {
      final input = _uri(['vless://a@h:443?type=tcp&type=raw#N']);
      final r = applyImportRules(input, [_replace('&type=raw', '')]);
      expect(_lines(r).single, 'vless://a@h:443?type=tcp#N');
    });

    test('caseSensitive=false матчит любой регистр (дефолт §301)', () {
      final input = _uri(['HELLOChrome_120']);
      final r = applyImportRules(
          input, [_replace('hellochrome_120', 'chrome')]);
      expect(_lines(r).single, 'chrome');
    });

    test('caseSensitive=true не матчит другой регистр', () {
      final input = _uri(['HELLOChrome_120']);
      final r = applyImportRules(
          input, [_replace('hellochrome_120', 'chrome', caseSensitive: true)]);
      expect(_lines(r).single, 'HELLOChrome_120');
    });

    test('порядок: второе правило видит результат первого', () {
      final input = _uri(['aaa']);
      final r = applyImportRules(
          input, [_replace('aaa', 'bbb'), _replace('bbb', 'ccc')]);
      expect(_lines(r).single, 'ccc');
    });

    test('битый regex скипается, остальные применяются', () {
      final input = _uri(['fooBAR']);
      final r = applyImportRules(input, [
        _replace('(unclosed', 'X', isRegex: true), // невалидный → скип
        _replace('BAR', 'baz'),
      ]);
      expect(_lines(r).single, 'foobaz');
    });
  });

  group('origin-карта', () {
    test('изменённая строка → карта послезаменная→оригинал', () {
      final input = _uri([
        'vless://a@h:443?fp=hellochrome_120#NL', // изменится
        'vless://b@h:443#US', // не тронута
      ]);
      final r = applyImportRules(
          input, [_replace('hellochrome_120', 'chrome')]);
      expect(r.originByRewritten, {
        'vless://a@h:443?fp=chrome#NL':
            'vless://a@h:443?fp=hellochrome_120#NL',
      });
      // Нетронутая строка в карту не попадает.
      expect(r.originByRewritten.containsValue('vless://b@h:443#US'), isFalse);
    });
  });

  group('DISABLE', () {
    test('помечает совпавшую строку, НЕ удаляет её из тела', () {
      final input = _uri([
        'vless://a@h:443#US-NewYork',
        'vless://b@h:443#NL-Amsterdam',
      ]);
      final r = applyImportRules(input, [_disable(r'.*Netherlands.*')]);
      // Netherlands в имени нет → не совпало.
      expect(r.disabledLines, isEmpty);

      final r2 = applyImportRules(input, [_disable(r'.*NL-.*')]);
      expect(_lines(r2).length, 2, reason: 'строка остаётся в теле');
      expect(r2.disabledLines, {'vless://b@h:443#NL-Amsterdam'});
    });

    test('disable матчит ПОСЛЕзаменную строку', () {
      // replace переименовывает в Netherlands, потом disable по нему.
      final input = _uri(['vless://b@h:443#NL']);
      final r = applyImportRules(input, [
        _replace('#NL', '#Netherlands'),
        _disable(r'.*Netherlands.*'),
      ]);
      expect(_lines(r).single, 'vless://b@h:443#Netherlands');
      expect(r.disabledLines, {'vless://b@h:443#Netherlands'});
    });

    test('caseSensitive disable (дефолт false матчит любой регистр)', () {
      final input = _uri(['vless://b@h:443#netherlands']);
      final r = applyImportRules(input, [_disable(r'.*Netherlands.*')]);
      expect(r.disabledLines, {'vless://b@h:443#netherlands'});
    });
  });

  group('не-URI тела', () {
    test('INI: REPLACE работает по тексту, disable неприменим', () {
      const ini = '[Interface]\nMTU = 1280\n[Peer]\nEndpoint = h:51820';
      final r = applyImportRules(
          IniConfig(ini), [_replace('1280', '1420')]);
      expect((r.body as IniConfig).text, contains('MTU = 1420'));
      expect(r.disabledLines, isEmpty);
    });

    test('INI: disable-правило не помечает ничего (нет строки-ноды)', () {
      const ini = '[Interface]\n# Netherlands\n[Peer]\nEndpoint = h:51820';
      final r = applyImportRules(
          IniConfig(ini), [_disable(r'.*Netherlands.*')]);
      expect(r.disabledLines, isEmpty);
    });

    test('JSON: тело не трогается (ноды — элементы, не строки)', () {
      final json = JsonConfig(
          [<String, dynamic>{'type': 'vless'}], JsonFlavor.unknown);
      final r = applyImportRules(json, [_replace('vless', 'trojan')]);
      expect(identical(r.body, json), isTrue);
    });
  });
}
