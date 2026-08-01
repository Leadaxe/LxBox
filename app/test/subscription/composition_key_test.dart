import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/controllers/subscription_controller.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §326 — отпечаток «состава» подписки: то и только то, от чего зависит
/// собранный конфиг. Одинаковый отпечаток ⇒ пересобирать нечего ⇒ синюю плашку
/// «Settings changed» поднимать не за что.
///
/// Причина существования: `_persist()` поднимал `configDirty` на ЛЮБУЮ запись
/// настроек, включая обновление подписки, вернувшей тот же список узлов. Плашка
/// «есть несохранённые изменения» вылезала раз в час на подписке, которая не
/// менялась (device-фидбэк 31.07.2026).

NodeSpec _node(String uri) => parseUri(uri)!;

String _key(List<NodeSpec> nodes, [Iterable<String> disabled = const []]) =>
    SubscriptionController.compositionKeyForTesting(nodes, disabled);

void main() {
  // Разные узлы: отличаются host'ом → разные identity-хеши.
  final a = _node('vless://11111111-1111-1111-1111-111111111111@a.example.com:443?type=tcp&security=tls#A');
  final b = _node('vless://22222222-2222-2222-2222-222222222222@b.example.com:443?type=tcp&security=tls#B');
  final c = _node('vless://33333333-3333-3333-3333-333333333333@c.example.com:443?type=tcp&security=tls#C');

  group('§326 состав: список узлов', () {
    test('тот же список → тот же ключ', () {
      expect(_key([a, b]), _key([a, b]));
    });

    test('РЕГРЕСС: порядок узлов ЗНАЧИМ (перестановка → другой ключ)', () {
      // От порядка зависят суффиксы allocateTag (X / X-1) и порядок внутри
      // пулов urltest/selector. Провайдер переставил узлы — это изменение,
      // конфиг соберётся другим.
      expect(_key([a, b]), isNot(_key([b, a])));
    });

    test('добавленный узел → другой ключ', () {
      expect(_key([a, b]), isNot(_key([a, b, c])));
    });

    test('удалённый узел → другой ключ', () {
      expect(_key([a, b, c]), isNot(_key([a, c])));
    });

    test('заменённый узел → другой ключ', () {
      expect(_key([a, b]), isNot(_key([a, c])));
    });

    test('пустой список ≠ непустой', () {
      expect(_key(const []), isNot(_key([a])));
    });

    test('два пустых списка равны', () {
      expect(_key(const []), _key(const []));
    });

    test('дубль узла заметен (append, а не set)', () {
      // Список узлов — не множество: два одинаковых узла дадут два outbound'а
      // (второй получит суффикс -1). Схлопывать нельзя.
      expect(_key([a]), isNot(_key([a, a])));
    });
  });

  group('§326 состав: disable-отметки (§283)', () {
    test('набор отметок ЗНАЧИМ при том же списке узлов', () {
      // Отметка меняет, что билдер эмитит, даже когда узлы те же.
      expect(_key([a, b]), isNot(_key([a, b], const ['hash-a'])));
    });

    test('порядок ключей отметок НЕ значим (сортируем)', () {
      // Map не упорядочен — порядок обхода не должен влиять на вердикт.
      expect(
        _key([a, b], const ['hash-a', 'hash-b']),
        _key([a, b], const ['hash-b', 'hash-a']),
      );
    });

    test('снятая отметка → другой ключ', () {
      expect(
        _key([a, b], const ['hash-a', 'hash-b']),
        isNot(_key([a, b], const ['hash-a'])),
      );
    });

    test('отметки без узлов и узлы без отметок различимы', () {
      expect(_key(const [], const ['hash-a']), isNot(_key([a])));
    });
  });

  group('§326 в состав НЕ входят метаданные', () {
    test('ключ зависит только от узлов и отметок', () {
      // Прямой негативный тест на утечку метаданных невозможен — они в сигнатуру
      // не передаются. Фиксируем инвариант: ключ детерминирован по двум
      // аргументам, значит last_updated / meta / name / consecutiveFails
      // повлиять на него не могут по построению.
      final first = _key([a, b], const ['hash-a']);
      final second = _key([a, b], const ['hash-a']);
      expect(first, second);
      expect(first, contains('|'), reason: 'разделитель узлы|отметки на месте');
    });

    test('разделитель не даёт коллизии между секциями', () {
      // Хеши узлов и отметок не должны «перетекать» друг в друга: одинаковая
      // конкатенация при разном распределении по секциям — разные ключи.
      expect(
        _key(const [], const ['x', 'y']),
        isNot(_key(const [], const ['x,y'])),
      );
    });
  });
}
