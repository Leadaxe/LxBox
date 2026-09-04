import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/auto_select.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/services/node_hash.dart';
import 'package:lxbox/services/parser/json_parsers.dart';
import 'package:lxbox/services/parser/uri_parsers.dart';

/// §400 (контракт 0.10.0, IDENTITY.md) — идентичность узла = его ТЕГ,
/// уникализированный внутри источника. Контент-хеш остался shim'ом
/// ([legacyNodeIdentityHash]) для миграции ключей и отпечатка содержимого.
///
/// Узел с ЗАДАННЫМ тегом. Конструктор, а не `parseUri`: парсер восполняет имя
/// из схемы и адреса, и пустой тег через него не выразить — а именно пустой
/// тег проверяет пункт «идентичности нет» (§2.3). Тёзки обязаны быть РАЗНЫМИ
/// объектами: карта строится через `Map.identity()`.
NodeSpec _node(String tag, {String server = 'h.example', int port = 443}) =>
    VlessSpec(
      id: 'n${_seq++}',
      tag: tag,
      label: tag,
      server: server,
      port: port,
      rawUri: '',
      uuid: '11111111-1111-1111-1111-111111111111',
    );

int _seq = 0;

/// Узел-ГРУППА (§322): идентичности не имеет — цепляться через группу задача
/// detour, отметок выключения у групп нет.
NodeSpec _group(String tag) => AutoSelectSpec(
      id: 'g${_seq++}',
      tag: tag,
      label: tag,
      membership: const RuleMembers(include: '.'),
    );

/// §283 — identity-хеш ноды: стабилен через reparse и переименования,
/// меняется при смене сути; TTL-порог и GC отметок disable.
void main() {
  group('nodeIdentityHash', () {
    const uri = 'vless://0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c@h.example:443'
        '?type=ws&security=tls&sni=x.com&fp=chrome#Label';

    test('один и тот же URI при повторном парсе → одинаковый хеш', () {
      final a = parseVless(uri)!;
      final b = parseVless(uri)!;
      expect(a.id == b.id, isFalse, reason: 'id эфемерен — новый на парс');
      expect(legacyNodeIdentityHash(a), legacyNodeIdentityHash(b));
    });

    test('смена только ремарки (#label → tag) хеш НЕ меняет', () {
      final a = parseVless(uri)!;
      final b = parseVless(uri.replaceFirst('#Label', '#Renamed%20NL-42'))!;
      expect(a.tag == b.tag, isFalse);
      expect(legacyNodeIdentityHash(a), legacyNodeIdentityHash(b));
    });

    test('смена сути (uuid / порт) хеш меняет', () {
      final a = parseVless(uri)!;
      final otherUuid = parseVless(uri.replaceFirst('0aa41f0a', '1bb52f1b'))!;
      final otherPort = parseVless(uri.replaceFirst(':443', ':8443'))!;
      expect(legacyNodeIdentityHash(a), isNot(legacyNodeIdentityHash(otherUuid)));
      expect(legacyNodeIdentityHash(a), isNot(legacyNodeIdentityHash(otherPort)));
    });

    test('chained-цепочка (detour) в хеш не входит', () {
      Map<String, dynamic> xray({required bool withJump}) => {
            'remarks': 'L',
            'outbounds': [
              {
                'protocol': 'vless',
                'tag': 'proxy',
                'settings': {
                  'vnext': [
                    {
                      'address': 'h.example',
                      'port': 443,
                      'users': [
                        {'id': '0aa41f0a-6d92-4f74-8b13-4d0d5b6cbb6c'}
                      ],
                    }
                  ],
                },
                'streamSettings': {
                  'network': 'ws',
                  'security': 'tls',
                  'tlsSettings': {'serverName': 'x.com'},
                  if (withJump) 'sockopt': {'dialerProxy': 'jump'},
                },
              },
              if (withJump)
                {
                  'protocol': 'socks',
                  'tag': 'jump',
                  'settings': {
                    'servers': [
                      {'address': 'j.example', 'port': 1080},
                    ],
                  },
                },
            ],
          };
      final chained = parseXrayOutbound(xray(withJump: true))!;
      final plain = parseXrayOutbound(xray(withJump: false))!;
      expect(chained.chained, isNotNull, reason: 'фикстура с цепочкой');
      expect(legacyNodeIdentityHash(chained), legacyNodeIdentityHash(plain));
    });
  });

  group('deepSortKeys', () {
    test('детерминированная сериализация независимо от порядка ключей', () {
      final a = {
        'b': 1,
        'a': {
          'd': [
            {'z': 1, 'y': 2}
          ],
          'c': 3,
        },
      };
      final b = {
        'a': {
          'c': 3,
          'd': [
            {'y': 2, 'z': 1}
          ],
        },
        'b': 1,
      };
      expect(jsonEncode(deepSortKeys(a)), jsonEncode(deepSortKeys(b)));
      expect(jsonEncode(deepSortKeys(a)),
          '{"a":{"c":3,"d":[{"y":2,"z":1}]},"b":1}');
    });
  });

  group('disabledHashTtl (clamp 3×interval, пол 24ч, потолок месяц)', () {
    test('таблица порогов', () {
      expect(disabledHashTtl(1), const Duration(hours: 24)); // пол
      expect(disabledHashTtl(24), const Duration(hours: 72));
      expect(disabledHashTtl(168), const Duration(hours: 504));
      expect(disabledHashTtl(336), const Duration(hours: 720)); // потолок
      expect(disabledHashTtl(0), const Duration(hours: 24)); // respect-server
      expect(disabledHashTtl(-1), const Duration(hours: 24)); // file:
    });
  });

  group('gcDisabledHashes', () {
    final now = DateTime.utc(2026, 7, 18, 12);

    test('источник найден в свежем теле → lastSeen = now', () {
      final out = gcDisabledHashes(
        {'h1': now.subtract(const Duration(days: 10))},
        {'h1'},
        updateIntervalHours: 24,
        now: now,
      );
      expect(out, {'h1': now});
    });

    test('источник отсутствует, но порог не истёк → отметка на месте', () {
      final lastSeen = now.subtract(const Duration(hours: 71));
      final out = gcDisabledHashes(
        {'h1': lastSeen},
        const {},
        updateIntervalHours: 24, // порог 72ч
        now: now,
      );
      expect(out, {'h1': lastSeen}, reason: 'lastSeen не трогаем без находки');
    });

    test('источник отсутствует дольше порога → отметка удалена', () {
      final out = gcDisabledHashes(
        {'h1': now.subtract(const Duration(hours: 73))},
        const {},
        updateIntervalHours: 24,
        now: now,
      );
      expect(out, isEmpty);
    });

    test('смешанный проход: found/спящий/истёкший за один вызов', () {
      final sleeping = now.subtract(const Duration(hours: 10));
      final out = gcDisabledHashes(
        {
          'found': now.subtract(const Duration(hours: 100)),
          'sleeping': sleeping,
          'expired': now.subtract(const Duration(hours: 100)),
        },
        {'found'},
        updateIntervalHours: 24,
        now: now,
      );
      expect(out, {'found': now, 'sleeping': sleeping});
    });

    test('пустой current → тот же (пустой) без работы', () {
      final current = <String, DateTime>{};
      expect(
          identical(
              gcDisabledHashes(current, {'x'},
                  updateIntervalHours: 24, now: now),
              current),
          isTrue);
    });
  });

  group('§332 applyRuleMarks', () {
    final now = DateTime(2026, 8, 1);
    final old = now.subtract(const Duration(hours: 5));

    test('enable снимает отметку — в том числе ручную §283', () {
      final out = applyRuleMarks(
        {'manual': old, 'stale-rule': old},
        enable: {'manual', 'stale-rule'},
        disable: const {},
        now: now,
      );
      expect(out, isEmpty);
    });

    test('disable ставит отметку со свежим lastSeen, чужие не трогает', () {
      final out = applyRuleMarks(
        {'other': old},
        enable: const {},
        disable: {'fi-node'},
        now: now,
      );
      expect(out, {'other': old, 'fi-node': now});
    });

    test('enable + disable за один вызов (наборы не пересекаются)', () {
      final out = applyRuleMarks(
        {'was-fi': old, 'manual': old},
        enable: {'was-fi'},
        disable: {'new-nl'},
        now: now,
      );
      expect(out, {'manual': old, 'new-nl': now});
    });

    test('оба набора пусты → тот же инстанс без работы', () {
      final base = {'x': old};
      expect(
          identical(
              applyRuleMarks(base, enable: const {}, disable: const {}, now: now),
              base),
          isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §400 — идентичность = тег (контракт 0.10.0, IDENTITY.md)
  // ══════════════════════════════════════════════════════════════════════════

  group('§400 sourceNodeIdentities', () {
    test('уникализация внутри источника: X, X-2, X-3 в порядке разбора', () {
      final a = _node('X');
      final b = _node('X');
      final c = _node('X');
      final map = sourceNodeIdentities([a, b, c]);
      expect([map[a], map[b], map[c]], ['X', 'X-2', 'X-3'],
          reason: 'нумерация тёзок идёт порядком разбора, а не сортировкой');
    });

    test('кандидат проверяется на ЗАНЯТОСТЬ: X, X-2, X → X, X-2, X-3', () {
      // Находка аудита M2 (SPEC 113-A §5): без проверки третий узел получил бы
      // сгенерированное `X-2`, уже принадлежащее настоящему имени из подписки.
      // Две идентичности с одним ключом — и одна отметка гасила бы ОБА узла.
      final first = _node('X');
      final real = _node('X-2');
      final third = _node('X');
      final map = sourceNodeIdentities([first, real, third]);
      expect([map[first], map[real], map[third]], ['X', 'X-2', 'X-3']);
      expect(map.values.toSet(), hasLength(3),
          reason: 'коллизия ключей: одна отметка погасила бы два узла');
    });

    test('тёзки не схлопываются: карта по ССЫЛКЕ (Map.identity)', () {
      // `NodeSpec.==` сравнивает id+tag. Обычная Map сложила бы два узла с
      // одинаковым тегом в одну ячейку, и второй остался бы без ключа.
      final a = _node('Same');
      final b = _node('Same');
      final map = sourceNodeIdentities([a, b]);
      expect(map, hasLength(2));
      expect(map[a], isNot(map[b]));
    });

    test('группа идентичности не имеет — её в карте нет', () {
      final group = _group('Auto');
      final node = _node('Real');
      final map = sourceNodeIdentities([group, node]);
      expect(map[group], isNull,
          reason: 'у групп отметок выключения нет (§2.3)');
      expect(map[node], 'Real');
    });

    test('безымянный узел идентичности не имеет — пустая строка НЕ ключ', () {
      // Иначе все безымянные узлы схлопнулись бы в одну отметку и гасились
      // разом. «Идентичности нет» выражено структурно: узла нет в карте.
      final blank = _node('');
      final spaces = _node('   ');
      final named = _node('Named');
      final map = sourceNodeIdentities([blank, spaces, named]);
      expect(map[blank], isNull);
      expect(map[spaces], isNull, reason: 'тег из пробелов — тоже пустой');
      expect(map, hasLength(1));
    });

    test('счётчик СВОЙ на источник: два вызова нумеруют с нуля', () {
      final a = _node('X');
      final b = _node('X');
      expect(sourceNodeIdentities([a]).values, ['X']);
      expect(sourceNodeIdentities([b]).values, ['X'],
          reason: 'конфиговые теги уникальны глобально, идентичность — '
              'только внутри источника');
    });

    test('идентичность не зависит от содержимого: ротация IP её не двигает',
        () {
      // Ровно то, ради чего контракт сменил модель: провайдер вправе поменять
      // сервер под тем же именем, и отметка обязана следовать за узлом.
      final before = _node('NL-1', server: 'old.example');
      final after = _node('NL-1', server: 'new.example');
      expect(sourceNodeIdentities([before])[before],
          sourceNodeIdentities([after])[after]);
      expect(legacyNodeIdentityHash(before), isNot(legacyNodeIdentityHash(after)),
          reason: 'контент-хеш при этом обязан РАЗОЙТИСЬ — он про содержимое');
    });

    test('пустой список → пустая карта', () {
      expect(sourceNodeIdentities(const []), isEmpty);
    });
  });

  group('§400 migrateLegacyDisabledKeys (IDENTITY.md §5.1)', () {
    final seen = DateTime.utc(2026, 8, 20, 10);

    test('совпал → переезд на идентичность с СОХРАНЕНИЕМ lastSeen', () {
      final node = _node('DE-1');
      final legacy = legacyNodeIdentityHash(node);
      final out = migrateLegacyDisabledKeys({legacy: seen}, [node]);
      expect(out, {'DE-1': seen},
          reason: 'время встречи — часть отметки, обнулять его нельзя: '
              'GC снёс бы переехавшую отметку как протухшую');
    });

    test('не совпал → ключ выброшен (узла с таким содержимым нет)', () {
      final node = _node('DE-1');
      final alien = legacyNodeIdentityHash(_node('X', server: 'other.example'));
      final out = migrateLegacyDisabledKeys({alien: seen}, [node]);
      expect(out, isEmpty, reason: 'отметка и так мертва — п.4');
    });

    test('тег-ключи проходят сквозь миграцию нетронутыми', () {
      final node = _node('DE-1');
      final legacy = legacyNodeIdentityHash(node);
      final out = migrateLegacyDisabledKeys(
          {legacy: seen, 'уже-тег': seen}, [node]);
      expect(out.keys.toSet(), {'DE-1', 'уже-тег'});
    });

    test('коллизия: побеждает более свежий lastSeen', () {
      // Два legacy-ключа опознались как один узел (дубли по содержимому
      // различаются только именем). Отметке нужно ОДНО время, и это последняя
      // встреча — иначе GC снесёт её раньше срока.
      final node = _node('DE-1');
      final legacy = legacyNodeIdentityHash(node);
      final older = seen.subtract(const Duration(days: 5));
      // Один и тот же ключ дважды в карту не положить, поэтому коллизию даём
      // через второй узел-тёзку с тем же содержимым: у него другой хеш быть
      // не может, а идентичность — `DE-1-2`.
      final twin = _node('DE-1');
      final out = migrateLegacyDisabledKeys({legacy: older}, [node, twin]);
      expect(out, {'DE-1': older},
          reason: 'первый узел с этим содержимым и побеждает');
    });

    test('идемпотентность: без legacy-ключей возвращается ТА ЖЕ ссылка', () {
      // По `identical` вызывающий решает, нужен ли лишний persist: иначе
      // legacy-прогон повторялся бы на каждом запуске.
      final current = {'DE-1': seen};
      final out = migrateLegacyDisabledKeys(current, [_node('DE-1')]);
      expect(identical(out, current), isTrue);
    });

    test('второй заход после миграции ничего не меняет', () {
      final node = _node('DE-1');
      final first = migrateLegacyDisabledKeys(
          {legacyNodeIdentityHash(node): seen}, [node]);
      final second = migrateLegacyDisabledKeys(first, [node]);
      expect(identical(second, first), isTrue);
      expect(second, {'DE-1': seen});
    });

    test('пустая карта → та же ссылка без работы', () {
      final current = <String, DateTime>{};
      expect(identical(migrateLegacyDisabledKeys(current, [_node('X')]), current),
          isTrue);
    });

    test('узел без идентичности legacy-ключ не принимает', () {
      // Безымянный узел ключа не имеет, переезжать отметке некуда — она
      // выбрасывается, а не садится на пустую строку.
      final blank = _node('');
      final out =
          migrateLegacyDisabledKeys({legacyNodeIdentityHash(blank): seen}, [blank]);
      expect(out, isEmpty);
    });
  });

  group('§400 isLegacyIdentityKey', () {
    test('64 lowercase hex — legacy; всё прочее — тег', () {
      expect(isLegacyIdentityKey('a' * 64), isTrue);
      expect(isLegacyIdentityKey('A' * 64), isFalse, reason: 'только lowercase');
      expect(isLegacyIdentityKey('a' * 63), isFalse);
      expect(isLegacyIdentityKey('a' * 65), isFalse);
      expect(isLegacyIdentityKey('g' * 64), isFalse, reason: 'не hex');
      expect(isLegacyIdentityKey('DE-1'), isFalse);
      expect(isLegacyIdentityKey(''), isFalse);
    });
  });

  group('§400 legacyNodeIdentityHash — воспроизводимость', () {
    test('фиксированный вход → фиксированный hex', () {
      // Алгоритм обязан остаться воспроизводимым, пока в природе есть
      // непереехавшие состояния: правка эмиттера, сдвинувшая этот хеш,
      // означает, что legacy-ключи на устройствах перестанут опознаваться и
      // отметки пользователей молча исчезнут. Литерал — якорь именно для
      // этого; менять его вместе с эмиттером НЕЛЬЗЯ, это и есть сигнал.
      final node = VlessSpec(
        id: 'fixed',
        tag: 'Anything',
        label: 'Anything',
        server: 'example-1.com',
        port: 443,
        rawUri: '',
        uuid: '11111111-1111-1111-1111-111111111111',
      );
      final hash = legacyNodeIdentityHash(node);
      expect(hash, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(isLegacyIdentityKey(hash), isTrue,
          reason: 'форма хеша обязана опознаваться миграцией');
      // Тег в хеш не входит: та же нода под другим именем даёт тот же хеш.
      final renamed = VlessSpec(
        id: 'fixed2',
        tag: 'Other name',
        label: 'Other name',
        server: 'example-1.com',
        port: 443,
        rawUri: '',
        uuid: '11111111-1111-1111-1111-111111111111',
      );
      expect(legacyNodeIdentityHash(renamed), hash);
    });
  });
}
