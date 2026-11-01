import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/mixin.dart';
import 'package:lxbox/services/lx_backup.dart';
import 'package:lxbox/services/lx_backup_import.dart';

/// §704 §6 — секция `mixins` LX Backup: экспорт без `id`, разбор с новыми
/// `id`, импорт в конец списка, совпадение по телу — пропуск.
void main() {
  final a = Mixin(
    id: 'a',
    name: 'DNS listener',
    target: 'inbounds',
    op: 'append',
    value: {
      'type': 'direct',
      'tag': 'dns-in',
      'nested': {'any': 'key'},
    },
  );
  final b = Mixin(
    id: 'b',
    enabled: false,
    target: 'route.rules[action=hijack-dns]',
    op: 'before',
    value: {
      'inbound': ['dns-in'],
      'action': 'hijack-dns',
    },
  );

  Future<String> export(List<Mixin> mixins) async =>
      (await buildLxBackup(lists: const [], rules: const [], vars: const {},
              mixins: mixins))
          .json;

  test('экспорт: секция после warp, без id; пустой список — ключа нет', () async {
    final doc = jsonDecode(await export([a, b])) as Map<String, dynamic>;
    final list = doc['mixins'] as List;
    expect(list, hasLength(2));
    expect(list[0], a.toBackupJson());
    expect((list[0] as Map).containsKey('id'), isFalse);
    expect(doc.keys.last, 'mixins');
    final empty = jsonDecode(await export(const [])) as Map<String, dynamic>;
    expect(empty.containsKey('mixins'), isFalse);
  });

  test('разбор: новые id, поля как в файле, value вглубь не обходится',
      () async {
    final file = parseLxBackup(await export([a, b]));
    expect(file.mixins, hasLength(2));
    expect(file.mixins[0].id, isNot('a'));
    expect(file.mixins[0].bodyKey, a.bodyKey);
    expect(file.mixins[1].enabled, isFalse);
    expect(file.warnings.where((w) => w.code == kWarnUnknownField), isEmpty);
  });

  test('неизвестное поле записи и битая запись — предупреждения', () async {
    final doc = jsonDecode(await export([a])) as Map<String, dynamic>;
    (doc['mixins'] as List)
      ..add({'name': 'x', 'target': 'log', 'op': 'set', 'value': 1, 'foo': 1})
      ..add({'name': 'broken', 'op': 'set'});
    final file = parseLxBackup(jsonEncode(doc));
    expect(file.mixins.map((m) => m.name), ['DNS listener', 'x']);
    expect(
        file.warnings.map((w) => '${w.code} ${w.detail}'),
        containsAll([
          '$kWarnUnknownField mixins[x].foo',
          '$kWarnFieldTypeMismatch mixins[2].target',
        ]));
  });

  test('импорт: в конец списка, совпадение по телу — пропуск', () async {
    final raw = await export([a, b, a.copyWith(name: 'same body again')]);
    final mine = Mixin(id: 'mine', target: 'log.level', op: 'set', value: 'warn');
    final plan = planLxBackupImport(
      raw,
      LxImportReceiver(mixins: [mine, a.copyWith(id: 'mine-a', name: 'renamed')]),
    );
    expect(plan.appliedMixins, 1);
    expect(plan.mixins.map((m) => m.id).take(2), ['mine', 'mine-a']);
    expect(plan.mixins.last.bodyKey, b.bodyKey);
    expect(plan.mixins, hasLength(3));
  });

  test('mergeBackupMixins: дубль внутри файла не множится', () {
    final r = mergeBackupMixins(const [], [a, a.copyWith(id: 'z')]);
    expect(r.added, 1);
    expect(r.merged.single.id, 'a');
  });
}
