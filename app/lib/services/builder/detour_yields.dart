import '../../models/node_warning.dart' show RegistryWarning;
import '../contract/body_sanitizer.dart' show yieldToManaged;

/// Контракт 1.1.65 / 1.1.84 (§81) — тело [body], которому сборка (или
/// probe-конфиг) назначила `detour`: поля, уступающие ему по связи
/// `conflicts {with: detour}` реестра (`listen_port` WireGuard,
/// `tls.fragment`), снимаются с кодом связи ([yieldToManaged]).
///
/// Вслед за снятым `tls.fragment` уходит осиротевший
/// `tls.fragment_fallback_delay`, если `record_fragment` не задан: пауза
/// без фрагментации ядру ни к чему.
List<RegistryWarning> yieldToBuildDetour(Map<String, dynamic> body) {
  final ws = yieldToManaged(body, 'detour');
  if (ws.any((w) => w.path == 'tls.fragment')) {
    final tls = body['tls'];
    if (tls is Map<String, dynamic> && tls['record_fragment'] != true) {
      tls.remove('fragment_fallback_delay');
    }
  }
  return ws;
}
