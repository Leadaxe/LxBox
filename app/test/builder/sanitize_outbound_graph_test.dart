import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/builder/post_steps.dart';
import 'package:lxbox/services/builder/validator.dart';

/// §393 A4 — финальный граф-санитайзер (порт `outbound_graph_sanitize.go`).
///
/// Поглотил §172 `healDanglingDetours` (его сценарии — первая группа ниже) и
/// добавил правила про состав групп, `default` вне состава, кольца
/// зависимостей и каскад до фикспойнта.
void main() {
  List<Map<String, dynamic>> outs(Map<String, dynamic> config) =>
      (config['outbounds'] as List).cast<Map<String, dynamic>>();
  Map<String, dynamic>? byTag(Map<String, dynamic> config, String tag) {
    for (final o in [
      ...(config['outbounds'] as List? ?? const []),
      ...(config['endpoints'] as List? ?? const []),
    ]) {
      if (o is Map<String, dynamic> && o['tag'] == tag) return o;
    }
    return null;
  }

  group('правило 1 — висячий detour (поглощённый §172)', () {
    test('битый detour ("warp gen") → снят, нода остаётся', () {
      final config = {
        'outbounds': [
          {'tag': '🇫🇮 Finland', 'type': 'vless', 'detour': 'warp gen'},
          {'tag': 'direct-out', 'type': 'direct'},
        ],
      };
      final warnings = sanitizeOutboundGraph(config);

      expect(warnings, hasLength(1));
      expect(warnings.single, contains('Detour removed'));
      expect(warnings.single, contains('"warp gen"'));
      expect(warnings.single, contains('"🇫🇮 Finland"'));
      final node = outs(config)[0];
      expect(node.containsKey('detour'), isFalse, reason: 'detour снят');
      expect(node['tag'], '🇫🇮 Finland', reason: 'нода не выброшена');
      expect(outs(config), hasLength(2));
    });

    test('валидный detour → НЕ трогаем', () {
      final config = {
        'outbounds': [
          {'tag': 'main', 'type': 'vless', 'detour': 'hop'},
          {'tag': 'hop', 'type': 'shadowsocks'},
        ],
      };
      expect(sanitizeOutboundGraph(config), isEmpty);
      expect(outs(config)[0]['detour'], 'hop');
    });

    test('detour на endpoint (wireguard) → валиден, НЕ трогаем', () {
      final config = {
        'outbounds': [
          {'tag': 'main', 'type': 'vless', 'detour': 'wg-1'},
        ],
        'endpoints': [
          {'tag': 'wg-1', 'type': 'wireguard'},
        ],
      };
      expect(sanitizeOutboundGraph(config), isEmpty);
      expect(outs(config)[0]['detour'], 'wg-1');
    });

    test('несколько битых detour → все сняты, валидный уцелел', () {
      final config = {
        'outbounds': [
          {'tag': 'a', 'type': 'vless', 'detour': 'ghost1'},
          {'tag': 'b', 'type': 'vless', 'detour': 'ghost2'},
          {'tag': 'c', 'type': 'vless', 'detour': 'a'}, // валидный
          {'tag': 'direct-out', 'type': 'direct'},
        ],
      };
      final warnings = sanitizeOutboundGraph(config);

      expect(warnings.where((w) => w.contains('Detour removed')), hasLength(2));
      expect(outs(config)[2]['detour'], 'a');
      expect(outs(config)[0].containsKey('detour'), isFalse);
      expect(outs(config)[1].containsKey('detour'), isFalse);
    });

    test('detour endpoint\'а на призрака тоже деградирует', () {
      final config = {
        'endpoints': [
          {'tag': 'wg-1', 'type': 'wireguard', 'detour': 'ghost'},
        ],
      };
      final warnings = sanitizeOutboundGraph(config);
      expect(warnings, hasLength(1));
      expect((config['endpoints'] as List)[0], isNot(contains('detour')));
    });

    test('нет detour-полей → no-op', () {
      final config = {
        'outbounds': [
          {'tag': 'a', 'type': 'direct'},
        ],
      };
      expect(sanitizeOutboundGraph(config), isEmpty);
    });

    test('§377 — одна агрегированная строка на отсутствующий target', () {
      final config = {
        'outbounds': [
          for (var i = 1; i <= 7; i++)
            {'tag': 'Node-$i', 'type': 'vless', 'detour': 'warp gen'},
          {'tag': 'direct-out', 'type': 'direct'},
        ],
      };
      final lines = sanitizeOutboundGraph(config)
          .where((w) => w.contains('Detour removed'))
          .toList();

      expect(lines, hasLength(1), reason: 'одна строка на target, не 7');
      expect(lines.single, contains('7 outbounds'));
      expect(lines.single, contains('"Node-5"'));
      expect(lines.single, isNot(contains('"Node-6"')));
      expect(lines.single, contains('and 2 more'));
      expect(lines.single, contains('nodes work directly'));
    });
  });

  group('правило 2 — члены-призраки состава группы', () {
    test('призрачный член исключён, живые остаются', () {
      final config = {
        'outbounds': [
          {'tag': 'n1', 'type': 'vless'},
          {
            'tag': 'grp',
            'type': 'selector',
            'outbounds': ['n1', 'ghost'],
          },
        ],
      };
      final warnings = sanitizeOutboundGraph(config);
      expect(byTag(config, 'grp')!['outbounds'], ['n1']);
      expect(warnings.single, contains('"ghost"'));
      expect(warnings.single, contains('do not exist in the final config'));
    });

    test('include-тег на несуществующее Направление исключён (A3-остаток)',
        () {
      // A3 фильтрует include ещё в `_buildDirectionGroups`; санитайзер — сеть
      // для путей мимо него (raw-JSON шаблон, §302-патч, restore чужого
      // бэкапа).
      final config = {
        'outbounds': [
          {'tag': 'n1', 'type': 'vless'},
          {
            'tag': 'vpn-2',
            'type': 'selector',
            'outbounds': ['vpn-1', 'n1'],
          },
        ],
      };
      sanitizeOutboundGraph(config, directionTags: {'vpn-1', 'vpn-2'});
      expect(byTag(config, 'vpn-2')!['outbounds'], ['n1']);
    });

    test('состав узла автовыбора чистится так же (urltest)', () {
      final config = {
        'outbounds': [
          {'tag': 'n1', 'type': 'vless'},
          {
            'tag': 'vpn-1-auto',
            'type': 'urltest',
            'outbounds': ['n1', 'gone'],
          },
        ],
      };
      sanitizeOutboundGraph(config);
      expect(byTag(config, 'vpn-1-auto')!['outbounds'], ['n1']);
    });

    test('прочая группа, оставшаяся без участников → дроп с warning', () {
      final config = {
        'outbounds': [
          {
            'tag': '✨auto',
            'type': 'urltest',
            'outbounds': ['gone1', 'gone2'],
          },
          {'tag': 'direct-out', 'type': 'direct'},
        ],
      };
      final warnings = sanitizeOutboundGraph(config);
      expect(byTag(config, '✨auto'), isNull, reason: 'группа дропнута');
      expect(warnings.any((w) => w.contains('no members left')), isTrue);
    });

    test('пустеющее Направление → block-fallback, НЕ дроп', () {
      final config = {
        'outbounds': [
          {
            'tag': 'vpn-1',
            'type': 'selector',
            'outbounds': ['gone'],
          },
          {'tag': 'block', 'type': 'block'},
          {'tag': 'direct-out', 'type': 'direct'},
        ],
      };
      final warnings = sanitizeOutboundGraph(config, directionTags: {'vpn-1'});
      final dir = byTag(config, 'vpn-1')!;
      expect(dir, isNotNull, reason: 'Направление — цель правил, не дропается');
      expect(dir['outbounds'], ['block', 'direct-out']);
      expect(dir['default'], 'block');
      expect(warnings.any((w) => w.contains('traffic is blocked')), isTrue);
    });
  });

  group('правило 3 — default вне состава', () {
    test('default-призрак → заменён на первого участника с warning', () {
      final config = {
        'outbounds': [
          {'tag': 'n1', 'type': 'vless'},
          {'tag': 'n2', 'type': 'vless'},
          {
            'tag': 'grp',
            'type': 'selector',
            'outbounds': ['n1', 'n2'],
            'default': 'gone',
          },
        ],
      };
      final warnings = sanitizeOutboundGraph(config);
      expect(byTag(config, 'grp')!['default'], 'n1');
      expect(warnings.any((w) => w.contains('replaced with "n1"')), isTrue);
    });

    test('default выпал из состава каскадом → подхвачен kept[0]', () {
      final config = {
        'outbounds': [
          {'tag': 'n1', 'type': 'vless'},
          {
            'tag': 'grp',
            'type': 'selector',
            'outbounds': ['ghost', 'n1'],
            'default': 'ghost',
          },
        ],
      };
      sanitizeOutboundGraph(config);
      expect(byTag(config, 'grp')!['outbounds'], ['n1']);
      expect(byTag(config, 'grp')!['default'], 'n1');
    });

    test('default=block от emptyFallback НЕ перетирается', () {
      // §201/§274 — эталон `empty_direction_blocks.expected.json`:
      // [block, direct-out] с default=block. block в составе → правило 3
      // молчит, порядок опций сохранён.
      final config = {
        'outbounds': [
          {
            'tag': 'vpn-1',
            'type': 'selector',
            'outbounds': ['block', 'direct-out'],
            'default': 'block',
          },
          {'tag': 'block', 'type': 'block'},
          {'tag': 'direct-out', 'type': 'direct'},
        ],
      };
      final warnings = sanitizeOutboundGraph(config, directionTags: {'vpn-1'});
      expect(warnings, isEmpty);
      expect(byTag(config, 'vpn-1')!['default'], 'block');
      expect(byTag(config, 'vpn-1')!['outbounds'], ['block', 'direct-out']);
    });

    test('валидный default → не трогаем', () {
      final config = {
        'outbounds': [
          {'tag': 'n1', 'type': 'vless'},
          {'tag': 'n2', 'type': 'vless'},
          {
            'tag': 'grp',
            'type': 'selector',
            'outbounds': ['n1', 'n2'],
            'default': 'n2',
          },
        ],
      };
      expect(sanitizeOutboundGraph(config), isEmpty);
      expect(byTag(config, 'grp')!['default'], 'n2');
    });
  });

  group('правило 4 — узел с detour на группу со своим участием', () {
    test('вон из состава, detour СОХРАНЁН (fail-open)', () {
      // Эталон `detour_group_cycle.go`: detour задан пользователем осознанно,
      // тихо отправить трафик напрямую — нарушить ровно то, о чём он просил.
      final config = {
        'outbounds': [
          {'tag': 'Proton', 'type': 'vless', 'detour': 'vpn-2'},
          {'tag': 'Other', 'type': 'vless'},
          {
            'tag': 'vpn-2',
            'type': 'selector',
            'outbounds': ['Proton', 'Other'],
          },
        ],
      };
      final warnings = sanitizeOutboundGraph(config, directionTags: {'vpn-2'});

      expect(byTag(config, 'vpn-2')!['outbounds'], ['Other']);
      expect(byTag(config, 'Proton')!['detour'], 'vpn-2',
          reason: 'detour сохранён — fail-open');
      expect(
          warnings.any((w) => w.contains(
              'Outbound "Proton" detours through group "vpn-2" it belongs '
              'to — excluded from it')),
          isTrue);
      expect(validateConfig(config).isOk, isTrue);
    });

    test('detour на СЕЛЕКТОР при живом auto-двойнике → вон из обоих', () {
      // Достижимость правила 4 идёт по составу групп, потому detour на
      // селектор Направления виден и из его auto-двойника (vpn-2 ∋ vpn-2-auto
      // ∋ узел). Без этого шага кольцо vpn-2 → vpn-2-auto → узел → vpn-2
      // достался бы правилу 5, а оно развязало бы его СНЯТИЕМ detour'а — ровно
      // тем, чего эталон `detour_group_cycle.go` требует избежать.
      final config = {
        'outbounds': [
          {'tag': 'Relay', 'type': 'vless', 'detour': 'vpn-2'},
          {'tag': 'Other', 'type': 'vless'},
          {
            'tag': 'vpn-2-auto',
            'type': 'urltest',
            'outbounds': ['Relay', 'Other'],
          },
          {
            'tag': 'vpn-2',
            'type': 'selector',
            'outbounds': ['vpn-2-auto', 'Relay', 'Other'],
          },
        ],
      };
      final warnings = sanitizeOutboundGraph(config, directionTags: {'vpn-2'});

      expect(byTag(config, 'vpn-2')!['outbounds'], ['vpn-2-auto', 'Other']);
      expect(byTag(config, 'vpn-2-auto')!['outbounds'], ['Other']);
      expect(byTag(config, 'Relay')!['detour'], 'vpn-2',
          reason: 'fail-open: detour пережил обе группы');
      expect(warnings.every((w) => !w.contains('Dependency cycle')), isTrue,
          reason: 'кольцо снято правилом 4, до правила 5 не дошло');
      expect(validateConfig(config).isOk, isTrue);
    });

    test(
        'композиция fail-open → fail-closed: detour цел, но КОМПОЗИТНЫЙ '
        'warning называет узел и последствие', () {
      // Сценарий адверсариального ревью: правило 4 выкидывает единственного
      // участника Направления (его detour сохраняется — fail-open), после
      // чего правило 2 уводит опустевшее Направление в block-fallback. Итог:
      // detour узла теперь ведёт в block, весь его трафик заблокирован —
      // молча перевёрнутая политика при валидном конфиге.
      //
      // Решение: detour СОХРАНЯЕМ (снять = выпустить трафик мимо VPN, что
      // ломает принцип `empty_direction_blocks`), но обязаны сказать вслух.
      final config = {
        'outbounds': [
          {'tag': 'block', 'type': 'block'},
          {'tag': 'direct-out', 'type': 'direct'},
          {
            'tag': 'vpn-1',
            'type': 'selector',
            'outbounds': ['a'],
          },
          {'tag': 'a', 'type': 'vless', 'detour': 'vpn-1'},
        ],
      };
      final warnings = sanitizeOutboundGraph(config, directionTags: {'vpn-1'});

      // detour цел — fail-open не отменён.
      expect(byTag(config, 'a')!['detour'], 'vpn-1');
      // Направление уцелело block-fallback'ом.
      expect(byTag(config, 'vpn-1')!['outbounds'], ['block', 'direct-out']);
      expect(byTag(config, 'vpn-1')!['default'], 'block');

      final composite = warnings
          .where((w) => w.contains('which is now blocked'))
          .toList();
      expect(composite, hasLength(1), reason: 'композитный warning есть');
      expect(composite.single, contains('"a"'), reason: 'узел назван');
      expect(composite.single, contains('"vpn-1"'));
      expect(composite.single, contains('traffic is blocked too'),
          reason: 'последствие названо прямым текстом');
      expect(composite.single, contains('outside the VPN'),
          reason: 'объяснено, почему detour не снят');
      expect(validateConfig(config).isOk, isTrue);
    });

    test(
        'Направление в block-fallback БЕЗ живых detour-ов → композитного '
        'warning нет', () {
      // Обратная сторона: композитный warning гейтится наличием узла,
      // который в это Направление детурит. Иначе он превратился бы в шум на
      // каждом пустом по фильтру Направлении.
      final config = {
        'outbounds': [
          {
            'tag': 'vpn-1',
            'type': 'selector',
            'outbounds': ['gone'],
          },
          {'tag': 'block', 'type': 'block'},
          {'tag': 'direct-out', 'type': 'direct'},
        ],
      };
      final warnings = sanitizeOutboundGraph(config, directionTags: {'vpn-1'});
      expect(warnings.any((w) => w.contains('which is now blocked')), isFalse);
    });

    test('единственный участник детурит в группу → Направление в block', () {
      final config = {
        'outbounds': [
          {'tag': 'Proton', 'type': 'vless', 'detour': 'vpn-1'},
          {
            'tag': 'vpn-1',
            'type': 'selector',
            'outbounds': ['Proton'],
          },
          {'tag': 'block', 'type': 'block'},
          {'tag': 'direct-out', 'type': 'direct'},
        ],
      };
      sanitizeOutboundGraph(config, directionTags: {'vpn-1'});
      expect(byTag(config, 'vpn-1')!['outbounds'], ['block', 'direct-out']);
      expect(byTag(config, 'Proton')!['detour'], 'vpn-1');
      expect(validateConfig(config).isOk, isTrue);
    });
  });

  group('§377-агрегация правила 4 — по УЗЛУ, а не по группе', () {
    test('узел в селекторе И в auto-двойнике → ОДИН warning со списком групп',
        () {
      // Виноватый узел состоит и в селекторе Направления, и в его
      // auto-двойнике; агрегация по ГРУППЕ давала бы два warning'а об одной
      // и той же ноде.
      final config = {
        'outbounds': [
          {'tag': 'Relay', 'type': 'vless', 'detour': 'vpn-1'},
          {'tag': 'Other', 'type': 'vless'},
          {
            'tag': 'vpn-1-auto',
            'type': 'urltest',
            'outbounds': ['Relay', 'Other'],
          },
          {
            'tag': 'vpn-1',
            'type': 'selector',
            'outbounds': ['vpn-1-auto', 'Relay', 'Other'],
          },
        ],
      };
      final warnings = sanitizeOutboundGraph(config, directionTags: {'vpn-1'});

      final lines =
          warnings.where((w) => w.contains('it belongs to — excluded')).toList();
      expect(lines, hasLength(1), reason: 'один узел — один warning, не два');
      expect(lines.single, contains('"Relay"'));
      expect(lines.single, contains('"vpn-1"'));
      expect(lines.single, contains('"vpn-1-auto"'));
      expect(lines.single, contains('groups'),
          reason: 'множественное число при двух группах');
      expect(byTag(config, 'Relay')!['detour'], 'vpn-1');
      expect(validateConfig(config).isOk, isTrue);
    });

    test('два разных виноватых узла в одной группе → два warning\'а', () {
      // Агрегация по узлу не должна СКЛЕИВАТЬ разные узлы: каждый теряет
      // членство сам по себе, и юзеру нужны оба имени.
      final config = {
        'outbounds': [
          {'tag': 'A', 'type': 'vless', 'detour': 'vpn-1'},
          {'tag': 'B', 'type': 'vless', 'detour': 'vpn-1'},
          {'tag': 'C', 'type': 'vless'},
          {
            'tag': 'vpn-1',
            'type': 'selector',
            'outbounds': ['A', 'B', 'C'],
          },
        ],
      };
      final warnings = sanitizeOutboundGraph(config, directionTags: {'vpn-1'});
      final lines =
          warnings.where((w) => w.contains('it belongs to — excluded')).toList();
      expect(lines, hasLength(2));
      expect(lines.join('\n'), contains('"A"'));
      expect(lines.join('\n'), contains('"B"'));
      expect(byTag(config, 'vpn-1')!['outbounds'], ['C']);
    });
  });

  group('ФИКС 2 — честный текст про цель, снятую самим санитайзером', () {
    test('НЕ-Направленческая группа дропнута → detour снят, «missing» нет',
        () {
      // Каскад: `g` — обычная группа (не Направление) с единственным членом
      // `a`; правило 4 выкидывает `a` из состава, группа пустеет и ДРОПАЕТСЯ
      // санитайзером, после чего правило 1 снимает повисший detour `a → g`.
      // Текст «referenced missing "g"» отправил бы юзера искать битую
      // подписку — а тег `g` в конфиге БЫЛ, его удалил сам санитайзер.
      final config = {
        'outbounds': [
          {
            'tag': 'g',
            'type': 'selector',
            'outbounds': ['a'],
          },
          {'tag': 'a', 'type': 'vless', 'detour': 'g'},
        ],
      };
      final warnings = sanitizeOutboundGraph(config); // g НЕ Направление

      expect(byTag(config, 'g'), isNull, reason: 'группа дропнута');
      expect(byTag(config, 'a'), isNotNull, reason: 'узел жив');
      expect(byTag(config, 'a')!.containsKey('detour'), isFalse,
          reason: 'detour снят правилом 1 — цели больше нет');

      final line = warnings.singleWhere((w) => w.startsWith('Detour removed:'));
      expect(line, contains('"a"'));
      expect(line, contains('"g"'));
      expect(line, contains('left with no members and removed during sanitation'),
          reason: 'честная причина');
      expect(line, isNot(contains('missing')),
          reason: 'санитайзер не сваливает вину на подписку');
    });

    test('цель, которой не было изначально → прежний текст «missing»', () {
      // Обратная сторона развилки: битая подписка по-прежнему называется
      // битой. Оба текста в ОДНОМ прогоне — тексты не должны схлопнуться.
      final config = {
        'outbounds': [
          {
            'tag': 'g',
            'type': 'selector',
            'outbounds': ['a'],
          },
          {'tag': 'a', 'type': 'vless', 'detour': 'g'},
          {'tag': 'b', 'type': 'vless', 'detour': 'never-existed'},
        ],
      };
      final lines = sanitizeOutboundGraph(config)
          .where((w) => w.startsWith('Detour removed:'))
          .toList();

      expect(lines, hasLength(2));
      final missing =
          lines.singleWhere((w) => w.contains('"never-existed"'));
      expect(missing, contains('referenced missing'));
      expect(missing, contains('"b"'));
      final sanitized = lines.singleWhere((w) => w.contains('"g"'));
      expect(sanitized, contains('removed during sanitation'));
      expect(sanitized, isNot(contains('missing')));
    });
  });

  group('ФИКС 3 — живость только по ФАКТУ записи (контракт с валидатором)', () {
    test('block БЕЗ записи в конфиге — призрак, как и для validateConfig', () {
      // До фикса `alive()` объявляла `kReservedDirectionTags` живыми без
      // записи, а `validator.dart` строит `allTags` строго по фактическим
      // outbounds/endpoints. Санитайзер оставлял ссылку — валидатор падал
      // фатально уже ПОСЛЕ него. Теперь обе стороны решают одинаково.
      final config = {
        'outbounds': [
          {'tag': 'n1', 'type': 'vless', 'detour': 'block'},
          {
            'tag': 'grp',
            'type': 'selector',
            'outbounds': ['n1', 'block'],
          },
        ],
      };
      sanitizeOutboundGraph(config);
      expect(byTag(config, 'n1')!.containsKey('detour'), isFalse);
      expect(byTag(config, 'grp')!['outbounds'], ['n1']);
      expect(validateConfig(config).isOk, isTrue,
          reason: 'санитайзер не оставляет валидатору фатальной ссылки');
    });

    test('block С записью (боевой wizard_template) — живой', () {
      // Боевой шаблон эмитит `magic_nodes.direct`/`magic_nodes.block`, и по
      // ФАКТУ записи оба живы: block-fallback пустого Направления
      // (`empty_direction_blocks`) остаётся цел.
      final config = {
        'outbounds': [
          {'tag': 'n1', 'type': 'vless', 'detour': 'block'},
          {
            'tag': 'grp',
            'type': 'selector',
            'outbounds': ['n1', 'block'],
          },
          {'tag': 'block', 'type': 'block'},
          {'tag': 'direct-out', 'type': 'direct'},
        ],
      };
      expect(sanitizeOutboundGraph(config), isEmpty);
      expect(byTag(config, 'n1')!['detour'], 'block');
      expect(byTag(config, 'grp')!['outbounds'], ['n1', 'block']);
    });

    test('ACTION-псевдоцели правил (direct/reject/drop) — не outbound-теги',
        () {
      // `direct`/`reject`/`drop` лежат в `kReservedDirectionTags`, но это
      // ACTION'ы route-правил, а не outbound'ы: в `detour` они такие же
      // призраки, как любой отсутствующий тег, и ядро отвергло бы конфиг.
      final config = {
        'outbounds': [
          {'tag': 'n1', 'type': 'vless', 'detour': 'reject'},
          {'tag': 'n2', 'type': 'vless', 'detour': 'direct'},
          {'tag': 'n3', 'type': 'vless', 'detour': 'dns-out'},
        ],
      };
      sanitizeOutboundGraph(config);
      for (final t in ['n1', 'n2', 'n3']) {
        expect(byTag(config, t)!.containsKey('detour'), isFalse, reason: t);
      }
      expect(validateConfig(config).isOk, isTrue);
    });
  });

  group('правило 5 — кольца по любым рёбрам', () {
    test('detour→группа→член: кольцо разорвано, конфиг валиден', () {
      // Транзитивно (не прямое участие): Node детурит в vpn-1, а vpn-1 держит
      // Relay, который детурит в Node. Правило 4 такое кольцо не видит —
      // ловит фикспойнт-DFS.
      final config = {
        'outbounds': [
          {'tag': 'Node', 'type': 'vless', 'detour': 'vpn-1'},
          {'tag': 'Relay', 'type': 'vless', 'detour': 'Node'},
          {
            'tag': 'vpn-1',
            'type': 'selector',
            'outbounds': ['Relay'],
          },
        ],
      };
      final warnings = sanitizeOutboundGraph(config, directionTags: {'vpn-1'});
      expect(warnings.any((w) => w.contains('Dependency cycle')), isTrue);
      expect(validateConfig(config).isOk, isTrue,
          reason: '§254-fatal валидатора уже не срабатывает');
    });

    test('member-кольцо selector↔selector: замыкающее ребро исключено', () {
      final config = {
        'outbounds': [
          {'tag': 'n1', 'type': 'vless'},
          {
            'tag': 'vpn-1',
            'type': 'selector',
            'outbounds': ['vpn-2', 'n1'],
          },
          {
            'tag': 'vpn-2',
            'type': 'selector',
            'outbounds': ['vpn-1', 'n1'],
          },
        ],
      };
      final warnings =
          sanitizeOutboundGraph(config, directionTags: {'vpn-1', 'vpn-2'});
      expect(warnings.any((w) => w.contains('excluded from group')), isTrue);
      expect(validateConfig(config).isOk, isTrue);
      // n1 уцелел в обеих группах — рвём ровно одно ребро.
      expect((byTag(config, 'vpn-1')!['outbounds'] as List), contains('n1'));
      expect((byTag(config, 'vpn-2')!['outbounds'] as List), contains('n1'));
    });

    test('include-кольцо после reorder (A3): состав спасён, кольца нет', () {
      // A3 держит антицикл ПОРЯДКОМ списка; кольцо в конфиге может появиться
      // только мимо формы (raw JSON / restore). Санитайзер рвёт member-ребро,
      // а не роняет сборку.
      final config = {
        'outbounds': [
          {'tag': 'n1', 'type': 'vless'},
          {'tag': 'n2', 'type': 'vless'},
          {
            'tag': 'vpn-1',
            'type': 'selector',
            'outbounds': ['vpn-2', 'n1'],
          },
          {
            'tag': 'vpn-2',
            'type': 'selector',
            'outbounds': ['vpn-1', 'n2'],
          },
        ],
      };
      sanitizeOutboundGraph(config, directionTags: {'vpn-1', 'vpn-2'});
      expect(validateConfig(config).isOk, isTrue);
      // Обе группы живы и непусты — деградация точечная.
      expect((byTag(config, 'vpn-1')!['outbounds'] as List), isNotEmpty);
      expect((byTag(config, 'vpn-2')!['outbounds'] as List), isNotEmpty);
    });

    test(
        '§254-минимальность: кольцо рвётся у виноватого, невиновный флот в '
        'составе цел', () {
      // Миниатюра device-кейса §254 на голом графе: флот BL ∈ vpn-2 детурит в
      // vpn-3, одна AWG-нода ∈ vpn-3 детурит обратно в vpn-2. Правило 4 сюда
      // НЕ лезет (его достижимость — только по составу групп, без detour'ов
      // чужих узлов): иначе оно выбросило бы из vpn-2 весь невиновный флот и
      // увело бы Направление в block. Работает правило 5 — снимает ровно один
      // detour у ноды с минимальным «весом» кольца.
      final config = {
        'outbounds': [
          for (final n in ['BL Sofia', 'BL Zagreb', 'BL Varna'])
            {'tag': n, 'type': 'vless', 'detour': 'vpn-3'},
          {'tag': 'IN Masque A', 'type': 'vless'},
          {'tag': 'IN Awg', 'type': 'vless', 'detour': 'vpn-2'},
          {
            'tag': 'vpn-2',
            'type': 'selector',
            'outbounds': ['BL Sofia', 'BL Zagreb', 'BL Varna'],
          },
          {
            'tag': 'vpn-3',
            'type': 'selector',
            'outbounds': ['IN Masque A', 'IN Awg'],
          },
        ],
      };
      final warnings =
          sanitizeOutboundGraph(config, directionTags: {'vpn-2', 'vpn-3'});

      expect(warnings, hasLength(1), reason: 'ровно одна деградация');
      expect(warnings.single, contains('"IN Awg"'));
      expect(warnings.single, contains('detour removed'));
      expect(byTag(config, 'IN Awg')!.containsKey('detour'), isFalse);
      // Флот не тронут: ни detour'ы, ни состав vpn-2.
      for (final n in ['BL Sofia', 'BL Zagreb', 'BL Varna']) {
        expect(byTag(config, n)!['detour'], 'vpn-3', reason: '$n невиновен');
      }
      expect(byTag(config, 'vpn-2')!['outbounds'],
          ['BL Sofia', 'BL Zagreb', 'BL Varna']);
      expect(validateConfig(config).isOk, isTrue);
    });

    test('detour-самоссылка (self-loop) → detour снят', () {
      final config = {
        'outbounds': [
          {'tag': 'loop', 'type': 'vless', 'detour': 'loop'},
        ],
      };
      final warnings = sanitizeOutboundGraph(config);
      expect(byTag(config, 'loop')!.containsKey('detour'), isFalse);
      expect(warnings.any((w) => w.contains('Dependency cycle')), isTrue);
    });

    test('чистый граф без колец → no-op', () {
      final config = {
        'outbounds': [
          {'tag': 'hop', 'type': 'vless'},
          {'tag': 'n1', 'type': 'vless', 'detour': 'hop'},
          {
            'tag': 'vpn-1',
            'type': 'selector',
            'outbounds': ['n1', 'hop'],
            'default': 'n1',
          },
        ],
      };
      expect(sanitizeOutboundGraph(config, directionTags: {'vpn-1'}), isEmpty);
    });
  });

  group('КАСКАД до фикспойнта', () {
    test('дроп группы → член-призрак → пустеющая группа → висячая ссылка', () {
      // Сценарий шапки Go-файла: удаление одного узла делает висячими новые
      // ссылки, и один проход не сходится.
      //   inner (urltest) остался без участников → дроп
      //   → mid (selector) содержал только inner → пустеет
      //   → outer (selector) содержал только mid → пустеет
      //   → vpn-1 (Направление) содержал только outer → block-fallback
      //   → узел, детуривший на outer, теряет detour
      final config = {
        'outbounds': [
          {
            'tag': 'inner',
            'type': 'urltest',
            'outbounds': ['gone'],
          },
          {
            'tag': 'mid',
            'type': 'selector',
            'outbounds': ['inner'],
            'default': 'inner',
          },
          {
            'tag': 'outer',
            'type': 'selector',
            'outbounds': ['mid'],
          },
          {
            'tag': 'vpn-1',
            'type': 'selector',
            'outbounds': ['outer'],
          },
          {'tag': 'Rider', 'type': 'vless', 'detour': 'outer'},
          {'tag': 'block', 'type': 'block'},
          {'tag': 'direct-out', 'type': 'direct'},
        ],
      };
      sanitizeOutboundGraph(config, directionTags: {'vpn-1'});

      expect(byTag(config, 'inner'), isNull);
      expect(byTag(config, 'mid'), isNull);
      expect(byTag(config, 'outer'), isNull);
      expect(byTag(config, 'vpn-1')!['outbounds'], ['block', 'direct-out'],
          reason: 'Направление уцелело block-fallback\'ом');
      expect(byTag(config, 'vpn-1')!['default'], 'block');
      expect(byTag(config, 'Rider')!.containsKey('detour'), isFalse,
          reason: 'detour на дропнутую группу снят на следующей итерации');
      expect(validateConfig(config).isOk, isTrue);
    });

    test('каскад через endpoints: дроп группы чистит detour endpoint\'а', () {
      final config = {
        'outbounds': [
          {
            'tag': 'grp',
            'type': 'selector',
            'outbounds': ['gone'],
          },
        ],
        'endpoints': [
          {'tag': 'wg-1', 'type': 'wireguard', 'detour': 'grp'},
        ],
      };
      sanitizeOutboundGraph(config);
      expect(byTag(config, 'grp'), isNull);
      expect(byTag(config, 'wg-1')!.containsKey('detour'), isFalse);
      expect((config['endpoints'] as List), hasLength(1),
          reason: 'endpoint не дропнут, только его detour');
    });
  });
}
