import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/node_warning.dart';
import 'package:lxbox/models/stop_reason.dart';
import 'package:lxbox/models/ui_msg.dart';
import 'package:lxbox/models/validation.dart';
import 'package:lxbox/services/l10n/get_local_text.dart';
import 'package:lxbox/services/l10n/plural_resolver.dart';

// §285 — sealed UiMsg: равенство по данным, рендер по локали (через
// GetLocalText, не ARB), стабильность renderEn() (machine-поверхности не
// зависят от активной локали). `_ru` — реальный словарь assets/l10n/ru/ui.json.
GetLocalText _loadRu() {
  final raw = File('assets/l10n/ru/ui.json').readAsStringSync();
  final dict = jsonDecode(raw) as Map<String, dynamic>;
  return GetLocalText(dict, const RuPluralResolver());
}

void main() {
  final ru = _loadRu();

  group('render — обе локали', () {
    test('PrefixedMsg: payload проходит verbatim в обеих локалях', () {
      const m = PrefixedMsg(ErrPrefix.fileError, RawMsg('ENOENT'));
      expect(m.renderEn(), 'File error: ENOENT');
      expect(m.renderWith(ru), contains('ENOENT'));
    });
  });

  group('renderEn() — пиненный английский', () {
    test('renderEn() всегда английский, независимо от локали', () {
      const msgs = <UiMsg>[
        ErrMsg(ErrKey.connectionTimedOut),
        PrefixedMsg(ErrPrefix.switchFailed, RawMsg('boom')),
        TimeoutError(10000),
        SubStatusFetching(),
        HttpStatusMsg(503),
        StopReasonMsg(StopRevoked()),
      ];
      // renderEn() не зависит ни от какого внешнего состояния локали.
      for (final m in msgs) {
        expect(m.renderEn(), isNot(contains(RegExp('[а-яА-ЯёЁ]'))));
      }
      // NodeWarning/ValidationIssue/StopReason — та же гарантия.
      expect(const UnknownObfsWarning('junk').renderEn(), contains('junk'));
      expect(const EmptyUrltestGroup('auto').renderEn(),
          'URL-test group "auto" has no outbounds.');
      expect(const StopError('x').renderEn(), 'Stopped: x');
    });
  });
}
