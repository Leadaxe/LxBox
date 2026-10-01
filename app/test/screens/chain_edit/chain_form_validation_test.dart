import 'package:flutter_test/flutter_test.dart';

import '../../contract_paths.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/source_chain.dart';
import 'package:lxbox/screens/chain_edit/chain_form_validation.dart';
import 'package:lxbox/screens/chain_edit/chain_hop_candidate.dart';

// §393 C6 — валидация формы цепочки. ФОРМА — ЕДИНСТВЕННЫЙ РУБЕЖ (§393 L4):
// `sing-box check` ошибки старта не ловит, ядро отвергает конфиг ЦЕЛИКОМ, и
// пользователь остаётся без VPN, а не без одного маршрута.
//
// Тесты сверяют КОДЫ и УРОВНИ находок, не тексты: подпись меняется, инвариант
// нет (AGENTS.md — тестов на формат UI-строк не писать).

/// Тело vless-узла с REALITY: реестр (`tls.reality.enabled` requires
/// `tls.utls.enabled` с `set`) требует у него путь `tls.utls`.
Map<String, dynamic> _realityBody(String tag) => {
      'type': 'vless',
      'tag': tag,
      'server': '203.0.113.7',
      'server_port': 443,
      'uuid': 'b831381d-6324-4d53-ad4f-8cda48b30811',
      'tls': {
        'enabled': true,
        'server_name': 'example.com',
        'utls': {'enabled': true, 'fingerprint': 'chrome'},
        'reality': {
          'enabled': true,
          'public_key': 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0',
          'short_id': '0123abcd',
        },
      },
    };

ChainHopCandidate _node(String tag,
        {bool reality = false, bool detour = false}) =>
    ChainHopCandidate(
        tag: tag,
        kind: ChainHopKind.node,
        body: reality ? _realityBody(tag) : null,
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

  // §57 (контракт 1.1.61) — REALITY × снятый uTLS больше не ошибка формы:
  // `on_hop_required` реестра снимает ключ с патча, цепочка собирается,
  // находка — предупреждение с кодом реестра.
  group('reality + strip tls.utls — on_hop_required реестра', () {
    setUpAll(loadTestRegistry);

    test('снятый utls на reality-ЗВЕНЕ — предупреждение, сохранять можно', () {
      final issues = validateChainForm(
        const ChainFormState(
          tag: 'via-de',
          hops: ['home', 'de-reality'],
          strip: {'tls.utls': true},
        ),
        _ctx([_node('home'), _node('de-reality', reality: true)]),
      );
      final kept = _find(issues, ChainIssueCode.stripKeptForHop);
      expect(kept, isNotNull);
      expect(kept!.level, ChainIssueLevel.warning);
      expect(kept.hops, ['de-reality']);
      expect(chainFormCanSave(issues), isTrue);
    });

    test('reality на позиции 0 не судится: strip применяется к звеньям', () {
      final issues = validateChainForm(
        const ChainFormState(
          tag: 'via-de',
          hops: ['home-reality', 'de-exit'],
          strip: {'tls.utls': true},
        ),
        _ctx([_node('home-reality', reality: true), _node('de-exit')]),
      );
      expect(_codes(issues), isNot(contains(ChainIssueCode.stripKeptForHop)));
    });

    test('utls по умолчанию каталога не снимается — находки нет', () {
      final issues = validateChainForm(
        const ChainFormState(tag: 'via-de', hops: ['home', 'de-reality']),
        _ctx([_node('home'), _node('de-reality', reality: true)]),
      );
      expect(_codes(issues), isNot(contains(ChainIssueCode.stripKeptForHop)));
    });

    test('явная галка перевешивает выключенный strip_evasion', () {
      final issues = validateChainForm(
        const ChainFormState(
          tag: 'via-de',
          hops: ['home', 'de-reality'],
          stripEvasion: false,
          strip: {'tls.utls': true},
        ),
        _ctx([_node('home'), _node('de-reality', reality: true)]),
      );
      expect(_codes(issues), contains(ChainIssueCode.stripKeptForHop));
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
        hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')],
        stripEvasion: false,
        strip: {'tls.utls': true},
      );
      final s = ChainFormState.of(c);
      expect(s.tag, 'via-de');
      expect(s.hops, ['a', 'b']);
      expect(s.stripEvasion, isFalse);
      expect(s.strip, {'tls.utls': true});
    });
  });
}
