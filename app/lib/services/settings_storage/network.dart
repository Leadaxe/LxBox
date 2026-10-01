part of '../settings_storage.dart';

// Route final / idle-suspend / passive check / DNS servers+rules (репозиторий
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
// §215 — idle-suspend threshold (lx.wg.idle_suspend, kernel SPEC 020)
//
// Duration-строка ("30s", "5m"). Пусто = feature off (поле не попадёт в
// route, idle-тик ядра не запустится). Config-significant → markConfigDirty.
// Дефолт (нет сохранённого значения) = "30s": включено по умолчанию.
// ---------------------------------------------------------------------------

Future<String> _getIdleSuspend() async {
  final data = await _load();
  return (data['route_idle_suspend'] as String?) ?? '30s';
}

Future<void> _saveIdleSuspend(String threshold, {bool flush = true}) async {
  final data = await _load();
  data['route_idle_suspend'] = threshold;
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113
  if (flush) await _save();
}

// ---------------------------------------------------------------------------
// §272 — reachable idle-suspend window (lx.wg.idle_suspend_reachable,
// kernel SPEC 020 rev. 2026-07-15)
//
// Второе, ДЛИННОЕ окно простоя для ДОСТИЖИМЫХ эндпоинтов (члены пула,
// выбранный узел, final): после него они тоже гасятся; пробуждение — лениво
// первым дайлом (+1 RTT). Duration-строка. Пусто = выключено (достижимые не
// засыпают — поведение до §272). Дефолт "5m" (решение владельца, 2026-07-15):
// агрессивная экономия; цена — при значении < idle_timeout каналов возможны
// 1-2 probe-флапа в хвосте засыпания (пробы ещё живы, когда туннель уже спит)
// — не поломка, см. docs-lx/lx-energy.ru.md §8 ядра.
// Ядро требует idle_suspend включённым и reachable >= idle_suspend —
// генератор эмитит поле только при непустом базовом пороге.
// ---------------------------------------------------------------------------

Future<String> _getIdleSuspendReachable() async {
  final data = await _load();
  return (data['route_idle_suspend_reachable'] as String?) ?? '5m';
}

Future<void> _saveIdleSuspendReachable(String threshold,
    {bool flush = true}) async {
  final data = await _load();
  data['route_idle_suspend_reachable'] = threshold;
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113
  if (flush) await _save();
}

// ---------------------------------------------------------------------------
// §542 — WG/AWG lazy build + build budget (lx.wg.lazy_build / build_max,
// kernel SPEC 097)
//
// `wg_lazy_build` (bool, дефолт true): эндпоинт собирается при первом дайле.
// false → в конфиг не пишутся ни lazy_build, ни build_max.
//
// Сколько WG/AWG эндпоинтов ядро держит собранными одновременно; сверх лимита
// самый давний разбирается и пересобирается по требованию. `0` = без потолка.
// Дефолт 5 (значение бывшей константы §536). Пишется в конфиг только вместе
// с idle_suspend (ядро требует его для lazy_build/build_max).
// Config-significant → markConfigDirty.
// ---------------------------------------------------------------------------

const int kWgBuildMaxDefault = 5;

Future<int> _getWgBuildMax() async {
  final data = await _load();
  final v = data['wg_build_max'];
  return (v is int && v >= 0) ? v : kWgBuildMaxDefault;
}

Future<void> _saveWgBuildMax(int value, {bool flush = true}) async {
  final data = await _load();
  data['wg_build_max'] = value;
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113
  if (flush) await _save();
}

Future<bool> _getWgLazyBuild() async {
  final data = await _load();
  return (data['wg_lazy_build'] as bool?) ?? true;
}

Future<void> _saveWgLazyBuild(bool enabled, {bool flush = true}) async {
  final data = await _load();
  data['wg_lazy_build'] = enabled;
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113
  if (flush) await _save();
}

// ---------------------------------------------------------------------------
// §272 — passive health check (urltest.passive_check, kernel SPEC 019)
//
// Успешный TCP-дайл через узел = доказательство живости; пока оно свежо
// (< interval), периодические пробы группы пропускаются — активная группа
// перестаёт будить спящие узлы. Пишется в urltest-двойники Направлений.
// Дефолт true (энергоэкономия из коробки). ⚠ Требует ядра с ревизией SPEC 019
// 2026-07-15 — на старом ядре незнакомое поле роняет конфиг (KERNEL.md #2).
// ---------------------------------------------------------------------------

Future<bool> _getPassiveCheck() async {
  final data = await _load();
  return (data['urltest_passive_check'] as bool?) ?? true;
}

Future<void> _savePassiveCheck(bool enabled, {bool flush = true}) async {
  final data = await _load();
  data['urltest_passive_check'] = enabled;
  SettingsStorage._cache = data;
  SettingsStorage.markConfigDirty(); // §113
  if (flush) await _save();
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
