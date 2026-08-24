import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/screens/chain_edit/chain_form_validation.dart';
import 'package:lxbox/screens/chain_edit/chain_hop_candidate.dart';

// §393 C6 — валидация формы цепочки. ФОРМА — ЕДИНСТВЕННЫЙ РУБЕЖ (§393 L4):
// `sing-box check` ошибки старта не ловит, ядро отвергает конфиг ЦЕЛИКОМ, и
// пользователь остаётся без VPN, а не без одного маршрута.
//
// Тесты сверяют КОДЫ и УРОВНИ находок, не тексты: подпись меняется, инвариант
// нет (AGENTS.md — тестов на формат UI-строк не писать).

ChainHopCandidate _node(String tag,
        {bool reality = false, bool detour = false}) =>
    ChainHopCandidate(
        tag: tag,
        kind: ChainHopKind.node,
        reality: reality,
        detour: detour,
        outboundType: 'vless');

ChainHopCandidate _chain(String tag, {bool below = false}) =>
    ChainHopCandidate(tag: tag, kind: ChainHopKind.chain, below: below);

ChainFormContext _ctx(
  List<ChainHopCandidate> cands, {
  bool targetsKnown = true,
  Set<String> taken = const {},
  String originalTag = 'via-de',
}) =>
    ChainFormContext(
      candidates: chainHopLookup(cands),
      targetsKnown: targetsKnown,
      takenTags: taken,
      originalTag: originalTag,
    );

Set<ChainIssueCode> _codes(List<ChainFormIssue> issues) =>
    issues.map((i) => i.code).toSet();

ChainFormIssue? _find(List<ChainFormIssue> issues, ChainIssueCode code) {
  for (final i in issues) {
    if (i.code == code) return i;
  }
  return null;
}

void main() {
  group('здоровая цепочка', () {
    test('две живые позиции — ни находок, ни запрета на сохранение', () {
      final issues = validateChainForm(
        const ChainFormState(tag: 'via-de', hops: ['home', 'de-exit']),
        _ctx([_node('home'), _node('de-exit')]),
      );
      expect(issues, isEmpty);
      expect(chainFormCanSave(issues), isTrue);
    });
  });

  group('инварианты ядра — блокирующие', () {
    test('одна позиция: ядро односкачковую цепочку отвергает', () {
      final issues = validateChainForm(
        const ChainFormState(tag: 'via-de', hops: ['home']),
        _ctx([_node('home')]),
      );
      expect(_codes(issues), contains(ChainIssueCode.tooFewHops));
      expect(_find(issues, ChainIssueCode.tooFewHops)!.level,
          ChainIssueLevel.blocking);
      expect(chainFormCanSave(issues), isFalse);
    });

    test('пустой список позиций — тот же инвариант', () {
      final issues = validateChainForm(
        const ChainFormState(tag: 'via-de', hops: []),
        _ctx(const []),
      );
      expect(_codes(issues), contains(ChainIssueCode.tooFewHops));
      expect(chainFormCanSave(issues), isFalse);
    });

    test('пустая позиция блокирует (приезжает из restore, формой не набрать)',
        () {
      final issues = validateChainForm(
        const ChainFormState(tag: 'via-de', hops: ['home', '  ']),
        _ctx([_node('home')]),
      );
      expect(_codes(issues), contains(ChainIssueCode.emptyHop));
      expect(chainFormCanSave(issues), isFalse);
    });

    test('дубль позиции блокирует и называет повторившийся тег', () {
      final issues = validateChainForm(
        const ChainFormState(tag: 'via-de', hops: ['home', 'de', 'home']),
        _ctx([_node('home'), _node('de')]),
      );
      final dup = _find(issues, ChainIssueCode.duplicateHop);
      expect(dup, isNotNull);
      expect(dup!.level, ChainIssueLevel.blocking);
      expect(dup.hops, ['home']);
      expect(chainFormCanSave(issues), isFalse);
    });

    test('самоссылка блокирует отдельным кодом, а не «дублем»', () {
      final issues = validateChainForm(
        const ChainFormState(tag: 'via-de', hops: ['home', 'via-de']),
        _ctx([_node('home')]),
      );
      expect(_codes(issues), contains(ChainIssueCode.selfReference));
      expect(_find(issues, ChainIssueCode.selfReference)!.level,
          ChainIssueLevel.blocking);
      expect(chainFormCanSave(issues), isFalse);
    });

    test('вложенная цепочка позицией 0 законна', () {
      // Звено — это «узел через предыдущую позицию»; первая позиция звеном не
      // является, и цепочка там пересобираться не должна.
      final issues = validateChainForm(
        const ChainFormState(tag: 'outer', hops: ['inner', 'de-exit']),
        _ctx([_chain('inner'), _node('de-exit')], originalTag: 'outer'),
      );
      expect(_codes(issues), isNot(contains(ChainIssueCode.nestedNotFirst)));
      expect(chainFormCanSave(issues), isTrue);
    });

    test('вложенная цепочка позицией ≥1 блокирует (check это НЕ ловит)', () {
      final issues = validateChainForm(
        const ChainFormState(tag: 'outer', hops: ['home', 'inner']),
        _ctx([_node('home'), _chain('inner')], originalTag: 'outer'),
      );
      final nested = _find(issues, ChainIssueCode.nestedNotFirst);
      expect(nested, isNotNull);
      expect(nested!.level, ChainIssueLevel.blocking);
      expect(nested.hops, ['inner']);
      expect(chainFormCanSave(issues), isFalse);
    });

    test('ссылка на цепочку НИЖЕ по списку блокирует (циклы исключены порядком)',
        () {
      final issues = validateChainForm(
        const ChainFormState(tag: 'outer', hops: ['later', 'de-exit']),
        _ctx([_chain('later', below: true), _node('de-exit')],
            originalTag: 'outer'),
      );
      final fwd = _find(issues, ChainIssueCode.forwardChainReference);
      expect(fwd, isNotNull);
      expect(fwd!.level, ChainIssueLevel.blocking);
      expect(fwd.hops, ['later']);
      expect(chainFormCanSave(issues), isFalse);
    });

    test('цепочка ВЫШЕ по списку — законная позиция', () {
      final issues = validateChainForm(
        const ChainFormState(tag: 'outer', hops: ['earlier', 'de-exit']),
        _ctx([_chain('earlier'), _node('de-exit')], originalTag: 'outer'),
      );
      expect(_codes(issues),
          isNot(contains(ChainIssueCode.forwardChainReference)));
      expect(chainFormCanSave(issues), isTrue);
    });
  });

  group('reality + strip tls.utls (T4) — ядро падает на старте', () {
    test('снятый utls на reality-ЗВЕНЕ блокирует', () {
      final issues = validateChainForm(
        const ChainFormState(
          tag: 'via-de',
          hops: ['home', 'de-reality'],
          strip: {kChainStripTlsUtls: true},
        ),
        _ctx([_node('home'), _node('de-reality', reality: true)]),
      );
      final bad = _find(issues, ChainIssueCode.realityUtlsStripped);
      expect(bad, isNotNull);
      expect(bad!.level, ChainIssueLevel.blocking);
      expect(bad.hops, ['de-reality']);
      expect(chainFormCanSave(issues), isFalse);
    });

    test('reality на позиции 0 конфликтом не является: strip применяется к звеньям',
        () {
      final issues = validateChainForm(
        const ChainFormState(
          tag: 'via-de',
          hops: ['home-reality', 'de-exit'],
          strip: {kChainStripTlsUtls: true},
        ),
        _ctx([_node('home-reality', reality: true), _node('de-exit')]),
      );
      expect(_codes(issues),
          isNot(contains(ChainIssueCode.realityUtlsStripped)));
    });

    test('utls по умолчанию НЕ снимается — конфликта нет', () {
      // Каталог ядра: tls.utls единственный, который strip_evasion не трогает.
      final issues = validateChainForm(
        const ChainFormState(tag: 'via-de', hops: ['home', 'de-reality']),
        _ctx([_node('home'), _node('de-reality', reality: true)]),
      );
      expect(_codes(issues),
          isNot(contains(ChainIssueCode.realityUtlsStripped)));
      expect(chainFormCanSave(issues), isTrue);
    });

    test('явно снятая галка утls перевешивает выключенный strip_evasion', () {
      // Точечный патч старше общего тумблера — та же лестница, что в ядре.
      final issues = validateChainForm(
        const ChainFormState(
          tag: 'via-de',
          hops: ['home', 'de-reality'],
          stripEvasion: false,
          strip: {kChainStripTlsUtls: true},
        ),
        _ctx([_node('home'), _node('de-reality', reality: true)]),
      );
      expect(_codes(issues), contains(ChainIssueCode.realityUtlsStripped));
    });

    test('явно оставленный utls при strip_evasion — конфликта нет', () {
      final issues = validateChainForm(
        const ChainFormState(
          tag: 'via-de',
          hops: ['home', 'de-reality'],
          strip: {kChainStripTlsUtls: false},
        ),
        _ctx([_node('home'), _node('de-reality', reality: true)]),
      );
      expect(_codes(issues),
          isNot(contains(ChainIssueCode.realityUtlsStripped)));
    });
  });

  group('detour (T7) — зависит от позиции', () {
    test('детур позиции 0 — ПРЕДУПРЕЖДЕНИЕ, сохранять не мешает', () {
      // Узел идёт в сеть как есть, вместе со своим детуром: реальный путь
      // ДЛИННЕЕ показанного. Это работает, и запрещать нечего.
      final issues = validateChainForm(
        const ChainFormState(tag: 'via-de', hops: ['home', 'de-exit']),
        _ctx([_node('home', detour: true), _node('de-exit')]),
      );
      final w = _find(issues, ChainIssueCode.detourAtEntry);
      expect(w, isNotNull);
      expect(w!.level, ChainIssueLevel.warning);
      expect(w.blocks, isFalse);
      expect(chainFormCanSave(issues), isTrue);
    });

    test('детур позиций ≥1 — СПРАВКА: ядро перезапишет его безусловно', () {
      final issues = validateChainForm(
        const ChainFormState(tag: 'via-de', hops: ['home', 'de-exit']),
        _ctx([_node('home'), _node('de-exit', detour: true)]),
      );
      final n = _find(issues, ChainIssueCode.detourIgnoredOnLink);
      expect(n, isNotNull);
      expect(n!.level, ChainIssueLevel.info);
      expect(n.hops, ['de-exit']);
      expect(chainFormCanSave(issues), isTrue);
    });

    test('детур и на входе, и на звене — две РАЗНЫЕ находки', () {
      // Сказать про обе одно и то же значило бы соврать про одну из них.
      final issues = validateChainForm(
        const ChainFormState(tag: 'via-de', hops: ['home', 'de-exit']),
        _ctx([_node('home', detour: true), _node('de-exit', detour: true)]),
      );
      expect(_codes(issues), containsAll([
        ChainIssueCode.detourAtEntry,
        ChainIssueCode.detourIgnoredOnLink,
      ]));
      expect(chainFormCanSave(issues), isTrue);
    });
  });

  group('потерянные позиции', () {
    test('исчезнувший тег — предупреждение с перечнем, сохранять не мешает', () {
      // Запереть форму значило бы не дать починить ровно ту цепочку, которую
      // пользователь пришёл чинить.
      final issues = validateChainForm(
        const ChainFormState(tag: 'via-de', hops: ['home', 'gone', 'de-exit']),
        _ctx([_node('home'), _node('de-exit')]),
      );
      final m = _find(issues, ChainIssueCode.missingHops);
      expect(m, isNotNull);
      expect(m!.level, ChainIssueLevel.warning);
      expect(m.hops, ['gone']);
      expect(chainFormCanSave(issues), isTrue);
    });

    test('снимок целей не готов — о потере молчим', () {
      // Объявить позиции потерянными до загрузки конфига значило бы покрасить
      // красным рабочую цепочку.
      final issues = validateChainForm(
        const ChainFormState(tag: 'via-de', hops: ['home', 'de-exit']),
        _ctx(const [], targetsKnown: false),
      );
      expect(_codes(issues), isNot(contains(ChainIssueCode.missingHops)));
    });

    test('перечислены ВСЕ пропавшие, а не первая', () {
      final issues = validateChainForm(
        const ChainFormState(tag: 'via-de', hops: ['gone-a', 'gone-b']),
        _ctx([_node('home')]),
      );
      expect(_find(issues, ChainIssueCode.missingHops)!.hops,
          ['gone-a', 'gone-b']);
    });
  });

  group('имя цепочки', () {
    test('пустой тег блокирует', () {
      final issues = validateChainForm(
        const ChainFormState(tag: '', hops: ['a', 'b']),
        _ctx([_node('a'), _node('b')], originalTag: ''),
      );
      expect(_codes(issues), contains(ChainIssueCode.tagEmpty));
      expect(chainFormCanSave(issues), isFalse);
    });

    test('занятый тег блокирует: два outbound\'а с одним именем ядро отвергает',
        () {
      final issues = validateChainForm(
        const ChainFormState(tag: 'vpn-1', hops: ['a', 'b']),
        _ctx([_node('a'), _node('b')],
            taken: {'vpn-1'}, originalTag: 'via-de'),
      );
      expect(_codes(issues), contains(ChainIssueCode.tagTaken));
      expect(chainFormCanSave(issues), isFalse);
    });

    test('своё же имя занятым не считается', () {
      final issues = validateChainForm(
        const ChainFormState(tag: 'via-de', hops: ['a', 'b']),
        _ctx([_node('a'), _node('b')], taken: {'via-de'}),
      );
      expect(_codes(issues), isNot(contains(ChainIssueCode.tagTaken)));
      expect(chainFormCanSave(issues), isTrue);
    });
  });

  group('порядок показа', () {
    test('блокирующие идут раньше мягких', () {
      final issues = validateChainForm(
        const ChainFormState(tag: 'via-de', hops: ['home']),
        _ctx([_node('home', detour: true)]),
      );
      expect(issues.first.level, ChainIssueLevel.blocking);
      expect(issues.last.blocks, isFalse);
    });
  });

  group('ChainFormState.of — снимок модели', () {
    test('читает hops/strip/strip_evasion как есть', () {
      const c = SourceChain(
        tag: 'via-de',
        hops: ['a', 'b'],
        stripEvasion: false,
        strip: {kChainStripTlsUtls: true},
      );
      final s = ChainFormState.of(c);
      expect(s.tag, 'via-de');
      expect(s.hops, ['a', 'b']);
      expect(s.stripsUtls, isTrue);
    });

    test('трёхзначность не теряется: нет ключа → умолчание каталога ядра', () {
      const c = SourceChain(tag: 'via-de', hops: ['a', 'b']);
      // tls.utls — единственный ключ каталога, не снимаемый по умолчанию.
      expect(ChainFormState.of(c).stripsUtls, isFalse);
    });
  });
}
