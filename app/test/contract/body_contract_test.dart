import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/contract/registry.dart';
import 'package:lxbox/services/contract/warning_codes.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

import 'corpus_warnings.dart';

// Конформанс-раннер корпуса ТЕЛ подписки (SPEC 103, фаза 2), сторона LxBox.
// Аналог core/config/contract_body_test.go — гоняет тот же
// contract/corpus/body/**/*.body через decode() → parseAll() и сравнивает
// состав узлов с ожиданиями лаунчера.
//
// Сравнивается СОСТАВ (схема + сервер + порт), а не полный конверт: эмиссия
// сторон нормируется корпусом URI, а здесь проверяется классификация тела и
// то, что ни один узел не потерян. Иначе один и тот же дефект ловился бы
// дважды, а падал бы в обоих местах — и чинить пришлось бы вслепую.
//
// D-088 / §404 — к составу добавлена ОТБРАКОВКА (`dropped[]`). Пустой
// `nodes[]` без `dropped[]` и пустой с ним — разные вещи: первое значит «тело
// не распознано», второе «запись узнана и отвергнута». Без сверки `dropped`
// кейс `xray/dialer_proxy_missing` проходил бы и при молчаливой потере узла,
// то есть ровно при том дефекте, ради которого он и заведён.

const _contractRoot = kContractRoot;

/// Имя этой стороны в `meta.extension` (corpus/README).
const _thisSide = 'lxbox';

/// Тело фикстуры без ведущих строк-комментариев (contract/corpus/README).
///
/// Комментарии режутся ТОЛЬКО сверху: '#' внутри тела — часть данных
/// (комментарий провайдера в URI-списке, fragment в URI).
String _readCorpusBody(File file) {
  final lines = file.readAsLinesSync();
  var start = 0;
  while (start < lines.length && lines[start].trimLeft().startsWith('#')) {
    start++;
  }
  return lines.sublist(start).join('\n');
}

/// Каноническое имя схемы (contract/registry/protocols/*.json → "scheme").
///
/// Dart зовёт протокол по типу sing-box ("shadowsocks"), канон корпуса — по
/// имени схемы URI ("ss"). Расхождение историческое и на поведение не влияет,
/// но подписи узлов без приведения не сходятся.
String _canonScheme(String protocol) => switch (protocol) {
      'shadowsocks' => 'ss',
      _ => protocol,
    };

/// Короткая подпись узла для сравнения состава.
String _nodeSignature(NodeSpec spec) {
  final SingboxEntry raw = spec.emit(TemplateVars.empty);
  final map = raw.map;
  final server = map['server'] ?? _wgPeerServer(map) ?? '';
  final port = map['server_port'] ?? _wgPeerPort(map) ?? 0;
  return '${_canonScheme(spec.protocol)}|$server|$port';
}

/// WireGuard держит адрес сервера внутри peers[], а не на верхнем уровне.
Object? _wgPeerServer(Map<String, dynamic> map) {
  final peers = map['peers'];
  if (peers is List && peers.isNotEmpty && peers.first is Map) {
    return (peers.first as Map)['address'];
  }
  return null;
}

Object? _wgPeerPort(Map<String, dynamic> map) {
  final peers = map['peers'];
  if (peers is List && peers.isNotEmpty && peers.first is Map) {
    return (peers.first as Map)['port'];
  }
  return null;
}

/// Подписи узлов из ожиданий лаунчера (`<case>.expected.json`).
List<String> _expectedSignatures(Map<String, dynamic> data) {
  final nodes = (data['nodes'] as List?) ?? const [];
  final out = <String>[];
  for (final n in nodes) {
    final node = n as Map<String, dynamic>;
    final entry = (node['entry'] as Map?)?.cast<String, dynamic>() ?? {};
    final server = entry['server'] ?? _wgPeerServer(entry) ?? '';
    final port = entry['server_port'] ?? _wgPeerPort(entry) ?? 0;
    out.add('${node['scheme']}|$server|$port');
  }
  return out;
}

/// Отбраковка из ожидания: нормативны `ref` и `code`, `reason` — НЕТ
/// (corpus/README «Отбраковки и meta.extension», D-088). `reason` — текст
/// СТОРОНЫ: у лаунчера формат ошибки Go, у LxBox свой, и побайтовая сверка
/// заставила бы вторую сторону копировать чужие строки.
///
/// `code` необязателен: ожидание без него проверяется только по `ref`.
List<String> _expectedDropped(Map<String, dynamic> data) {
  final out = <String>[];
  for (final d in (data['dropped'] as List?) ?? const []) {
    final rec = (d as Map).cast<String, dynamic>();
    final code = rec['code'];
    out.add(code == null ? '${rec['ref']}' : '${rec['ref']}|$code');
  }
  return out..sort();
}

/// `ref` отбраковки у JSON-тел — ТЕГ отвергнутого outbound'а (corpus/README),
/// а не его человеческое имя: `label` приходит из `remarks` ЭЛЕМЕНТА и на
/// многоузловом элементе одинаков у всех узлов, опознать по нему конкретную
/// запись нельзя. Тег пуст только когда провайдер его не дал — тогда
/// единственное, чем запись можно назвать, это label.
String _droppedRef(NodeWarning w) => switch (w) {
      DialerProxyUnusableWarning(:final ownerTag, :final label) =>
        ownerTag.isNotEmpty ? ownerTag : label,
      // §477 — запись, снятую реестром целиком (`on_invalid: drop_node`),
      // называет тег, который проход по дословной карте приписал коду.
      RegistryWarning(:final ownerTag) when ownerTag.isNotEmpty => ownerTag,
      _ => w.runtimeType.toString(),
    };

/// Цепочка хопов узла как список label'ов, ближний хоп первым (CANON §2.2).
List<String> _chainLabels(NodeSpec spec) {
  final out = <String>[];
  for (var hop = spec.chained; hop != null; hop = hop.chained) {
    out.add(hop.label);
  }
  return out;
}

List<String> _expectedChainLabels(Map<String, dynamic> node) {
  final out = <String>[];
  var chain = node['chain'];
  while (chain is List && chain.isNotEmpty) {
    final hop = (chain.first as Map).cast<String, dynamic>();
    out.add('${hop['label'] ?? ''}');
    chain = hop['chain'];
  }
  return out;
}

/// §470 — узлы, чьи `warnings[]` сторона пока не сверяет по известной причине:
/// `<кейс>|<подпись узла>` → причина.
///
/// Ожидание НЕ подгоняется и override не заводится (override живёт у
/// лаунчера): запись означает задокументированное расхождение по существу и
/// снимается вместе с работой, которая его закрывает. Образец — `_pendingCases`
/// backup-раннера и `_overrideIgnored` §465.
///
/// ПУСТ: при включении сверки (§470) покраснели четыре узла, и все четыре —
/// одна причина, разрыв между разбором и гардом сборки, плюс один наш дефект
/// (`unknown_key` без `value`). Расхождений по существу не нашлось. §472 шаг 1
/// закрыл и разрыв: коды дословного тела ставит сам разбор, и раннер читает
/// один `node.warnings`.
const Map<String, String> _pendingWarningNodes = {};

void main() {
  final root = Directory('$_contractRoot/corpus/body');
  if (!root.existsSync()) {
    // Контракт не синхронизирован — прогон пропускается, а не падает.
    return;
  }

  final cases = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.body'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  group('contract corpus: subscription bodies', () {
    setUpAll(() async {
      if (Directory('$_contractRoot/registry').existsSync()) {
        await ContractRegistry.I.loadFromDirectory(_contractRoot);
      }
    });

    for (final file in cases) {
      final name = file.path.substring(root.path.length + 1);
      final base = file.path.substring(0, file.path.length - '.body'.length);
      test(name, () {
        // Per-app override читается так же, как в URI-раннере: он означает
        // задокументированное by-design различие (IDENTITY §4a), а его
        // отсутствие — что нормативна общая база.
        final overrideFile = File('$base.expected.lxbox.json');
        final baseFile = File('$base.expected.json');
        final expectedFile =
            overrideFile.existsSync() ? overrideFile : baseFile;
        if (!expectedFile.existsSync()) {
          markTestSkipped('нет ожиданий лаунчера: ${baseFile.path}');
          return;
        }

        final expected =
            jsonDecode(expectedFile.readAsStringSync()) as Map<String, dynamic>;

        // Кейс схемы, которой у этой стороны нет по контракту
        // (corpus/README: `meta.extension`). Пропускается ЦЕЛИКОМ — падение
        // на протоколе, которого мы не обязаны поддерживать, ничего не
        // проверяет и прячет настоящие расхождения.
        final ext = (expected['meta'] as Map?)?['extension'];
        if (ext is String && ext.isNotEmpty && ext != _thisSide) {
          markTestSkipped('meta.extension=$ext — схемы у LxBox нет');
          return;
        }

        final decoded = decode(_readCorpusBody(file));
        final dropped = <NodeWarning>[];
        final specs = parseAll(decoded, dropped: dropped);

        final got = specs.map(_nodeSignature).toList()..sort();
        final want = _expectedSignatures(expected)..sort();
        expect(got, want,
            reason: 'состав узлов тела разошёлся с лаунчером\n'
                '  получено: $got\n  ожидалось: $want');

        // D-088 — отбраковка сверяется по (ref, code); code сравнивается
        // только там, где ожидание его объявило.
        final wantDropped = _expectedDropped(expected);
        final gotDropped = <String>[];
        for (final w in dropped) {
          final code = warningCodeOf(w);
          final ref = _droppedRef(w);
          gotDropped.add(
              wantDropped.any((e) => e == ref) ? ref : '$ref|${code ?? ''}');
        }
        gotDropped.sort();
        expect(gotDropped, wantDropped,
            reason: 'отбраковка (ref/code) разошлась с контрактом');

        // D-085 — канон хопа: тег/label звена = СОБСТВЕННЫЙ тег релея из
        // конфига провайдера, без `⚙`. Маркер §274 значит в конфиге ядра
        // совсем другое, и попасть туда не имеет права.
        final wantNodes =
            ((expected['nodes'] as List?) ?? const []).cast<Map<String, dynamic>>();
        for (final wantNode in wantNodes) {
          final wantChain = _expectedChainLabels(wantNode);
          if (wantChain.isEmpty) continue;
          final entry = (wantNode['entry'] as Map?)?.cast<String, dynamic>() ?? {};
          final sig =
              '${wantNode['scheme']}|${entry['server'] ?? ''}|${entry['server_port'] ?? 0}';
          final spec = specs.firstWhere((s) => _nodeSignature(s) == sig,
              orElse: () => throw StateError('узел $sig не найден'));
          expect(_chainLabels(spec), wantChain,
              reason: 'канон хопа: label звеньев обязан быть сырым тегом '
                  'релея (D-085), без маркера ⚙');
        }

        // §470 — `warnings[]` по тем же правилам, что у URI-раннера
        // (`corpus_warnings.dart`, CANON §6/§7). Узлы ищутся по подписи: у
        // многоузловых тел ожидание и результат уже сверены по составу выше.
        for (final wantNode in wantNodes) {
          final scheme = '${wantNode['scheme']}';
          final entry =
              (wantNode['entry'] as Map?)?.cast<String, dynamic>() ?? {};
          final srv = entry['server'] ?? _wgPeerServer(entry) ?? '';
          final prt = entry['server_port'] ?? _wgPeerPort(entry) ?? 0;
          final sig = '$scheme|$srv|$prt';
          final pending = _pendingWarningNodes['$name|$sig'];
          if (pending != null) {
            markTestSkipped('warnings[] узла $sig: $pending');
            continue;
          }
          final matched = specs.where((s) => _nodeSignature(s) == sig).toList();
          if (matched.isEmpty) continue;

          // §472 шаг 1 — читается ОДИН источник, `node.warnings`. До него
          // раннер склеивал здесь два пути (`_allWarningsOf`): санитайзер при
          // разборе смотрел на `emit()` уже разобранного узла, мусор к тому
          // моменту был снят, и коды дословного тела знал только гард сборки.
          // Теперь санитайзер идёт по дословной карте (`rawSource`) в самом
          // разборе, и раннер сверяет ровно то, что видит пользователь в
          // строке узла.
          final gotW = warningListOf(matched.first.warnings, scheme);
          final gotNode = <String, dynamic>{
            if (gotW.isNotEmpty) 'warnings': gotW,
          };
          final want = deepCopyEnvelope(wantNode) as Map<String, dynamic>;
          normalizeNodeWarnings(gotNode, want);
          normalizeNodeWarnings(want, null);
          final g = canonEncode(gotNode['warnings'] ?? const []);
          final w = canonEncode(want['warnings'] ?? const []);
          if (g != w) {
            fail('warnings[] узла $sig разошлись с контрактом\n'
                '--- got ---\n$g\n--- want ---\n$w');
          }
        }
      });
    }
  });
}
