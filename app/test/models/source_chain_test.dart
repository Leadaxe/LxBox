import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/codec/chain_record.dart';
import 'package:lxbox/models/node_link.dart';
import 'package:lxbox/models/source_chain.dart';

// §393 C1 — модель источника-цепочки (SPEC 110), канон
// `contract/schema/source_chain.schema.json`.

/// Цепочка через запись `sources[]` и JSON-текст файла — путь хранения (§439).
SourceChain _roundTrip(SourceChain c) => chainFromRecord(
        (jsonDecode(jsonEncode(chainToRecord(c))) as Map).cast<String, dynamic>())
    .value!;

Map<String, dynamic> _body(SourceChain c) =>
    chainToRecord(c)['body'] as Map<String, dynamic>;

void main() {
  group('SourceChain: запись sources[] round-trip', () {
    test('минимальная цепочка: hops переживают запись и чтение В ПОРЯДКЕ ПАКЕТА',
        () {
      const c = SourceChain(tag: 'via-de', hops: [
        NodeLink(tag: 'home-vps'),
        NodeLink(folderId: 'sub-1', tag: 'de-exit'),
      ]);
      final back = _roundTrip(c);
      // Порядок — смысл записи: перевернув его, получим работающий, но
      // другой маршрут (SPEC 110 T3). Пара едет парой, корневая — без
      // folder_id (D-112).
      expect(back.hops, const [
        NodeLink(tag: 'home-vps'),
        NodeLink(folderId: 'sub-1', tag: 'de-exit'),
      ]);
      expect(chainToRecord(c)['hops'], [
        {'tag': 'home-vps'},
        {'folder_id': 'sub-1', 'tag': 'de-exit'},
      ]);
      expect(back.tag, 'via-de');
      expect(back.enabled, isTrue);
    });

    test('полная цепочка: idle_timeout / strip / rewrite доезжают дословно', () {
      const c = SourceChain(
        tag: 'tuned',
        label: 'Tuned',
        hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b'), NodeLink(tag: 'c')],
        idleTimeout: '10m',
        stripEvasion: false,
        strip: {kChainStripTlsUtls: true, kChainStripTlsFragment: false},
        rewrite: {
          'vless': {'flow': 'xtls-rprx-vision'},
        },
      );
      final back = _roundTrip(c);
      expect(back, c);
      expect(back.idleTimeout, '10m');
      expect(back.stripEvasion, isFalse);
      expect(back.strip, {kChainStripTlsFragment: false, kChainStripTlsUtls: true});
      expect(back.rewrite, {
        'vless': {'flow': 'xtls-rprx-vision'},
      });
      expect(back.label, 'Tuned');
    });

    test('rewrite с null-значением (RFC 7396 «удалить ключ») не теряется', () {
      // null внутри merge-patch значит «удалить ключ у звена». Прибрать его
      // как «пустое значение» означало бы молча сменить патч на обратный
      // по смыслу — звено сохранило бы поле, которое пользователь снимал.
      const c = SourceChain(
        tag: 'c',
        hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')],
        rewrite: {
          'vless': {'flow': null},
        },
      );
      final back = _roundTrip(c);
      expect((back.rewrite['vless'] as Map).containsKey('flow'), isTrue);
      expect((back.rewrite['vless'] as Map)['flow'], isNull);
    });

    test('strip_evasion трёхзначен: нет ключа ≠ false', () {
      // Отсутствие ключа = умолчание ядра (true), false = явное выключение.
      // Схлопнув их в bool, мы потеряли бы выбор пользователя при смене
      // дефолта ядра.
      const unset = SourceChain(tag: 'c', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]);
      expect(_body(unset).containsKey('strip_evasion'), isFalse);
      expect(unset.stripEvasion, isNull);
      expect(unset.stripEvasionEnabled, isTrue);

      const off = SourceChain(tag: 'c', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')], stripEvasion: false);
      expect(_body(off)['strip_evasion'], isFalse);
      expect(off.stripEvasionEnabled, isFalse);
      expect(_roundTrip(off).stripEvasion, isFalse);
      expect(_roundTrip(unset).stripEvasion, isNull);
    });

    test('пустые каталоги ключей в записи не создают', () {
      const c = SourceChain(tag: 'c', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')]);
      final j = _body(c);
      expect(j.containsKey('strip'), isFalse);
      expect(j.containsKey('rewrite'), isFalse);
      expect(j.containsKey('idle_timeout'), isFalse);
    });

    test('чтение терпимо к мусору: не-строки в hops и чужие ключи strip', () {
      final notes = <String>[];
      final read = chainFromRecord({
        'kind': 'chain',
        'tag': 'c',
        'hops': [
          {'tag': 'a'},
          42,
          null,
          'b',
        ],
        'body': {
          'type': 'chain',
          'strip': {'tls.utls': true, 'nonsense': true, 'tls.fragment': 'yes'},
        },
      }, notes: notes);
      final back = read.value!;
      // Строка — корневая ссылка формы до 1.0; не ссылка — отброс с отметкой.
      expect(back.hops, const [NodeLink(tag: 'a'), NodeLink(tag: 'b')]);
      expect(notes, hasLength(2));
      expect(read.unknownKeys,
          ['body.strip.nonsense', 'body.strip.tls.fragment']);
      // Неизвестный ключ отсеян на чтении — ядро на нём не стартует.
      expect(back.strip, {kChainStripTlsUtls: true});
    });

    test('copyWith не трогает tag и умеет снять strip_evasion в «умолчание»',
        () {
      const c = SourceChain(tag: 'c', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')], stripEvasion: false);
      final off = c.copyWith(label: 'X');
      expect(off.tag, 'c');
      expect(off.label, 'X');
      expect(off.stripEvasion, isFalse);
      expect(c.copyWith(clearStripEvasion: true).stripEvasion, isNull);
    });

    test('displayLabel: пустое имя показывает тег', () {
      expect(const SourceChain(tag: 'chain-1').displayLabel, 'chain-1');
      expect(const SourceChain(tag: 'chain-1', label: 'Двойной').displayLabel,
          'Двойной');
    });
  });

  group('каталог strip', () {
    test('ровно четыре ключа, tls.utls последний и не снимается по умолчанию',
        () {
      // Список ЗАКРЫТ: неизвестный ключ ядро считает ошибкой старта.
      expect(kChainStripKeys, [
        'tls.fragment',
        'multiplex.padding',
        'xhttp.padding',
        'tls.utls',
      ]);
      expect(kChainStripDefault[kChainStripTlsUtls], isFalse);
      expect(
          kChainStripKeys.where((k) => kChainStripDefault[k] == true).length, 3);
    });
  });

  group('chainEmitError — инварианты ядра', () {
    test('валидная цепочка ошибок не даёт', () {
      expect(chainEmitError(const SourceChain(tag: 'c', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')])), '');
    });

    test('меньше двух позиций', () {
      expect(chainEmitError(const SourceChain(tag: 'c')),
          contains('no positions set'));
      expect(chainEmitError(const SourceChain(tag: 'c', hops: [NodeLink(tag: 'a')])),
          contains('at least two'));
    });

    test('пустая позиция, самоссылка, дубль', () {
      expect(chainEmitError(const SourceChain(tag: 'c', hops: [NodeLink(tag: 'a'), NodeLink(tag: '  ')])),
          contains('position 2 is empty'));
      expect(chainEmitError(const SourceChain(tag: 'c', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'c')])),
          contains('references the chain itself'));
      expect(chainEmitError(const SourceChain(tag: 'c', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'a')])),
          contains('repeats'));
    });

    test('неизвестный ключ strip называет допустимые', () {
      final err = chainEmitError(const SourceChain(
          tag: 'c', hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')], strip: {'tls.nope': true}));
      expect(err, contains('unknown key'));
      expect(err, contains('tls.utls'));
    });
  });

  group('chainOutboundObject', () {
    test('ключ ядра — outbounds, порядок хопов сохраняется', () {
      // Финальные теги позиций даёт сборка (node_link_resolve.dart): модель
      // их не знает, объект берёт их списком в порядке hops.
      final ob = chainOutboundObject(
          const SourceChain(tag: 'via-de', hops: [
            NodeLink(tag: 'home'),
            NodeLink(folderId: 'sub-1', tag: 'de'),
          ]),
          ['home', 'S de']);
      expect(ob['type'], 'chain');
      expect(ob['tag'], 'via-de');
      expect(ob['outbounds'], ['home', 'S de']);
      // Умолчания в конфиг не пишутся — иначе явный выбор пользователя стал
      // бы неотличим от дефолта уже в файле.
      expect(ob.containsKey('strip_evasion'), isFalse);
      expect(ob.containsKey('idle_timeout'), isFalse);
    });

    test('strip обходится по каталогу, а не по порядку ключей Map', () {
      final ob = chainOutboundObject(const SourceChain(
        tag: 'c',
        hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')],
        // Намеренно обратный каталогу порядок.
        strip: {kChainStripTlsUtls: true, kChainStripTlsFragment: false},
      ), const ['a', 'b']);
      expect((ob['strip'] as Map).keys.toList(), ['tls.fragment', 'tls.utls']);
    });

    test('rewrite копируется, а не разделяется с моделью', () {
      const c = SourceChain(
        tag: 'c',
        hops: [NodeLink(tag: 'a'), NodeLink(tag: 'b')],
        rewrite: {
          'vless': {'flow': ''},
        },
      );
      final ob = chainOutboundObject(c, const ['a', 'b']);
      (ob['rewrite'] as Map)['vless'] = {'hacked': true};
      expect(c.rewrite['vless'], {'flow': ''});
    });
  });

  group('nextChainTag', () {
    test('берёт первую свободную позицию, а не «максимум + 1»', () {
      expect(nextChainTag(const []), 'chain-1');
      expect(nextChainTag(const ['chain-1', 'chain-3']), 'chain-2');
      expect(nextChainTag(const ['chain-1', 'chain-2']), 'chain-3');
    });
  });
}
