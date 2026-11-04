part of '../settings_storage.dart';

// Route final / passive check / DNS servers+rules (репозиторий
// моделей DNS, §439) / ping-options для [SettingsStorage].
//
// Вынесено `part`'ом — та же библиотека, тот же доступ к `_load`/`_save`/
// `_cache`.

// ---------------------------------------------------------------------------
// Route final outbound
// ---------------------------------------------------------------------------

Future<String> _getRouteFinal() async {
  final data = await _load();
  return (data['route_final'] as String?) ?? '';
}

Future<void> _saveRouteFinal(String outbound, {bool flush = true}) async {
  final data = await _load();
  data['route_final'] = outbound;
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113
  if (flush) await _save();
}

// ---------------------------------------------------------------------------
// §612 — миграция от passive_check (§611) к режиму `failover`
//
// Ядро lx.12 удалило `urltest.passive_check` и назвало `failover` его явной
// заменой (одна проба в `interval` вместо N, энергетический эффект §272/§273
// сохраняется). Один раз при первом запуске после обновления, до первой
// сборки конфига:
// - сырой `urltest_passive_check` равен `true` или отсутствует (прежнее
//   умолчание — true) → автовыбор Направлений, автовыбор свёрток и узлы
//   автовыбора папок с режимом `least_test` (или без `mode`) переходят в
//   `failover`;
// - `false` → режимы не меняются;
// - `round_robin` не трогается ни при каком значении; ручной род
//   (`group_type: selector`) — тоже;
// - ключ `urltest_passive_check` удаляется, ставится маркер
//   `urltest_mode_migrated` (повторно миграция не идёт: отсутствие ключа само
//   по себе значит «true», маркером служить не может).
// ---------------------------------------------------------------------------

const String _kPassiveCheckKey = 'urltest_passive_check';

Future<void> _migrateUrltestModeIfNeeded() async {
  final data = await _load();
  if (data[kUrltestModeMigratedKey] == true) return;
  final passive = data[_kPassiveCheckKey];
  final toFailover = passive is! bool || passive;
  var changed = 0;
  if (toFailover) changed = _migrateLeastTestToFailover(data);
  data.remove(_kPassiveCheckKey);
  data[kUrltestModeMigratedKey] = true;
  SettingsStorage._cache = data;
  if (changed > 0) SettingsStorage.markConfigDirty();
  await _save();
  AppLog.I.info('SettingsStorage: urltest mode migration (§612): '
      'passive_check=${passive is bool ? passive : 'absent'}, '
      '$changed group(s) moved to failover');
}

/// §612 — перевод автовыбора с `least_test` (или без `mode`) на `failover` в
/// документе хранения [doc], на месте. Возвращает число переведённых групп.
int _migrateLeastTestToFailover(Map<String, dynamic> doc) {
  var n = 0;
  bool fix(Object? auto) {
    if (auto is! Map) return false;
    final mode = auto['mode'];
    if (mode != null && mode != UrltestMode.leastTest.wire) return false;
    auto['mode'] = UrltestMode.failover.wire;
    return true;
  }

  final directions = doc['directions'];
  if (directions is List) {
    for (final d in directions) {
      if (d is Map && fix(d['auto'])) n++;
    }
  }
  final sources = doc[kSourcesKey];
  if (sources is List) {
    for (final src in sources) {
      if (src is! Map) continue;
      final replace = src['replace'];
      if (replace is Map && fix(replace['auto'])) n++;
      final nodes = src['nodes'];
      if (nodes is! List) continue;
      for (final node in nodes) {
        if (node is! Map || node['kind'] != 'auto') continue;
        final group = node['group'];
        if (group is! Map || group['group_type'] == 'selector') continue;
        final strategy = group['strategy'];
        if (strategy == null) {
          group['strategy'] = <String, dynamic>{
            'mode': UrltestMode.failover.wire,
          };
          n++;
        } else if (fix(strategy)) {
          n++;
        }
      }
    }
  }
  return n;
}

// ---------------------------------------------------------------------------
// §439 — репозиторий DNS: записи `dns.servers[]` / `dns.rules[]` контракта
// 1.0 кодеком `models/codec/dns_record.dart`.
//
// Наверх уходят только модели [DnsServerRef] / [DnsRuleRef].
//
// Инварианты записи (§439 A1):
// - запись, которую кодек не читает (незнакомый вид, нет обязательных
//   полей), наверх не отдаётся и при сохранении остаётся на своём месте — её
//   не стирает ни резолвер, ни экран;
// - неизменённая запись пишется теми же байтами, что лежали: модель, равная
//   разобранной сохранённой записи, берёт её JSON как есть (ключи, которые
//   кодек не читает, не теряются).
// ---------------------------------------------------------------------------

List<dynamic> _dnsList(Map<String, dynamic> data, String key) {
  final dns = data[kDnsKey];
  if (dns is! Map) return const [];
  final list = dns[key];
  return list is List ? list : const [];
}

List<T> _parseDnsEntries<T>(
  List<dynamic> stored,
  T? Function(Map<String, dynamic>) parse,
) =>
    [
      for (final e in stored)
        if (e is Map)
          if (parse(e.cast<String, dynamic>()) case final T m) m,
    ];

/// Сохранённый список + новые модели → список записи (см. инварианты выше).
List<dynamic> _mergeDnsEntries<T>(
  List<dynamic> stored,
  List<T> models,
  T? Function(Map<String, dynamic>) parse,
  Map<String, dynamic> Function(T) encode,
) {
  final parsed = [
    for (final e in stored) e is Map ? parse(e.cast<String, dynamic>()) : null,
  ];
  final used = List<bool>.filled(stored.length, false);
  final out = <dynamic>[];
  for (final m in models) {
    var reuse = -1;
    for (var i = 0; i < stored.length; i++) {
      if (!used[i] && parsed[i] != null && parsed[i] == m) {
        reuse = i;
        break;
      }
    }
    if (reuse >= 0) {
      used[reuse] = true;
      out.add(stored[reuse]);
    } else {
      out.add(encode(m));
    }
  }
  for (var i = 0; i < stored.length; i++) {
    if (parsed[i] != null) continue;
    out.insert(i < out.length ? i : out.length, stored[i]);
  }
  return out;
}

Future<void> _putDnsList(String key, List<dynamic> list,
    {required bool flush}) async {
  final data = await _load();
  final dns = data[kDnsKey];
  data[kDnsKey] = <String, dynamic>{
    if (dns is Map) ...dns.cast<String, dynamic>(),
    key: list,
  };
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113
  if (flush) await _save();
}

DnsServerRef? _dnsServerOf(Map<String, dynamic> j) =>
    dnsServerFromRecord(j).value;

DnsRuleRef? _dnsRuleOf(Map<String, dynamic> j) => dnsRuleFromRecord(j).value;

Future<List<DnsServerRef>> _getDnsServers() async =>
    _parseDnsEntries(_dnsList(await _load(), kDnsServersKey), _dnsServerOf);

/// §680 — ключ `dns.servers` присутствует (список создан). Пустой список —
/// тоже «создан»: признак посева, отдельного флага нет.
Future<bool> _hasDnsServersList() async {
  final dns = (await _load())[kDnsKey];
  return dns is Map && dns[kDnsServersKey] is List;
}

/// §441 — значения переменных template-сервера пишутся по нормам Н2–Н4
/// против шаблона ([normalizeDnsServersVars]): необъявленное имя и значение,
/// равное умолчанию, снимаются молча. Запись, которую нормализация не
/// меняет, остаётся теми же байтами.
Future<void> _saveDnsServers(List<DnsServerRef> servers,
    {bool flush = true}) async {
  final normalized =
      normalizeDnsServersVars(servers, await loadRecordVarDecls());
  final stored = _dnsList(await _load(), kDnsServersKey);
  await _putDnsList(
    kDnsServersKey,
    _mergeDnsEntries(stored, normalized, _dnsServerOf, dnsServerToRecord),
    flush: flush,
  );
}

Future<List<DnsRuleRef>> _getDnsRulesList() async =>
    _parseDnsEntries(_dnsList(await _load(), kDnsRulesKey), _dnsRuleOf);

Future<void> _saveDnsRulesList(List<DnsRuleRef> rules,
    {bool flush = true}) async {
  final stored = _dnsList(await _load(), kDnsRulesKey);
  await _putDnsList(
    kDnsRulesKey,
    _mergeDnsEntries(stored, rules, _dnsRuleOf, dnsRuleToRecord),
    flush: flush,
  );
}

// ---------------------------------------------------------------------------
// Ping/test options (§040)
//
// Storage shape mirrors template `ping_options.{url, timeout_ms, presets}`,
// плюс расширение `groups: Map<groupTag, {url?, timeout_ms?}>` — per-group
// override'ы для ping/mass-ping/URLTest. Resolve chain в HomeController:
// group override → global storage → template default.
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _getPingOptions() async {
  final data = await _load();
  final raw = data['ping_options'];
  if (raw is Map<String, dynamic>) {
    return Map<String, dynamic>.from(raw);
  }
  return <String, dynamic>{};
}

Future<void> _savePingOptions(Map<String, dynamic> options) async {
  final data = await _load();
  data['ping_options'] = options;
  SettingsStorage._cache = data;
  await _save();
}

Future<void> _setGlobalPingUrl(String url) async {
  final opts = await SettingsStorage.getPingOptions();
  opts['url'] = url;
  await SettingsStorage.savePingOptions(opts);
}

/// §713 — параллельность проверки серверов (mass ping и ProbeRunner).
/// Хранится в `ping_options.concurrency`; мусор или отсутствие → дефолт,
/// выход за диапазон → граница.
Future<int> _getPingConcurrency() async {
  final opts = await SettingsStorage.getPingOptions();
  final raw = opts['concurrency'];
  if (raw is! num) return SettingsStorage.pingConcurrencyDefault;
  return raw.toInt().clamp(
      SettingsStorage.pingConcurrencyMin, SettingsStorage.pingConcurrencyMax);
}

/// §713 — `null` снимает ключ (= дефолт); число приводится к диапазону.
Future<void> _setPingConcurrency(int? value) async {
  final opts = await SettingsStorage.getPingOptions();
  if (value == null) {
    opts.remove('concurrency');
  } else {
    opts['concurrency'] = value.clamp(SettingsStorage.pingConcurrencyMin,
        SettingsStorage.pingConcurrencyMax);
  }
  await SettingsStorage.savePingOptions(opts);
}

Future<void> _setGlobalPingTimeout(int timeoutMs) async {
  final opts = await SettingsStorage.getPingOptions();
  opts['timeout_ms'] = timeoutMs;
  await SettingsStorage.savePingOptions(opts);
}

Future<void> _setGroupPing(
  String groupTag, {
  String? url,
  int? timeoutMs,
}) async {
  if (groupTag.isEmpty) return;
  final opts = await SettingsStorage.getPingOptions();
  final groups = (opts['groups'] is Map<String, dynamic>)
      ? Map<String, dynamic>.from(opts['groups'] as Map<String, dynamic>)
      : <String, dynamic>{};
  final existing = (groups[groupTag] is Map<String, dynamic>)
      ? Map<String, dynamic>.from(groups[groupTag] as Map<String, dynamic>)
      : <String, dynamic>{};
  if (url != null) existing['url'] = url;
  if (timeoutMs != null) existing['timeout_ms'] = timeoutMs;
  groups[groupTag] = existing;
  opts['groups'] = groups;
  await SettingsStorage.savePingOptions(opts);
}

Future<void> _clearGroupPing(String groupTag) async {
  if (groupTag.isEmpty) return;
  final opts = await SettingsStorage.getPingOptions();
  if (!_dropPingGroupKeys(opts, (t) => t == groupTag)) return;
  await SettingsStorage.savePingOptions(opts);
}

/// §408 — снять из `ping_options.groups` все ключи, для которых [doomed]
/// вернул `true`. Мутирует переданный `opts` НА МЕСТЕ и возвращает `true`,
/// если что-то ушло (вызывающий решает, писать ли на диск).
///
/// Пустая карта `groups` удаляется целиком, а не остаётся `{}`: ключ
/// `ping_options` попадает в бэкап и в `/state/storage`, и пустой контейнер
/// там читался бы как «per-direction override'ы были и все сброшены», хотя
/// состояние ровно то же, что и до первого override'а. Тот же приём был в
/// `_clearGroupPing` с §040 — здесь он просто вынесен в общую точку.
bool _dropPingGroupKeys(
  Map<String, dynamic> opts,
  bool Function(String tag) doomed,
) {
  final groups = opts['groups'];
  if (groups is! Map<String, dynamic>) return false;
  final doomedKeys = groups.keys.where(doomed).toList();
  if (doomedKeys.isEmpty) return false;
  for (final k in doomedKeys) {
    groups.remove(k);
  }
  if (groups.isEmpty) {
    opts.remove('groups');
  } else {
    opts['groups'] = groups;
  }
  return true;
}
