import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/app_log.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

/// §460 W2a — предупреждения реестра на узле при РАЗБОРЕ.
///
/// Воронка одна на все входы — `parseAll` (`services/parser/parse_all.dart`),
/// поэтому тесты идут через неё, а не через внутренний хелпер: проверяется
/// ровно то, что увидит список подписки.
const _contractRoot = 'contract';

/// Узлы из тела любого формата — тот же путь, которым идёт приложение.
List<NodeSpec> _parse(String raw) => parseAll(decode(raw));

NodeSpec _one(String raw) {
  final nodes = _parse(raw);
  expect(nodes, hasLength(1), reason: 'ожидался ровно один узел из $raw');
  return nodes.first;
}

List<RegistryWarning> _registry(NodeSpec n) =>
    n.warnings.whereType<RegistryWarning>().toList();

RegistryWarning _byCode(NodeSpec n, String code) => _registry(n).firstWhere(
      (w) => w.code == code,
      orElse: () => fail(
          'нет кода $code; есть: ${_registry(n).map((w) => '${w.code}@${w.path}').toList()}'),
    );

void main() {
  final synced = Directory('$_contractRoot/registry').existsSync();
  final skip = synced ? null : 'контракт не синхронизирован';

  setUpAll(() async {
    if (!synced) return;
    await ContractRegistry.I.loadFromDirectory(_contractRoot);
  });

  group('§460 W2a — воронка parseAll', () {
    test('URI: мусорный key_share даёт код с путём tls.reality.key_share', () {
      // REALITY-узел с валидным pbk: key_share читается только при нём.
      final n = _one(
        'vless://11111111-1111-1111-1111-111111111111@example.com:443'
        '?security=reality&encryption=none&sni=a.example'
        '&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0'
        '&sid=ab&key_share=garbage&type=tcp#node',
      );
      final w = _byCode(n, 'reality_key_share_invalid');
      expect(w.path, 'tls.reality.key_share');
      expect(w.value, 'garbage');
    }, skip: skip);

    test('JSON: битое значение модельного поля даёт код с путём', () {
      // `uuid` у tuic — поле модели и строка: до эмиссии оно доживает, и
      // санитайзер судит его сам.
      final n = _one('''
{"type":"tuic","tag":"n","server":"example.com","server_port":443,
 "uuid":"not-a-uuid","password":"p","congestion_control":"bbr"}
''');
      final w = _byCode(n, 'type_invalid');
      expect(w.path, 'uuid');
    }, skip: skip);

    // ГРАНИЦА ВОЛНЫ, найдена на этих тестах.
    //
    // Разбор смотрит НЕ на присланное тело, а на `emit()` уже построенного
    // `NodeSpec`, и модель узла — сама по себе фильтр: JSON-парсер кладёт в
    // спеку только то, что у неё есть полем, приводя типы. Поэтому до
    // санитайзера при разборе не доходят ровно два класса мусора:
    //
    //   * ключ, которого у модели нет (`totally_bogus`) — `unknown_key`;
    //   * значение, не прошедшее приведение типа в парсере
    //     (`tls.min_version: 5` числом) — оно снимается там же, молча.
    //
    // Это не дефект W2a: такой мусор не доезжает и до ядра, а дословный
    // JSON-источник (§455) проходит мимо модели и разбирается гардом
    // СБОРКИ, который эти коды и выдаёт. Тест держит границу явной, чтобы
    // «реестр не заметил unknown_key» не читалось как регрессия.
    test('мусор вне модели до разбора не доходит — он снят парсером', () {
      final n = _one('''
{"type":"vless","tag":"n","server":"example.com","server_port":443,
 "uuid":"11111111-1111-1111-1111-111111111111","totally_bogus":1,
 "tls":{"enabled":true,"server_name":"a.example","min_version":5}}
''');
      final emitted = n.emit(TemplateVars.empty).map;
      expect(emitted.containsKey('totally_bogus'), isFalse,
          reason: 'ключ вне модели снял JSON-парсер, а не санитайзер');
      expect((emitted['tls'] as Map).containsKey('min_version'), isFalse,
          reason: 'значение не прошло приведение типа в парсере');
      expect(_registry(n).map((w) => w.code), isNot(contains('unknown_key')));
    }, skip: skip);

    test('разбор тело узла не меняет', () {
      // Узел без мусора: аннотация обязана пройти по нему и не тронуть
      // ничего — чистит по-прежнему гард сборки.
      const raw = 'vless://11111111-1111-1111-1111-111111111111@example.com:443'
          '?security=tls&encryption=none&sni=a.example&type=ws&path=/p#node';
      final before = _one(raw).emit(TemplateVars.empty).map;
      final after = _one(raw).emit(TemplateVars.empty).map;
      expect(jsonEncode(after), jsonEncode(before));
    }, skip: skip);

    test('гейты ядра при разборе выключены: min_core кода не даёт', () {
      // `tls.reality.key_share` несёт min_core 1.14.1-lx.4. Валидное значение
      // при разборе обязано пройти молча — версии ядра здесь ещё нет
      // (24.1.6), и снимать поле разбору нечем.
      final n = _one(
        'vless://11111111-1111-1111-1111-111111111111@example.com:443'
        '?security=reality&encryption=none&sni=a.example'
        '&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0'
        '&sid=ab&key_share=hybrid&type=tcp#node',
      );
      expect(_registry(n).map((w) => w.code), isNot(contains('type_invalid')));
      expect(_registry(n).map((w) => w.code),
          isNot(contains('reality_key_share_invalid')));
    }, skip: skip);

    test('одна пара {code, path} не повторяется', () {
      final n = _one(
        'vless://11111111-1111-1111-1111-111111111111@example.com:443'
        '?security=reality&encryption=none&sni=a.example'
        '&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0'
        '&sid=ab&key_share=garbage&type=tcp#node',
      );
      final pairs = _registry(n).map((w) => '${w.code} ${w.path}').toList();
      expect(pairs, isNotEmpty);
      expect(pairs.toSet().length, pairs.length);
    }, skip: skip);
  });

  group('§460 W2a — дедуп с рукописными кодами', () {
    test('рукописный класс перебивает код реестра на том же коде', () {
      // `flow` вне закрытого набора: парсер ставит DeprecatedFlowWarning
      // (код flow_deprecated), реестр — свой код на том же поле.
      final n = _one(
        'vless://11111111-1111-1111-1111-111111111111@example.com:443'
        '?security=tls&encryption=none&sni=a.example'
        '&flow=xtls-rprx-origin&type=tcp#node',
      );
      final hand = n.warnings.whereType<DeprecatedFlowWarning>().toList();
      expect(hand, isNotEmpty, reason: 'рукописное предупреждение на месте');
      // Реестр тот же код вторым сообщением не дублирует.
      expect(_registry(n).map((w) => w.code), isNot(contains('flow_deprecated')));
    }, skip: skip);

    test('обфускация: рукописный obfs_unknown не дублируется реестром', () {
      final n = _one(
        'hysteria2://pass@example.com:443?obfs=nonsense&obfs-password=p#node',
      );
      final codes = _registry(n).map((w) => w.code).toList();
      if (n.warnings.whereType<UnknownObfsWarning>().isNotEmpty) {
        expect(codes, isNot(contains('obfs_unknown')));
      }
    }, skip: skip);
  });

  group('§460 W2a — цена разбора', () {
    // Аннотация считается на КАЖДОМ узле подписки, поэтому её цена измерена,
    // а не предположена. Замер на рабочей машине (2000 узлов vless+ws+tls,
    // release-прогон `flutter test`):
    //
    //   разбор без реестра        ~42 мс
    //   аннотация сверху          ~95 мс  (≈47 мкс на узел)
    //   схема из кэша, x2000      ~0.7 мс (≈0.3 мкс на вызов)
    //
    // 95 мс однократно на подписку в 2000 узлов — цена обхода 384 полей
    // схемы, и она приемлема: разбор идёт один раз на обновление подписки,
    // не на каждый кадр.
    //
    // Порог ниже сознательно НЕ про проценты: абсолютные миллисекунды
    // на CI-раннере и на ноутбуке несопоставимы, и тест на ±20 % был бы
    // флаки-генератором. Он ловит потерю КЭША схем — единственную регрессию,
    // которая здесь реальна: без `_schemaCache` каждый узел заново
    // раскрывает `ref`-ы (tls + dialer + multiplex), и цена растёт на
    // порядок, а не на проценты.
    test('2000 узлов: схема берётся из кэша, а не раскрывается заново', () {
      const n = 2000;

      // Прогрев кэша и JIT.
      for (var i = 0; i < 50; i++) {
        ContractRegistry.I.schemaFor('vless');
      }

      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        ContractRegistry.I.schemaFor('vless');
      }
      sw.stop();

      // Раскрытие схемы vless — это разбор JSON-секций tls/transports/
      // dialer/multiplex, десятки микросекунд на вызов. Из кэша — доли
      // микросекунды. Порог 20 мс на 2000 вызовов (10 мкс на вызов) лежит
      // между этими режимами с запасом в обе стороны.
      expect(
        sw.elapsedMicroseconds,
        lessThan(20000),
        reason: 'schemaFor перестал кэшировать: ${sw.elapsedMicroseconds}µs '
            'на $n вызовов',
      );
    }, skip: skip);

    test('2000 узлов с предупреждениями разбираются за разумное время', () {
      const n = 2000;
      final body = StringBuffer();
      for (var i = 0; i < n; i++) {
        // Узел с полным телом (tls + ws + fp) — худший случай обхода схемы.
        body.writeln(
          'vless://11111111-1111-1111-1111-111111111111@example.com:443'
          '?security=tls&encryption=none&sni=a.example&type=ws&path=/p'
          '&fp=chrome#node$i',
        );
      }
      final decoded = decode(body.toString());

      expect(parseAll(decoded), hasLength(n)); // прогрев

      final sw = Stopwatch()..start();
      final nodes = parseAll(decoded);
      sw.stop();
      expect(nodes, hasLength(n));

      // Измерено ~130 мс (разбор + аннотация). Потолок 3 с — про «ушло в
      // квадратичность», а не про проценты: на самом медленном CI-раннере
      // запас десятикратный.
      expect(
        sw.elapsedMilliseconds,
        lessThan(3000),
        reason: 'разбор $n узлов с реестром: ${sw.elapsedMilliseconds} мс',
      );
    }, skip: skip);
  });

  group('§460 W2a — secret-поля', () {
    test('битый secret uuid не утекает ни в текст, ни в AppLog', () {
      const secretValue = 'SUPERSECRET-uuid-not-a-uuid-at-all';
      final n = _one('''
{"type":"tuic","tag":"n","server":"example.com","server_port":443,
 "uuid":"$secretValue","password":"p","congestion_control":"bbr"}
''');
      final w = _byCode(n, 'type_invalid');
      expect(w.path, 'uuid');
      expect(w.value, '***', reason: 'значение secret-поля маскируется');

      // Ни одно предупреждение узла не несёт исходного значения.
      for (final warning in n.warnings) {
        expect(warning.renderEn(), isNot(contains(secretValue)));
        expect(warning.message(), isNot(contains(secretValue)));
        expect(warning.toString(), isNot(contains(secretValue)));
      }

      // И лог — тоже: `entries` отдаёт весь буфер сессии (newest first),
      // так что проверка накрывает и всё, что написал разбор.
      for (final e in AppLog.I.entries) {
        expect(e.message, isNot(contains(secretValue)));
      }
    }, skip: skip);
  });
}
