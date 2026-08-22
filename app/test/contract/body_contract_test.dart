import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_spec.dart';
import 'package:lxbox/models/singbox_entry.dart';
import 'package:lxbox/models/template_vars.dart';
import 'package:lxbox/services/parser/body_decoder.dart';
import 'package:lxbox/services/parser/parse_all.dart';

// Конформанс-раннер корпуса ТЕЛ подписки (SPEC 103, фаза 2), сторона LxBox.
// Аналог core/config/contract_body_test.go — гоняет тот же
// contract/corpus/body/**/*.body через decode() → parseAll() и сравнивает
// состав узлов с ожиданиями лаунчера.
//
// Сравнивается СОСТАВ (схема + сервер + порт), а не полный конверт: эмиссия
// сторон нормируется корпусом URI, а здесь проверяется классификация тела и
// то, что ни один узел не потерян. Иначе один и тот же дефект ловился бы
// дважды, а падал бы в обоих местах — и чинить пришлось бы вслепую.

const _contractRoot = 'contract';

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

/// Подписи узлов из ожиданий лаунчера (<case>.expected.json).
List<String> _expectedSignatures(File expected) {
  final data = jsonDecode(expected.readAsStringSync()) as Map<String, dynamic>;
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
    for (final file in cases) {
      final name = file.path.substring(root.path.length + 1);
      test(name, () {
        final expectedFile = File(
            '${file.path.substring(0, file.path.length - '.body'.length)}.expected.json');
        if (!expectedFile.existsSync()) {
          markTestSkipped('нет ожиданий лаунчера: ${expectedFile.path}');
          return;
        }

        final decoded = decode(_readCorpusBody(file));
        final specs = parseAll(decoded);
        final got = specs.map(_nodeSignature).toList()..sort();
        final want = _expectedSignatures(expectedFile)..sort();

        expect(got, want,
            reason: 'состав узлов тела разошёлся с лаунчером\n'
                '  получено: $got\n  ожидалось: $want');
      });
    }
  });
}
