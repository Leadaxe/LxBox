import 'dart:convert' show jsonDecode, jsonEncode;

import '../../models/node_warning.dart' show RegistryWarning;
import '../contract/body_edit.dart' show applyRegistryEdits, editBodyPath;
import '../contract/body_sanitizer.dart' show yieldToManaged;

/// Контракт 1.1.65 / 1.1.84 (§81) — тело [body], которому сборка (или
/// probe-конфиг) назначила `detour`: поля, уступающие ему по связи
/// `conflicts {with: detour}` реестра (`listen_port` WireGuard,
/// `tls.fragment`), снимаются с кодом связи ([yieldToManaged]).
///
/// Вслед за снятым `tls.fragment` уходит осиротевший
/// `tls.fragment_fallback_delay`, если `record_fragment` не задан: пауза
/// без фрагментации ядру ни к чему.
///
/// §577 — [authored]: правки идут через точку правки (`body_edit.dart`) по
/// копии тела. `listen_port` при `detour` — жёсткое (`core_rejects`: ядро
/// отказывает конфигу), `tls.fragment` — мягкое: остаётся, код с
/// `applied: false`.
List<RegistryWarning> yieldToBuildDetour(
  Map<String, dynamic> body, {
  bool authored = false,
}) {
  final edited = authored
      ? (jsonDecode(jsonEncode(body)) as Map).cast<String, dynamic>()
      : body;
  final ws = yieldToManaged(edited, 'detour');
  final out = applyRegistryEdits(
    body,
    scheme: '${body['type'] ?? ''}',
    authored: authored,
    edited: edited,
    warnings: ws,
  );
  final fragmentGone =
      out.any((w) => w.path == 'tls.fragment' && w.applied);
  if (fragmentGone) {
    final tls = body['tls'];
    if (tls is Map<String, dynamic> &&
        tls.containsKey('fragment_fallback_delay') &&
        tls['record_fragment'] != true) {
      editBodyPath(
        body,
        authored: authored,
        code: 'detour_with_tls_fragment',
        path: 'tls.fragment_fallback_delay',
        remove: true,
      );
    }
  }
  return out;
}
