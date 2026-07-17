import 'package:flutter_test/flutter_test.dart';

// §279 (Phase 7) — self-test AST-скана hardcoded_check: display-позиции,
// рекурсия в ternary/switch/скобки, l10n-exempt, канонизация hash'а.
// Логика вынесена в tool/l10n/src/hardcoded_scan.dart ровно ради этого теста.
import '../../tool/l10n/src/hardcoded_scan.dart';
import '../../tool/l10n/src/sha256.dart';

List<HardcodedSite> scan(String source,
        {Map<String, DisplayHelper> helpers = const {}}) =>
    scanForHardcodedStrings(
        path: 'test.dart', content: source, helpers: helpers);

void main() {
  group('display positions', () {
    test('Text positional literal is a site', () {
      final sites = scan("final w = Text('Hello world');");
      expect(sites, hasLength(1));
      expect(sites.single.preview, 'Hello world');
    });

    test('named display args (tooltip/labelText/hintText/helperText)', () {
      final sites = scan('''
final w = IconButton(tooltip: 'Do it', onPressed: null, icon: x);
final d = InputDecoration(labelText: 'Name', hintText: 'e.g. Bob',
    helperText: 'Required');
''');
      expect(sites.map((s) => s.preview),
          unorderedEquals(['Do it', 'Name', 'e.g. Bob', 'Required']));
    });

    test('registered helper positional arg is a site, unregistered is not',
        () {
      const src = "void f() { showSnack('Saved'); mySnack('Hidden'); }";
      expect(scan(src), isEmpty);
      final sites = scan(src, helpers: {
        'showSnack': DisplayHelper({0}, {}),
      });
      expect(sites.map((s) => s.preview), ['Saved']);
    });

    test('non-display literals are ignored', () {
      expect(scan("final tag = 'vpn-1'; log('wire message');"), isEmpty);
    });

    test('letterless literals (punctuation/units) are ignored', () {
      expect(scan("final w = Text(' · '); final d = Text('—');"), isEmpty);
    });
  });

  group('ternary/switch recursion (Phase 7 hardening)', () {
    test('both ternary branches in Text are sites', () {
      final sites = scan("final w = Text(up ? 'Stop' : 'Start');");
      expect(sites.map((s) => s.preview), unorderedEquals(['Stop', 'Start']));
    });

    test('ternary in a named display arg', () {
      final sites =
          scan("final w = IconButton(tooltip: on ? 'Hide' : 'Show');");
      expect(sites.map((s) => s.preview), unorderedEquals(['Hide', 'Show']));
    });

    test('switch-expression branches in Text are sites', () {
      final sites = scan('''
final w = Text(switch (x) {
  1 => 'One thing',
  2 => 'Two things',
  _ => 'Many things',
});
''');
      expect(sites.map((s) => s.preview),
          unorderedEquals(['One thing', 'Two things', 'Many things']));
    });

    test('nested ternary and parentheses are recursed', () {
      final sites =
          scan("final w = Text(a ? (b ? 'Deep A' : 'Deep B') : 'Other');");
      expect(sites.map((s) => s.preview),
          unorderedEquals(['Deep A', 'Deep B', 'Other']));
    });

    test('ternary branches through a registered helper', () {
      final sites = scan(
        "void f() { showSnack(ok ? 'Saved it' : 'Save failed'); }",
        helpers: {'showSnack': DisplayHelper({0}, {})},
      );
      expect(sites.map((s) => s.preview),
          unorderedEquals(['Saved it', 'Save failed']));
    });

    test('ternary over non-literal expressions yields no sites', () {
      expect(scan('final w = Text(a ? x.label : y.label);'), isEmpty);
    });
  });

  group('l10n-exempt', () {
    test('same line and line above suppress the site', () {
      expect(
          scan("final w = Text('ms'); // l10n-exempt: unit label"), isEmpty);
      expect(scan('''
// l10n-exempt: wire tag
final w = Text('direct-out');
'''), isEmpty);
    });

    test('exempt applies to ternary branches on the annotated line', () {
      expect(
          scan("final w = Text(x ? 'A side' : 'B side'); // l10n-exempt: t"),
          isEmpty);
    });
  });

  group('hash canonicalization', () {
    test('interpolation is replaced positionally — rename keeps the hash', () {
      final a = scan('final w = Text("Saved \$name");').single;
      final b = scan('final w = Text("Saved \$other");').single;
      expect(a.hash, b.hash);
      expect(a.hash, sha256Hex('Saved {}').substring(0, 12));
    });

    test('adjacent strings are concatenated before hashing', () {
      final s = scan("final w = Text('Long ' 'text');").single;
      expect(s.hash, sha256Hex('Long text').substring(0, 12));
    });
  });
}
