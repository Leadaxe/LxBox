import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/engine/section_loader.dart';

import 'engine_test_setup.dart';

/// §480 W5 — СЕКЦИИ ВИДА ИСТОЧНИКА `singbox`.
///
/// Секции порождены механически (норма `MAPPER_ENGINE.md` §8a, ответ
/// лаунчера на находку 7 LxBox: «да, генерируйте»), поэтому проверяет их
/// ЛИНТЕР ФОРМЫ, а не ревью глазами.
///
/// **Граница волны.** `parseSingboxEntry` — читатель тела в модель — и форма
/// хранения `rawSource` (§454–§456) не меняются ни строкой: секция `singbox`
/// работает ПЕРЕД санитайзером, как нормализатор диалекта. Поэтому тут нет
/// сверки тел: сверять нечего, тела строит прежний код.
const _registryRoot = 'assets/contract';
const _draftRoot = 'assets/contract_draft';

/// Типы тела, которые узлом НЕ становятся: группа и цепочка — способ
/// собрать документ, а не запись сервера.
const _notNodes = {'group', 'chain'};

/// Живые элементы sing-box-документа: по одному на каждый вид тела, в том
/// виде, в каком их присылают подписки.
final Map<String, Map<String, dynamic>> _elements = {
  'trojan': {'type': 'trojan', 'server': 'h', 'server_port': 443},
  'vless': {'type': 'vless', 'server': 'h', 'server_port': 443, 'uuid': 'u'},
  'vmess': {'type': 'vmess', 'server': 'h', 'server_port': 443, 'uuid': 'u'},
  'shadowsocks': {
    'type': 'shadowsocks',
    'server': 'h',
    'server_port': 8388,
    'method': 'aes-256-gcm',
  },
  'shadowsocks (синоним типа)': {'type': 'ss', 'server': 'h'},
  'hysteria2': {'type': 'hysteria2', 'server': 'h', 'server_port': 443},
  'tuic': {'type': 'tuic', 'server': 'h', 'server_port': 443},
  'anytls': {'type': 'anytls', 'server': 'h', 'server_port': 443},
  'socks': {'type': 'socks', 'server': 'h', 'server_port': 1080},
  'http': {'type': 'http', 'server': 'h', 'server_port': 8080},
  'ssh': {'type': 'ssh', 'server': 'h', 'server_port': 22},
  'naive': {'type': 'naive', 'server': 'h', 'server_port': 443},
  'masque': {'type': 'masque', 'server': 'h', 'server_port': 443},
  'wireguard (outbound)': {'type': 'wireguard', 'server': 'h'},
  'wireguard (endpoint с peers[])': {
    'type': 'wireguard',
    'address': ['10.0.0.2/32'],
    'peers': [
      {'address': 'h', 'port': 51820, 'public_key': 'k'}
    ],
  },
};

void main() {
  final mirrored = Directory('$_registryRoot/registry').existsSync();
  final skip = mirrored ? null : 'зеркало реестра не найдено';

  setUpAll(loadEngineSections);

  test('секция singbox есть у каждого вида тела, который бывает узлом', () {
    final have = MapperSections.I.typesFor('singbox').toSet();
    final missing = <String>[];
    for (final name in ContractRegistry.I.protocolNames) {
      if (_notNodes.contains(name)) continue;
      final proto = ContractRegistry.I.rawProtocol(name);
      if (((proto?['body'] as Map?)?['fields']) == null) continue;
      if (!have.contains(name)) missing.add(name);
    }
    expect(missing, isEmpty,
        reason: 'без секции элемент документа никому не принадлежит: '
            '${missing.join(", ")}');
  }, skip: skip);

  test('форма секции — норма §8a: detect, body_source, ровно одна ветка '
      'default, unknown_key.action = keep', () {
    final bad = <String>[];
    for (final type in MapperSections.I.typesFor('singbox')) {
      final s = MapperSections.I.sectionFor('singbox', type);
      if (s == null) {
        bad.add('$type: секция не построилась');
        continue;
      }
      if (s.detect == null) bad.add('$type: нет detect');
      if (s.bodySource != 'singbox') {
        bad.add('$type: body_source=${s.bodySource}, ожидался singbox');
      }
      // `keep`, а не `drop`: чужой ключ может быть расширением форка.
      if (s.unknownKeyAction != 'keep') {
        bad.add('$type: unknown_key.action=${s.unknownKeyAction}');
      }
      if (s.unknownKeyCode == null) bad.add('$type: нет unknown_key.code');
      final defaults =
          s.forms.where((f) => f.detect?['default'] == true).length;
      if (defaults != 1) {
        bad.add('$type: веток default $defaults, норма требует ровно одну');
      }
      // Записи появляются ТОЛЬКО там, где диалект есть. Пустая `params` —
      // нормальное конечное состояние, и требовать записей нельзя.
    }
    expect(bad, isEmpty, reason: bad.join('\n'));
  }, skip: skip);

  test('каждый элемент документа опознаётся РОВНО одной секцией', () {
    final bad = <String>[];
    for (final e in _elements.entries) {
      final hits = MapperSections.I.matchJsonAll('singbox', e.value);
      if (hits.length == 1) continue;
      bad.add('${e.key}: ${hits.isEmpty ? "ни одной" : hits.map((s) => s.singboxType).join(", ")}');
    }
    expect(bad, isEmpty,
        reason: 'ноль или две секции на элемент — тот же сниффер, только в '
            'данных:\n${bad.join("\n")}');
  }, skip: skip);

  test('разъезд уровней: peers[] выбирает форму endpoint, плоский — outbound',
      () {
    final s = MapperSections.I.sectionFor('singbox', 'wireguard');
    expect(s, isNotNull);
    final endpoint = s!.forms.firstWhere((f) => f.id == 'endpoint');
    expect(endpoint.level, 'endpoint');
    final outbound = s.forms.firstWhere((f) => f.id == 'outbound');
    expect(outbound.level, 'outbound');
    // Порядок нормативен: точный предикат идёт РАНЬШЕ ветки «всё остальное»,
    // иначе `default` перехватил бы элемент с peers[].
    expect(s.forms.indexOf(endpoint), lessThan(s.forms.indexOf(outbound)));
  }, skip: skip);

  // §533 / контракт 1.1.53 (§49 п.9) — ЧЕРНОВИКА `singbox/` БОЛЬШЕ НЕТ:
  // контракт забрал все 13 секций в реестр (`mappers.singbox` у каждой
  // схемы), и при исполняемой секции реестра загрузчик берёт реестр.
  // Прежний тест требовал у каждого файла пометку `_generated` и пустую
  // `params`; теперь проверяется обратное — что каталог не вернулся. Копия
  // рядом с исполняемой секцией реестра молча проигрывает ей и протухает
  // незаметно, то есть ровно та ловушка, из-за которой файлы и сняты.
  test('черновика singbox/ нет: секции приехали реестром', () {
    expect(Directory('$_draftRoot/singbox').existsSync(), isFalse,
        reason: 'каталог $_draftRoot/singbox вернулся. Секции mappers.singbox '
            'несёт РЕЕСТР (контракт 1.1.53); копия рядом с исполняемой '
            'секцией реестра загрузчиком игнорируется и становится вторым '
            'источником правды. Отступление объявляется записями params '
            'оверлея, а не полной копией секции');
    for (final type in _elements.values.map((e) => '${e['type']}')) {
      final resolved = type == 'ss' ? 'shadowsocks' : type;
      expect(MapperSections.I.has('singbox', resolved), isTrue,
          reason: 'секция singbox/$resolved обязана приезжать РЕЕСТРОМ');
    }
  }, skip: skip);
}
