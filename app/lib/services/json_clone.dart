import 'dart:convert';

/// Deep-clone / deep-equality helpers for decoded-JSON trees.
///
/// All sing-box config fragments, settings snapshots and preset bodies are
/// JSON-serializable, so an encode→decode round-trip is the canonical
/// structural copy. Centralized here (§089 P6) — previously hand-rolled as
/// `_deepCopy` (build_config, preset_expand), `_deepClone` (backup_service),
/// inline `jsonDecode(jsonEncode(...))` (backup_tun), and a recursive
/// `_deepEquals` duplicated in preset_expand + rule_set_registry.

/// Deep-copy a JSON-shaped map (values must be JSON-serializable).
Map<String, dynamic> deepCopyJson(Map<String, dynamic> src) =>
    jsonDecode(jsonEncode(src)) as Map<String, dynamic>;

/// Deep-copy any JSON value (Map / List / scalar / null). Null-safe.
Object? deepCloneJson(Object? v) =>
    v == null ? null : jsonDecode(jsonEncode(v));

/// Structural deep-equality over nested Map/List/scalar trees.
/// `mapEquals`/`listEquals` don't recurse into nested collections; this does.
bool deepEqualsJson(dynamic a, dynamic b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k)) return false;
      if (!deepEqualsJson(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deepEqualsJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
