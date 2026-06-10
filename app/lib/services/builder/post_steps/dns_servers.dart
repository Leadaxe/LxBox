part of '../post_steps.dart';

// ===========================================================================
// §043: DNS servers — refs by kind (симметрия с §061 DNS rules)
// ===========================================================================

/// §043: Auto-discovery + orphan cleanup + legacy migration для
/// `dns_options.servers`. Возвращает список ref-записей шейпа
/// `{enabled, kind: inline|preset|template, tag, body?}` (body только для inline).
///
/// Используется и UI (DnsSettingsScreen) и build-time pipeline'ом — единая
/// точка истины. Persist'ит в storage если результат отличается от raw'а.
///
/// **Resolve order — user → preset → template:**
/// - Walk stored entries; orphan-cleanup'им template/preset entries чьи tag'и
///   не существуют в текущем template / active preset'ах. Inline keep всегда.
/// - Auto-discovery: для каждого preset/template-server'а tag которого нет
///   в storage — append'им новую entry со значением `enabled` из template'а
///   (для template) либо `true` (для preset).
///
/// **Migration с v1.6.0** (legacy full-body snapshot list):
/// - Если каждая запись имеет поле `kind` — already migrated, no-op.
/// - Иначе — каждая запись классифицируется:
///   - tag не в template и не в preset → `kind: inline` с full body (pure user).
///   - tag в template/preset, shape совпадает (modulo `enabled`/`description`)
///     → `kind: template/preset` ref (без body).
///   - tag в template/preset, shape отличается → `kind: inline` с full body
///     (real override).
Future<List<Map<String, dynamic>>> resolveDnsServersList({
  required List<Map<String, dynamic>> templateServers,
  required Map<String, Map<String, dynamic>> presetServersByTag,
}) async {
  final raw = await SettingsStorage.getDnsServers();
  final templateByTag = <String, Map<String, dynamic>>{
    for (final s in templateServers)
      if (s['tag'] is String && (s['tag'] as String).isNotEmpty)
        s['tag'] as String: s,
  };

  // Step 1: legacy migration (full-body snapshot → kind-refs).
  final stored = _migrateLegacyDnsServers(raw, templateByTag, presetServersByTag);

  // Step 2: filter / orphan-cleanup, preserving user order.
  final result = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final raw in stored) {
    final entry = Map<String, dynamic>.from(raw);
    final kind = entry['kind'] as String?;
    final tag = entry['tag']?.toString();
    if (kind == null || tag == null || tag.isEmpty) continue;
    if (seen.contains(tag)) continue;
    if (kind == 'inline') {
      if (entry['body'] is! Map) continue; // malformed
      result.add(entry);
      seen.add(tag);
    } else if (kind == 'template') {
      if (!templateByTag.containsKey(tag)) continue; // orphan
      result.add(entry);
      seen.add(tag);
    } else if (kind == 'preset') {
      if (!presetServersByTag.containsKey(tag)) continue; // orphan
      result.add(entry);
      seen.add(tag);
    }
    // Other kinds (legacy, unknown) — silently dropped, auto-discovery восстановит
  }

  // Step 3: auto-discover missing preset entries (preset > template priority).
  for (final tag in presetServersByTag.keys) {
    if (seen.contains(tag)) continue;
    result.add({'enabled': true, 'kind': 'preset', 'tag': tag});
    seen.add(tag);
  }
  // Step 4: auto-discover missing template entries (наследуют enabled из template).
  for (final s in templateServers) {
    final tag = s['tag']?.toString();
    if (tag == null || tag.isEmpty) continue;
    if (seen.contains(tag)) continue;
    final enabled = s['enabled'] != false;
    result.add({'enabled': enabled, 'kind': 'template', 'tag': tag});
    seen.add(tag);
  }

  // Step 5: persist if changed (deep-equality чтобы не писать на каждый load).
  if (!const DeepCollectionEquality().equals(raw, result)) {
    await SettingsStorage.saveDnsServers(result);
  }
  return result;
}

/// §044: Migration helper. Приводит storage-entries к §044 schema:
/// `{kind, enabled, tag, description?, body?}` где body — partial sing-box
/// shape БЕЗ полей `tag`/`description`/`enabled`.
///
/// Поддерживает три исходных state'а (auto-detect):
/// - **pre-§043** (legacy full-body snapshot, нет поля `kind`):
///   classify by canonical match → конвертируем в kind-ref;
///   для inline — peel `description` на ref-level, body partial.
/// - **§043 inline с полями tag/description/enabled внутри body**:
///   peel `description` → ref-level; drop body's `tag`/`description`/`enabled`.
/// - **§043 template/preset ref / уже §044**:
///   no-op (уже корректная форма).
///
/// Lossless: user data не теряется. Persist'ит только если что-то изменилось
/// (см. caller).
List<Map<String, dynamic>> _migrateLegacyDnsServers(
  List<Map<String, dynamic>> raw,
  Map<String, Map<String, dynamic>> templateByTag,
  Map<String, Map<String, dynamic>> presetServersByTag,
) {
  if (raw.isEmpty) return raw;

  final out = <Map<String, dynamic>>[];
  for (final s in raw) {
    final tag = s['tag']?.toString();
    if (tag == null || tag.isEmpty) continue;
    final kind = s['kind']?.toString();

    if (kind == null) {
      // pre-§043: classify by canonical match
      final tpl = templateByTag[tag];
      final preset = presetServersByTag[tag];
      final canonical = preset ?? tpl; // preset > template
      final canonicalKind =
          preset != null ? 'preset' : (tpl != null ? 'template' : null);
      final enabled = s['enabled'] != false;
      if (canonical == null) {
        // Pure custom — kind: inline с peeled description + partial body
        out.add(_makeInlineRef(s, tag, enabled));
      } else if (_serverShapesMatch(s, canonical)) {
        // Snapshot canonical — kind ref без body
        out.add({'enabled': enabled, 'kind': canonicalKind!, 'tag': tag});
      } else {
        // Real override — kind: inline
        out.add(_makeInlineRef(s, tag, enabled));
      }
    } else if (kind == 'inline') {
      // Уже kind-ref. Проверяем — если body содержит tag/description/enabled
      // (это § 043 shape), peel'им их.
      final bodyRaw = s['body'];
      final body =
          bodyRaw is Map ? Map<String, dynamic>.from(bodyRaw) : <String, dynamic>{};
      final needsPeel = body.containsKey('tag') ||
          body.containsKey('description') ||
          body.containsKey('enabled');
      if (needsPeel) {
        final ref = <String, dynamic>{
          'enabled': s['enabled'] != false,
          'kind': 'inline',
          'tag': tag,
        };
        // Peel description на ref-level (§044 хранит здесь).
        // Если на ref'е уже есть description — не перезаписываем (user-set takes precedence).
        final descFromBody = body['description']?.toString();
        final descOnRef = s['description']?.toString();
        if (descOnRef != null && descOnRef.isNotEmpty) {
          ref['description'] = descOnRef;
        } else if (descFromBody != null && descFromBody.isNotEmpty) {
          ref['description'] = descFromBody;
        }
        // Strip body fields, что live на ref'е.
        body.remove('tag');
        body.remove('description');
        body.remove('enabled');
        // Strip UI annotations если протекли.
        body.remove('_origin');
        body.remove('_overrides');
        body.remove('_preset_label');
        ref['body'] = body;
        out.add(ref);
      } else {
        // Already §044 shape — просто пропускаем как есть.
        out.add(s);
      }
    } else {
      // kind: template / preset / другое — без изменений.
      out.add(s);
    }
  }
  return out;
}

/// Создаёт §044 inline ref из pre-§043 full-body snapshot'а:
/// peel description на ref-level, body partial без tag/description/enabled.
Map<String, dynamic> _makeInlineRef(
    Map<String, dynamic> snapshot, String tag, bool enabled) {
  final ref = <String, dynamic>{
    'enabled': enabled,
    'kind': 'inline',
    'tag': tag,
  };
  final desc = snapshot['description']?.toString();
  if (desc != null && desc.isNotEmpty) {
    ref['description'] = desc;
  }
  final body = Map<String, dynamic>.from(snapshot)
    ..remove('tag')
    ..remove('description')
    ..remove('enabled')
    ..remove('_origin')
    ..remove('_overrides')
    ..remove('_preset_label');
  ref['body'] = body;
  return ref;
}

/// Deep-equality по server shape (без mutable meta + UI-аннотаций).
/// Order-insensitive — для сравнения pre-§043 snapshot'а с canonical.
bool _serverShapesMatch(Map<String, dynamic> a, Map<String, dynamic> b) {
  return const DeepCollectionEquality()
      .equals(_stripMetaForCompare(a), _stripMetaForCompare(b));
}

Map<String, dynamic> _stripMetaForCompare(Map<String, dynamic> m) {
  final out = Map<String, dynamic>.from(m);
  out.remove('enabled');
  out.remove('description');
  out.remove('_origin');
  out.remove('_overrides');
  out.remove('_preset_label');
  return out;
}

/// §043 + §044: Resolves ref-list в final list of sing-box server bodies для
/// `config.dns.servers`.
///
/// Source резолва:
/// - `kind: inline` → `entry.body` (partial, без tag/description/enabled — §044).
/// - `kind: template` → lookup `templateByTag[entry.tag]` (full canonical).
/// - `kind: preset` → lookup `presetServersByTag[entry.tag]`.
///
/// Synthesis (запротоколированная магия §044):
/// - `body['tag'] = entry.tag` — single source of truth, инжект из ref'а.
/// - Strip `description` / `enabled` (sing-box их не использует) из body
///   независимо от source'а.
/// - Filter `enabled != false` на уровне ref'а (вычитаем disabled-серверы).
List<Map<String, dynamic>> resolveDnsServersBodies({
  required List<Map<String, dynamic>> resolved,
  required Map<String, Map<String, dynamic>> templateByTag,
  required Map<String, Map<String, dynamic>> presetServersByTag,
}) {
  final out = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final entry in resolved) {
    if (entry['enabled'] == false) continue;
    final kind = entry['kind'] as String?;
    final tag = entry['tag']?.toString();
    if (kind == null || tag == null || tag.isEmpty) continue;
    if (seen.contains(tag)) continue;
    Map<String, dynamic>? body;
    if (kind == 'inline') {
      final b = entry['body'];
      if (b is Map) body = Map<String, dynamic>.from(b);
    } else if (kind == 'template') {
      final t = templateByTag[tag];
      if (t != null) body = Map<String, dynamic>.from(t);
    } else if (kind == 'preset') {
      final p = presetServersByTag[tag];
      if (p != null) body = Map<String, dynamic>.from(p);
    }
    if (body == null) continue;
    body
      ..remove('enabled')
      ..remove('description')
      ..remove('_preset_label')
      ..remove('_origin')
      ..remove('_overrides');
    body['tag'] = tag; // ensure tag set (даже если body lost его при edit'е)
    out.add(body);
    seen.add(tag);
  }
  return out;
}
