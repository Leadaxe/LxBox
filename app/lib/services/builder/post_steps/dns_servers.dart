part of '../post_steps.dart';

// ===========================================================================
// §043: DNS servers — refs by kind (симметрия с §061 DNS rules)
// §117: template-серверы в обёртке `{description, enabled, vars?, server}`
// ===========================================================================

/// §117: tag template-server-обёртки `{description, enabled, vars?, server}`.
/// Single source of truth — `server.tag` (top-level `tag` больше нет).
String? templateDnsServerTag(Map<String, dynamic> entry) {
  final server = entry['server'];
  if (server is! Map) return null;
  final tag = server['tag'];
  return (tag is String && tag.isNotEmpty) ? tag : null;
}

/// §117: tag → wrapper map для `dns_options.servers` шаблона. Используется
/// и build'ом (applyCustomDns), и UI (DnsSettingsScreen) — единая точка.
Map<String, Map<String, dynamic>> templateDnsServersByTag(
  List<Map<String, dynamic>> templateServers,
) {
  return {
    for (final s in templateServers)
      if (templateDnsServerTag(s) != null) templateDnsServerTag(s)!: s,
  };
}

/// §117: резолв template-обёртки в sing-box server body.
///
/// Deep-copy `server` + подстановка `@var`-плейсхолдеров: значение юзера из
/// `varValues` ref-записи (непустое после подрезки, §441 Н3) → иначе
/// `default_value` определения (пустой → null → ключи с этим `@var`
/// выпадают, семантика §033). Обёртка без `vars` (local_dns_resolver) —
/// чистая копия `server`.
///
/// §441 (SPEC 129 §4.1) — `@name`, которого сервер не объявил, из записи не
/// подставляется: глобальный проход сборки `dns_options` не видит, и литерал
/// `@name` ушёл бы в конфиг. Ключ с таким плейсхолдером выпадает, имя — в
/// [unknownVarsOut] (сборка называет его warning'ом).
///
/// `detour` здесь НЕ нормализуется — это делает caller
/// ([resolveDnsServersBodies] / UI), у которого есть контекст знакомых
/// outbound'ов.
Map<String, dynamic>? resolveTemplateDnsServerBody(
  Map<String, dynamic> wrapper, {
  Map<String, dynamic> varValues = const {},
  List<String>? unknownVarsOut,
}) {
  final server = wrapper['server'];
  if (server is! Map) return null;
  final body = deepCopyJson(Map<String, dynamic>.from(server));
  final varsMap = <String, dynamic>{};
  for (final d
      in (wrapper['vars'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()) {
    final name = d['name']?.toString();
    if (name == null || name.isEmpty) continue;
    final user = varValues[name]?.toString().trim();
    if (user != null && user.isNotEmpty) {
      varsMap[name] = user;
    } else {
      final def = d['default_value']?.toString() ?? '';
      varsMap[name] = def.isEmpty ? null : def;
    }
  }
  final result = walk(body, (name) {
    if (!varsMap.containsKey(name)) {
      unknownVarsOut?.add(name);
      return Dropped.instance;
    }
    final v = varsMap[name];
    return v ?? Dropped.instance;
  });
  return result is Map<String, dynamic> ? result : null;
}

/// §043: Auto-discovery + orphan cleanup для `dns_options.servers`.
///
/// Используется и UI (DnsSettingsScreen) и build-time pipeline'ом — единая
/// точка истины. Persist'ит в storage если результат отличается от
/// сохранённого.
///
/// **Resolve order — user → preset → template:**
/// - Walk stored entries; orphan-cleanup'им template/preset entries чьи tag'и
///   не существуют в текущем template / active preset'ах. Inline keep всегда.
///   Повтор тега — первая запись побеждает.
/// - Auto-discovery: для каждого preset/template-server'а tag которого нет
///   в storage — append'им новую entry со значением `enabled` из template'а
///   (для template) либо `true` (для preset).
///
/// §439 — ключи [presetServersByTag] — теги конфига: у серверов пресета они
/// в пространстве его id (`ru-direct:dns_ru`, `namespacePresetTags`), та же
/// форма, что у [DnsServerPreset.tag] из хранения. [presetIdByTag] (тег
/// сервера → `preset_id` пресета, который его внёс) заполняет
/// [DnsServerPreset.presetId] нового сервера; у сохранённого id берётся из
/// пространства тега.
///
/// §439 A1 — записи, которые кодек не читает (незнакомый вид), сюда не
/// приходят и сохранением не стираются: их держит репозиторий.
Future<List<DnsServerRef>> resolveDnsServersList({
  required List<Map<String, dynamic>> templateServers,
  required Map<String, Map<String, dynamic>> presetServersByTag,
  Map<String, String> presetIdByTag = const {},
}) async {
  final stored = await SettingsStorage.getDnsServers();
  // §117: template-серверы — обёртки `{description, enabled, vars?, server}`,
  // tag живёт в `server.tag`.
  final templateByTag = templateDnsServersByTag(templateServers);

  // Step 1: orphan-cleanup, preserving user order.
  final result = <DnsServerRef>[];
  final seen = <String>{};
  for (final entry in stored) {
    if (seen.contains(entry.tag)) continue;
    final keep = switch (entry) {
      DnsServerInline() => true,
      DnsServerTemplate() => templateByTag.containsKey(entry.tag),
      DnsServerPreset() => presetServersByTag.containsKey(entry.tag),
    };
    if (!keep) continue; // orphan
    result.add(entry);
    seen.add(entry.tag);
  }

  // Step 2: auto-discover missing preset entries (preset > template priority).
  for (final tag in presetServersByTag.keys) {
    if (seen.contains(tag)) continue;
    result.add(DnsServerPreset(
        enabled: true, tag: tag, presetId: presetIdByTag[tag] ?? ''));
    seen.add(tag);
  }
  // Step 3: auto-discover missing template entries (наследуют enabled из template).
  for (final s in templateServers) {
    final tag = templateDnsServerTag(s);
    if (tag == null) continue;
    if (seen.contains(tag)) continue;
    final enabled = s['enabled'] != false;
    result.add(DnsServerTemplate(enabled: enabled, tag: tag));
    seen.add(tag);
  }

  // Step 4: persist if changed (не писать на каждый load).
  if (!const ListEquality<DnsServerRef>().equals(stored, result)) {
    await SettingsStorage.saveDnsServers(result);
  }
  return result;
}

/// §043 + §044 + §117: Resolves ref-list в final list of sing-box server
/// bodies для `config.dns.servers`.
///
/// Source резолва:
/// - `kind: inline` → `entry.body` (partial, без tag/description/enabled — §044).
/// - `kind: template` → `templateByTag[entry.tag]` — обёртка
///   `{description, enabled, vars?, server}`; body = `server` с подставленными
///   `@var`'ами (значения юзера из `entry.varValues` или дефолты — §117).
/// - `kind: preset` → lookup `presetServersByTag[entry.tag]`.
///
/// Synthesis (запротоколированная магия §044):
/// - `body['tag'] = entry.tag` — single source of truth, инжект из ref'а.
/// - Strip `description` / `enabled` (sing-box их не использует) из body
///   независимо от source'а.
/// - Filter `enabled != false` на уровне ref'а (вычитаем disabled-серверы).
///   §117 исключение (lifecycle, locked №7): сервер, реферимый активным
///   пресетом (tag есть в `presetServersByTag`) ИЛИ активным правилом с
///   DNS-опцией (tag в [ruleReferencedTags], задача 3), — **force-include**
///   независимо от `enabled` — иначе DNS-правило ссылается в пустоту.
/// - `detour` нормализуется ([normalizeDnsDetour]): `direct-out` → ключ не
///   пишется (§117 решение №2). §441 (SPEC 129 Н10, вторая линия
///   fail-closed) — `detour` на тег, которого нет в [knownOutboundTags],
///   сервер НЕ эмитит: снятый ключ пустил бы его запросы мимо выбранного
///   маршрута. Тег — в [detourDroppedOut], warning — в [warningsOut]; ссылки
///   на него лечит [healDetourDroppedDnsRefs]. `knownOutboundTags == null` —
///   проверка только на direct-out.
/// - §312: члены DNS-групп (`type: group`) фильтруются пост-проходом по
///   реально эмитированным тегам ([_filterDnsGroupMembers]); каждый дроп —
///   warning в [warningsOut]. Storage НЕ трогается: выключенный член при
///   обратном включении «встаёт на место» (решение юзера §312 №3). §443
///   (SPEC 129 Н10) — группа, опустевшая от членов, выпавших второй линией,
///   выпадает сама и идёт в [detourDroppedOut].
/// - `tailscale` второй линией не выпадает никогда: `detour` у типа нет
///   ([normalizeDnsDetour] снимает ключ), висячий `endpoint` снимает
///   [_sanitizeTailscaleDnsServers] прежним механизмом (NODE_SECTIONS §6).
List<Map<String, dynamic>> resolveDnsServersBodies({
  required List<DnsServerRef> resolved,
  required Map<String, Map<String, dynamic>> templateByTag,
  required Map<String, Map<String, dynamic>> presetServersByTag,
  Set<String>? knownOutboundTags,
  Set<String> ruleReferencedTags = const {},
  List<String>? warningsOut,
  // §435 — серверы узлов (тела с `tag`, после подстановки `@self`): в конец
  // списка ПОСЛЕ корневых refs и ДО фильтра членов групп (иначе сервер узла
  // вылетел бы из группы как `unknown`). Дубль тега — первый побеждает.
  List<Map<String, dynamic>> nodeServers = const [],
  // §435 — эмитированные endpoint'ы `tailscale`: цели поля `endpoint`
  // DNS-сервера того же типа. `null` = проверку не делать (вызовы UI).
  Set<String>? tailscaleEndpointTags,
  // §441 (Н10) — теги серверов, выпавших из-за висячего `detour`.
  Set<String>? detourDroppedOut,
}) {
  final out = <Map<String, dynamic>>[];
  final seen = <String>{};
  final detourDropped = <String>{};
  // §441 (Н10) — висячий detour после подстановки: сервер не эмитится.
  bool dropForDetour(Map<String, dynamic> body, String tag) {
    final dangling = normalizeDnsDetour(body, knownOutbounds: knownOutboundTags);
    if (dangling == null) return false;
    warningsOut?.add(
        'DNS server "$tag" dropped: its detour "$dangling" is not in the config.');
    detourDropped.add(tag);
    detourDroppedOut?.add(tag);
    return true;
  }

  for (final entry in resolved) {
    final tag = entry.tag;
    if (tag.isEmpty) continue;
    if (!entry.enabled &&
        !presetServersByTag.containsKey(tag) &&
        !ruleReferencedTags.contains(tag)) {
      continue;
    }
    if (seen.contains(tag)) continue;
    final unknownVars = <String>[];
    final Map<String, dynamic>? body = switch (entry) {
      DnsServerInline(:final body) => Map<String, dynamic>.from(body),
      DnsServerTemplate(:final varValues) => switch (templateByTag[tag]) {
          final t? => resolveTemplateDnsServerBody(t,
              varValues: varValues, unknownVarsOut: unknownVars),
          null => null,
        },
      DnsServerPreset() => switch (presetServersByTag[tag]) {
          final p? => Map<String, dynamic>.from(p),
          null => null,
        },
    };
    if (body == null) continue;
    for (final name in unknownVars.toSet()) {
      warningsOut?.add('DNS server "$tag": "@$name" is not declared by the '
          'server, the key with it is left out.');
    }
    body
      ..remove('enabled')
      ..remove('description')
      ..remove('_preset_label')
      ..remove('_preset_id')
      ..remove('_origin')
      ..remove('_overrides');
    body['tag'] = tag; // ensure tag set (даже если body lost его при edit'е)
    seen.add(tag);
    if (dropForDetour(body, tag)) continue;
    out.add(body);
  }
  // §435 — серверы узлов: после корневых, дубль тега — первый побеждает с
  // warning'ом (NODE_SECTIONS.md §3 п. 5).
  for (final s in nodeServers) {
    final tag = s['tag']?.toString() ?? '';
    if (tag.isEmpty) continue;
    if (seen.contains(tag)) {
      warningsOut?.add(
          'Node DNS server "$tag" dropped: the tag is already taken by another server.');
      continue;
    }
    final body = Map<String, dynamic>.of(s);
    body['tag'] = tag;
    seen.add(tag);
    if (dropForDetour(body, tag)) continue;
    out.add(body);
  }
  if (tailscaleEndpointTags != null) {
    _sanitizeTailscaleDnsServers(out, tailscaleEndpointTags, warningsOut);
  }
  _filterDnsGroupMembers(
    out,
    allRefTags: {
      for (final e in resolved)
        if (e.tag.isNotEmpty) e.tag,
      for (final s in nodeServers)
        if (s['tag'] is String && (s['tag'] as String).isNotEmpty)
          s['tag'] as String,
    },
    detourDropped: detourDropped,
    detourDroppedOut: detourDroppedOut,
    warningsOut: warningsOut,
  );
  return out;
}

/// §435 — санитайзер ребра `endpoint` у DNS-серверов `tailscale`
/// (NODE_SECTIONS.md §3 п. 5, §6): висячий `endpoint` → сервер выбрасывается
/// целиком (ядро отвергло бы конфиг); второй сервер на тот же узел →
/// выбрасывается (ограничение ядра: не больше одного на узел). Правила на
/// выброшенный сервер чинит вызывающий (`applyCustomDns`). Работает и для
/// корневых серверов из формы DNS-сервера, и для узловых.
void _sanitizeTailscaleDnsServers(
  List<Map<String, dynamic>> out,
  Set<String> endpointTags,
  List<String>? warningsOut,
) {
  final usedEndpoints = <String>{};
  out.removeWhere((body) {
    if (body['type'] != 'tailscale') return false;
    final tag = body['tag']?.toString() ?? '';
    final ep = body['endpoint'];
    if (ep is! String || ep.isEmpty || !endpointTags.contains(ep)) {
      warningsOut?.add(
          'DNS server "$tag" dropped: its Tailscale endpoint "${ep ?? ''}" is not in the config.');
      return true;
    }
    if (!usedEndpoints.add(ep)) {
      warningsOut?.add(
          'DNS server "$tag" dropped: Tailscale endpoint "$ep" already has a DNS server (the core allows one per node).');
      return true;
    }
    return false;
  });
}

/// §312 — пост-проход фильтра членов DNS-групп (`type: group`, kernel
/// SPEC 033). Именно ПОСЛЕ сборки всего списка: доступность члена зависит от
/// полного набора эмитящихся тегов, включая серверы, стоящие в списке ниже
/// группы.
///
/// Правило (решение юзера §312 №3): недоступный член выкидывается ИЗ ЭМИССИИ
/// с warning'ом («ворчание в лог» — [warningsOut] → emitWarnings-снекбар §105
/// + AppLog); storage не мутируется. Причины различаются в тексте:
/// - `disabled` — тег известен ref-списку, но не эмитится (enabled: false);
/// - `unknown`  — тега нет вовсе (опечатка через JSON-вкладку / удалён);
/// - `dangling detour` — сервер выпал из-за висячего `detour` (§441 Н10);
/// - `itself`   — самовключение (ядро роняет конфиг — снимаем до старта);
/// - `duplicate` — повтор (группа = множество, порядок не значим).
///
/// Пустая группа после фильтра НЕ чинится и не выкидывается молча — эмитится
/// пустой, validator помечает `EmptyDnsGroup` (fatal): сборка блокируется до
/// решения юзера, а не деградирует втихую (анти-паттерн §277/§278).
///
/// §443 (SPEC 129 Н10) — исключение: группа, опустевшая оттого, что её члены
/// выпали второй линией (`dangling detour`, в том числе вложенные группы,
/// опустевшие так же), выпадает сама и лечится как сервер — тег уходит в
/// [detourDropped] (и [detourDroppedOut]), ссылки на неё закрывает
/// [healDetourDroppedDnsRefs].
void _filterDnsGroupMembers(
  List<Map<String, dynamic>> out, {
  required Set<String> allRefTags,
  Set<String> detourDropped = const {},
  Set<String>? detourDroppedOut,
  List<String>? warningsOut,
}) {
  final emittedTags = <String>{
    for (final b in out)
      if (b['tag'] is String) b['tag'] as String,
  };
  // Неподвижная точка: группа, чьи члены все недоступны и хотя бы один выпал
  // второй линией, выпадает; её выпадение может опустошить объемлющую группу.
  final dropped = {...detourDropped};
  for (var changed = true; changed;) {
    changed = false;
    for (final body in out) {
      final tag = body['tag'];
      if (body['type'] != 'group' || tag is! String) continue;
      if (dropped.contains(tag)) continue;
      final members = [
        for (final raw in (body['servers'] as List<dynamic>? ?? const []))
          raw?.toString() ?? '',
      ];
      final alive = members.any((m) =>
          m != tag &&
          allRefTags.contains(m) &&
          !dropped.contains(m) &&
          emittedTags.contains(m));
      if (!alive && members.any(dropped.contains)) {
        dropped.add(tag);
        changed = true;
      }
    }
  }
  out.removeWhere((body) {
    final tag = body['tag'];
    if (body['type'] != 'group' ||
        tag is! String ||
        !dropped.contains(tag) ||
        detourDropped.contains(tag)) {
      return false;
    }
    warningsOut?.add("DNS group '$tag' dropped: its members were dropped "
        '(dangling detour)');
    detourDroppedOut?.add(tag);
    return true;
  });
  for (final body in out) {
    if (body['type'] != 'group') continue;
    final selfTag = body['tag'] as String;
    final kept = <String>[];
    for (final raw in (body['servers'] as List<dynamic>? ?? const [])) {
      final m = raw?.toString() ?? '';
      final String? dropReason;
      if (m == selfTag) {
        dropReason = 'itself';
      } else if (kept.contains(m)) {
        dropReason = 'duplicate';
      } else if (m.isEmpty || !allRefTags.contains(m)) {
        // Тега нет ни в одном ref'е — опечатка/удалён: надо чинить группу.
        dropReason = 'unknown';
      } else if (dropped.contains(m)) {
        dropReason = 'dangling detour';
      } else if (!emittedTags.contains(m)) {
        // Ref есть, но не эмитится — выключен: включение вернёт члена.
        dropReason = 'disabled';
      } else {
        dropReason = null;
      }
      if (dropReason != null) {
        warningsOut?.add(
          "DNS group '$selfTag': member '$m' dropped ($dropReason)",
        );
      } else {
        kept.add(m);
      }
    }
    body['servers'] = kept;
  }
}
