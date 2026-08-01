import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/widgets/big_text_view.dart';

void main() {
  group('chunkTextLines', () {
    test('empty text → no chunks', () {
      expect(chunkTextLines(''), isEmpty);
    });

    test('plain lines pass through', () {
      expect(chunkTextLines('a\nbb\nccc'), ['a', 'bb', 'ccc']);
    });

    test('trailing newline does not add a phantom line', () {
      // LineSplitter: 'a\n' — одна строка.
      expect(chunkTextLines('a\n'), ['a']);
    });

    test('line exactly at the limit stays whole', () {
      final line = 'x' * 4096;
      expect(chunkTextLines(line), [line]);
    });

    test('line one char over the limit splits in two', () {
      final line = '${'x' * 4096}y';
      final chunks = chunkTextLines(line);
      expect(chunks, hasLength(2));
      expect(chunks[0], 'x' * 4096);
      expect(chunks[1], 'y');
      expect(chunks.join(), line);
    });

    test('single-line 100 KB base64 blob chunks losslessly', () {
      // §333 — undecoded тело подписки: одна строка без \n.
      final blob = 'A' * (100 * 1024);
      final chunks = chunkTextLines(blob);
      expect(chunks, hasLength((100 * 1024 / 4096).ceil()));
      expect(chunks.join(), blob);
    });

    test('custom chunk size', () {
      expect(chunkTextLines('abcdef', maxChunk: 4), ['abcd', 'ef']);
    });
  });

  group('BigTextView', () {
    testWidgets('renders visible lines of a 50k-line text', (tester) async {
      final text =
          List.generate(50000, (i) => 'line-$i payload').join('\n');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: BigTextView(text: text)),
      ));
      expect(find.text('line-0 payload'), findsOneWidget);
      // Виртуализация: хвост документа не построен.
      expect(find.text('line-49999 payload'), findsNothing);
    });

    testWidgets('sliver variant embeds into CustomScrollView', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(child: Text('header')),
              BigTextSliver(text: 'body-a\nbody-b'),
            ],
          ),
        ),
      ));
      expect(find.text('header'), findsOneWidget);
      expect(find.text('body-a'), findsOneWidget);
      expect(find.text('body-b'), findsOneWidget);
    });

    testWidgets('text swap rebuilds chunks (didUpdateWidget)', (tester) async {
      Widget build(String t) => MaterialApp(
            home: Scaffold(body: BigTextView(text: t)),
          );
      await tester.pumpWidget(build('first'));
      expect(find.text('first'), findsOneWidget);
      await tester.pumpWidget(build('second'));
      expect(find.text('first'), findsNothing);
      expect(find.text('second'), findsOneWidget);
    });
  });
}
