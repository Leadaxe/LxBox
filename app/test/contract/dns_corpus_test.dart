import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/dns_ref.dart';
import 'package:lxbox/services/builder/core_chain_capability.dart'
    show kDnsGroupHostsMinCoreVersion;
import 'package:lxbox/services/builder/post_steps.dart';

import '../contract_paths.dart';

// Конформанс-раннер корпуса DNS-серверов (SPEC 109 лаунчера), сторона LxBox.
// Тот же набор гоняет лаунчер (`core/build/contract_dns_test.go`).
//
// Вход кейса переводится в нашу модель:
// - запись `dns_options.servers` шаблона — обёртка `{description, enabled,
//   required?, vars?, server}` (§117); плоскую запись (`server` — не объект)
//   раннер заворачивает сам: шаблон LxBox пишет только вложенную форму, и
//   плоскую сервером не читает (`template_loader.dart`);
// - ref-список — как после посева каталога (§680): записи шаблона в его
//   порядке, `enabled` из шаблона, `state[]` перекрывает `enabled` и `vars`.
//
// Дальше — шаг материализации сборки `resolveDnsServersBodies` (тот, что
// зовёт `applyCustomDns`). Загрузка состояния (`resolveDnsServersList`:
// сироты, посев, §695 правило 5 «ссылка держит») — не часть корпуса: состояние
// кейса подаётся как есть. Иначе выключенный член группы включался бы при
// загрузке, и кейсы чистки состава проверяли бы не сборку.
//
// Нормативны состав тел и порядок серверов; порядок ключей тела — нет.

/// Кейсы, которые сторона не проходит по известной причине.
const Map<String, String> _pendingCases = {
  'group_empty_after_prune_dropped':
      'LxBox: группа, опустевшая от выключенных или неизвестных членов, '
          'эмитится пустой и блокирует сборку (EmptyDnsGroup, §312 решение '
          '№3); выпадает сама только от висячего detour членов (§443)',
};

void main() {
  if (corpusSuiteUnavailable('test/contract/dns_corpus_test.dart')) {
    return;
  }

  final root = Directory('$kVendorRoot/corpus/dns');
  if (!root.existsSync()) return; // контракт не синхронизирован

  final cases = root
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dns.json'))
      .map((f) => f.path.substring(0, f.path.length - '.dns.json'.length))
      .toList()
    ..sort();

  group('contract corpus: dns', () {
    test('корпус не пуст', () => expect(cases, isNotEmpty));

    for (final base in cases) {
      final name = base.substring(root.path.length + 1);
      test(name, skip: _pendingCases[name], () {
        final input = jsonDecode(File('$base.dns.json').readAsStringSync())
            as Map<String, dynamic>;
        final expected =
            jsonDecode(File('$base.expected.json').readAsStringSync())
                as Map<String, dynamic>;

        final templateServers = [
          for (final s in (input['servers'] as List? ?? const []))
            _wrapper(Map<String, dynamic>.from(s as Map)),
        ];
        final templateByTag = templateDnsServersByTag(templateServers);
        final stateByTag = {
          for (final e in (input['state'] as List? ?? const []))
            (e as Map)['tag'] as String: e,
        };
        final resolved = <DnsServerRef>[
          for (final s in templateServers)
            if (templateDnsServerTag(s) case final tag?)
              DnsServerTemplate(
                tag: tag,
                enabled: stateByTag[tag]?['enabled'] as bool? ??
                    s['enabled'] != false,
                varValues: {
                  for (final v
                      in ((stateByTag[tag]?['vars'] as Map?) ?? const {})
                          .entries)
                    v.key as String: v.value.toString(),
                },
              ),
        ];

        final warnings = <String>[];
        final actual = resolveDnsServersBodies(
          resolved: resolved,
          templateByTag: templateByTag,
          presetServersByTag: const {},
          warningsOut: warnings,
          globalVars: {
            for (final v in ((input['vars'] as Map?) ?? const {}).entries)
              v.key as String: v.value.toString(),
          },
          coreVersion: kDnsGroupHostsMinCoreVersion,
        );

        final want = expected['servers'] as List;
        expect(
          const DeepCollectionEquality().equals(actual, want),
          isTrue,
          reason: '${input['_']}\n'
              'получено: ${jsonEncode(actual)}\n'
              'ожидалось: ${jsonEncode(want)}\n'
              'предупреждения: $warnings',
        );
      });
    }
  });
}

/// Запись шаблона в форме обёртки §117: вложенная — как есть, плоская —
/// служебные поля визарда наверх, остальное в `server`.
Map<String, dynamic> _wrapper(Map<String, dynamic> entry) {
  if (entry['server'] is Map) return entry;
  const wizardKeys = {'description', 'enabled', 'required', 'vars'};
  return {
    for (final k in wizardKeys)
      if (entry.containsKey(k)) k: entry[k],
    'server': {
      for (final e in entry.entries)
        if (!wizardKeys.contains(e.key)) e.key: e.value,
    },
  };
}
