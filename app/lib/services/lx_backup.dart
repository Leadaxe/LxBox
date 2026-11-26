/// LX Backup v1 — переносимый формат обмена настройками с десктопным
/// лаунчером (SPEC 103, фаза 4). Подробности — в docstring ниже.
library;

import 'dart:convert';
import 'dart:math';

import 'package:package_info_plus/package_info_plus.dart';

import '../config/consts.dart';
import '../models/auto_select.dart';
import '../models/codec/auto_group_record.dart';
import '../models/codec/chain_record.dart';
import '../models/codec/node_link_record.dart';
import '../models/codec/source_record.dart';
import '../models/codec/source_replace_record.dart';
import '../models/core_reject_verdict.dart';
import '../models/custom_rule.dart';
import '../models/direction.dart';
import '../models/dns_ref.dart';
import '../models/import_rule.dart';
import '../models/mixin.dart';
import '../models/node_link.dart';
import '../models/node_spec.dart' show AutoSelectSpec, NodeSpec;
import '../models/parser_config.dart' show kUserRuleNumStart;
import '../models/record_codec.dart';
import '../models/server_list.dart';
import '../models/source_chain.dart';
import '../models/source_dialect.dart';
import '../models/source_replace.dart';
import '../models/tls_policy.dart';
import 'core_reject/core_reject_backup.dart';
import 'lx_backup_slice.dart';
import 'node_link_address.dart';
import 'node_hash.dart' show deepSortKeys;
import 'parser/body_decoder.dart';
import 'parser/json_comments.dart';
import 'parser/parse_all.dart';
import 'parser/uri_utils.dart' show newUuidV4;
import 'record_vars.dart';
import 'settings_storage.dart' show NativePrefsKeys;
import 'storage_migration/legacy_autogroup.dart';
import 'tag_resolver.dart';

part 'lx_backup/constants.dart';
part 'lx_backup/models.dart';
part 'lx_backup/export.dart';
part 'lx_backup/decode_0x.dart';
part 'lx_backup/decode_10.dart';
part 'lx_backup/merge.dart';

/// LX Backup — переносимый формат обмена настройками с десктопным лаунчером
/// (SPEC 103; контракт 1.0, §438).
///
/// Схема — `contract/schema/backup.schema.json`, семантика —
/// `contract/docs/BACKUP.md`, принципы — `contract/docs/BACKUP_PRINCIPLES.md`
/// (П1–П7, нормативны). Это НЕ замена [BackupService]: тот делает полный
/// снимок настроек для той же самой установки, а этот переносит общую часть
/// между приложениями.
///
/// **Файл — сериализация состояния** (П1). Ничего сверх состояния в нём нет:
/// ни блобов «на провоз», ни теневых карманов. Следствия, которыми меряется
/// реализация:
///
///  1. экспорт — чистая функция состояния: два неотличимых состояния дают
///     неотличимые файлы;
///  2. состояние после импорта неотличимо от настроенного руками;
///  3. `import(export(x))` в том же приложении = `x`.
///
/// Механизм `extensions` УПРАЗДНЁН целиком (П3). Провоз непонятого создавал
/// ровно то, что запрещает П1: состояние-призрак, которое протухает, когда
/// каноническую часть правят в другом приложении. Непонятое теперь
/// отбрасывается и предъявляется пользователю warning'ом.
///
/// §438 — пишется формат 1.0 ([buildLxBackup]). Читаются оба: `lx_backup: 1`
/// (семейство 0.x, legacy-вход) и `lx_backup: 2`. Каждый разбирается своим
/// декодером в одни и те же промежуточные записи ([LxBackupFile]), дальше
/// работает ОДИН код слияния ([mergeBackupSubscriptions],
/// [mergeBackupServers], [resolveBackupChainHops], [renumberBackupAxis],
/// `applyDnsBackup`). Файл 0.10.x разбирается декодером 0.x общим правилом.
///
/// Нет молчаливых потерь (П6): всё неприменённое названо кодом warning'а —
/// и на импорте, и на экспорте.

/// Строка → JSON-объект, если это он. Массив/скаляр/мусор → null.
Map<String, dynamic>? _tryDecodeObject(String body) {
  if (!body.startsWith('{')) return null;
  try {
    final decoded = jsonDecode(body);
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// Разбирает LX Backup и сверяет цели правил и `route.final` без состояния
/// приёмника: известные цели — [knownOutbounds] плюс то, что приехало файлом
/// ([lxImportKnownTargets]). Импорт в приложение идёт не сюда, а через план
/// `planLxBackupImport` (`lx_backup_import.dart`): там список считается после
/// слияния, с узлами и шаблоном приёмника (D-117).
///
/// [knownOutbounds] — имена, которые приёмник знает сам (они же заняты для
/// Направлений файла); пустой набор при файле без целей означает «проверять
/// нечем» — тогда ссылки не режутся.
///
/// [knownChains] — теги ЦЕПОЧЕК, уже заведённых на этой стороне (§393 C9).
/// Отдельно от [knownOutbounds] намеренно: merge цепочек идёт по СВОЕМУ
/// пространству имён — приехавшая цепочка `relay` при существующем
/// Направлении `relay` это не «своя цепочка сильнее», а коллизия тегов, и
/// разгребает её гейт применения ([directionTagConflict]), а не warning
/// `backup_chain_exists`, который отвечает на другой вопрос.
///
/// §438 — формат опознаётся ключом `lx_backup` одним сравнением ещё до
/// разбора тела (BACKUP.md §8): `1` — декодер 0.x, `2` и `3` (§757) —
/// декодер 1.0. Больше [kLxBackupVersion] — отказ целиком; вне `{1, 2, 3}`
/// — не наш файл.
LxBackupFile parseLxBackup(
  String raw, {
  Set<String> knownOutbounds = const {},
  Set<String> knownPresets = const {},
  Set<String> knownChains = const {},
  RecordVarDecls recordVars = RecordVarDecls.none,
}) {
  final file = decodeLxBackup(
    raw,
    takenTags: knownOutbounds,
    knownPresets: knownPresets,
    knownChains: knownChains,
    recordVars: recordVars,
  );
  return gateLxBackupTargets(
    file,
    lxImportKnownTargets(
      directions: file.directions,
      chainTags: {for (final c in file.chains) c.tag},
      receiverTargets: {...knownOutbounds, ...knownChains},
    ),
  );
}

/// Декодер LX Backup без проверки целей: записи файла в промежуточную форму,
/// пресет вне шаблона — выключен. Цели правил и `route.final` сверяет
/// [gateLxBackupTargets] одним списком после слияния (BACKUP.md §3, D-117):
/// до слияния декодер не знает ни узлов результата, ни шаблона приёмника.
///
/// [takenTags] — теги, занятые у приёмника: Направление файла под таким тегом
/// не применяется (`backup_direction_exists`).
///
/// [recordVars] — §441, объявления переменных записей шаблона приёмника:
/// корневые `dns_<tag>_<var>` переносятся в записи серверов файла (Н8),
/// template-сервер DNS с тегом, которого шаблон не объявил, не ввозится
/// ([kWarnDnsEntrySkipped]). [RecordVarDecls.none] — шаблона нет: корневые
/// имена идут общим правилом `vars`, теги серверов не сверяются.
LxBackupFile decodeLxBackup(
  String raw, {
  Set<String> takenTags = const {},
  Set<String> knownPresets = const {},
  Set<String> knownChains = const {},
  RecordVarDecls recordVars = RecordVarDecls.none,
}) {
  final dynamic decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Это не файл LX Backup');
  }
  final version = decoded['lx_backup'];
  if (version is! int) {
    throw const FormatException('Это не файл LX Backup: нет поля lx_backup');
  }
  if (version > kLxBackupVersion) {
    throw FormatException(
      'Формат бэкапа v$version новее поддерживаемого v$kLxBackupVersion — обновите приложение',
    );
  }
  if (version < kLxBackupFormat0x) {
    throw const FormatException('Это не файл LX Backup: нет поля lx_backup');
  }
  if (version == kLxBackupFormat10 || version == kLxBackupFormat11) {
    return _parse10(
      decoded,
      takenTags: takenTags,
      knownPresets: knownPresets,
      knownChains: knownChains,
      recordVars: recordVars,
    );
  }
  return _parse0x(
    decoded,
    version,
    takenTags: takenTags,
    knownPresets: knownPresets,
    knownChains: knownChains,
    recordVars: recordVars,
  );
}

/// Направления файла и то, что они дают остальному разбору.
typedef _ParsedDirections = ({
  List<Direction> directions,
  Map<String, LxDirectionPing> ping,
});

/// §393 B1 — Направления файла. Форма `directions[]` у 0.x и 1.0 одна (тонкий
/// слой, BACKUP.md §1), поэтому и разбор один. Их теги — известные цели
/// правил (BACKUP.md §3): список считает [lxImportKnownTargets] после слияния.
///
/// Занятый тег — не ошибка файла: у пользователя под этим именем своё
/// Направление со своими настройками. Приехавшее не применяется (warning),
/// но цель под этим тегом у приёмника есть — правило её находит.
_ParsedDirections _parseDirections(
  Map<String, dynamic> decoded,
  Set<String> takenTags,
  List<LxBackupWarning> warnings,
) {
  final directions = <Direction>[];
  // §409 — бюджеты теста узла применённых Направлений (`ping_options.groups`).
  final directionPing = <String, LxDirectionPing>{};
  // §406 (D-095) — занятость тега определяется ТОЧНЫМ совпадением, как при
  // создании Направления руками (`directionTagConflict`). `VPN-DE` при живом
  // `vpn-de` — не тёзка, а второе Направление: для ядра это два разных
  // outbound'а, и объявлять одно из них «уже существующим» значило бы молча
  // потерять приехавшую запись.
  final taken = <String>{
    for (final t in takenTags) t.trim(),
  };
  final items = decoded['directions'];
  for (final item in (items is List ? items : const [])) {
    if (item is! Map) continue;
    final j = item.cast<String, dynamic>();
    final rawTag = j['tag'];
    final tag = rawTag is String ? rawTag.trim() : '';
    if (tag.isEmpty) continue; // без тега Направление не адресуемо
    if (!taken.add(tag)) {
      warnings.add(LxBackupWarning(kWarnDirectionExists, tag));
      continue;
    }
    directions.add(_directionFromCanon(j, tag));
    // §409 — бюджет теста узла разбирается ТОЛЬКО у применённого
    // Направления: занятый тег уводит запись в `continue` выше, и бюджет
    // уходит вместе с ней. Иначе файл менял бы настройку Направлению,
    // которого сам не создавал (§9 BACKUP.md — своё остаётся своим).
    final ping = _directionPingFromCanon(j, tag, warnings);
    if (!ping.isEmpty) directionPing[tag] = ping;
  }
  return (
    directions: directions,
    ping: directionPing,
  );
}

/// `vars` — только переносимые имена (обе формы одинаковы).
///
/// §441 (SPEC 129 Н8) — корневое имя вне реестра разрешается против
/// объявлений шаблона приёмника ([rootDnsVarTarget]: объявленные пары
/// `(tag, var)`, выигрывает самый длинный тег) и переносится в запись
/// template-сервера ФАЙЛА до слияния:
///
///  * кандидата нет — [kVarSkippedNotPortable], как раньше;
///  * у записи в файле свои непустые `vars` — побеждает запись,
///    [kVarSkippedSuperseded];
///  * запись есть, `vars` пуст — значение уходит в `vars` записи (Н2–Н4 —
///    на слиянии, против шаблона приёмника);
///  * записи с этим тегом в файле нет — [kVarSkippedNoRecord].
///
/// Правило одно на файлы 1.0 и 0.x. «Пуст» — `vars` записи, как прочитан
/// файл: два корневых имени одного сервера переносятся оба. Пустое значение
/// переносить нечего (Н3).
({Map<String, String> vars, LxDns? dns}) _parseVars(
  Map<String, dynamic> decoded,
  List<LxBackupWarning> warnings, {
  LxDns? dns,
  RecordVarDecls recordVars = RecordVarDecls.none,
}) {
  final vars = <String, String>{};
  final raw = decoded['vars'];
  final rawVars = raw is Map ? raw.cast<String, dynamic>() : const {};
  final servers = dns?.servers.toList();
  // Теги template-записей файла со своими `vars` — как прочитан файл.
  final ownVars = <String>{
    for (final s in servers ?? const <DnsServerRef>[])
      if (s is DnsServerTemplate && s.varValues.isNotEmpty) s.tag,
  };
  var lifted = false;
  for (final key in rawVars.keys.toList()..sort()) {
    // §643 (D-132) — корневая переменная шаблона приёмника с
    // `wizard_ui: internal`: значение файла не данные пользователя.
    if (recordVars.internalGlobals.contains(key)) {
      warnings.add(LxBackupWarning(kWarnVarSkipped, key,
          reason: kVarSkippedInternal));
      continue;
    }
    if (kLxPortableVars.contains(key)) {
      vars[key] = '${rawVars[key]}';
      continue;
    }
    final target = rootDnsVarTarget(key, recordVars);
    if (target == null) {
      warnings.add(LxBackupWarning(kWarnVarSkipped, key,
          reason: kVarSkippedNotPortable));
      continue;
    }
    final at = servers == null
        ? -1
        : servers.indexWhere(
            (s) => s is DnsServerTemplate && s.tag == target.tag);
    if (at < 0) {
      warnings.add(LxBackupWarning(kWarnVarSkipped, key,
          reason: kVarSkippedNoRecord));
      continue;
    }
    if (ownVars.contains(target.tag)) {
      warnings.add(LxBackupWarning(kWarnVarSkipped, key,
          reason: kVarSkippedSuperseded));
      continue;
    }
    final value = rawVars[key];
    final text = value == null ? '' : '$value'.trim();
    if (text.isEmpty) continue;
    final record = servers![at] as DnsServerTemplate;
    servers[at] = record.copyWith(
        varValues: {...record.varValues, target.varName: text});
    lifted = true;
  }
  return (
    vars: vars,
    dns: !lifted || dns == null
        ? dns
        : LxDns(
            servers: servers!,
            rules: dns.rules,
            finalServer: dns.finalServer,
            strategy: dns.strategy,
            defaultDomainResolver: dns.defaultDomainResolver,
            templateCatalog: dns.templateCatalog,
          ),
  );
}

/// `route.final` файла как есть. Применяется только при известной цели
/// (BACKUP.md §3) — сверяет [gateLxBackupTargets] после слияния.
String? _parseRouteFinal(Map<String, dynamic> decoded) {
  final route = decoded['route'];
  final finalTag = route is Map ? route['final'] : null;
  if (finalTag is! String || finalTag.isEmpty) return null;
  return finalTag;
}

/// §393 B8 — записи warp[]: разбираются позже, при применении (парсер не
/// знает про storage). Здесь только отсев мусора и дискриминатор.
List<Map<String, dynamic>> _parseWarp(
  Map<String, dynamic> decoded,
  List<LxBackupWarning> warnings,
) {
  final warp = <Map<String, dynamic>>[];
  final items = decoded['warp'];
  for (final item in (items is List ? items : const [])) {
    if (item is! Map) continue;
    final j = item.cast<String, dynamic>();
    final rawType = j['type'];
    final type = rawType is String ? rawType : '';
    if (type != 'wg' && type != 'masque') {
      warnings.add(
        LxBackupWarning(
          kWarnWarpSkipped,
          type.isEmpty ? 'warp[]: нет type' : 'warp[]: $type',
        ),
      );
      continue;
    }
    warp.add(j);
  }
  return warp;
}

/// §707 итер. 9 (контракт 1.1.158) — секция `native_prefs`: известные
/// ключи с типом схемы (bool у тумблеров, строка у `background_mode`,
/// `memory_limit`, `app_theme_mode`). Значение не того типа — пропуск с
/// [kWarnFieldTypeMismatch]; нормализацию значения делает слой native_prefs.
Map<String, Object> _parseNativePrefs(
  Map<String, dynamic> decoded,
  List<LxBackupWarning> warnings,
) {
  final raw = decoded['native_prefs'];
  if (raw is! Map) return const {};
  final out = <String, Object>{};
  for (final key in NativePrefsKeys.all) {
    if (!raw.containsKey(key)) continue;
    final v = raw[key];
    final ok = NativePrefsKeys.bools.contains(key) ? v is bool : v is String;
    if (!ok || v == null) {
      warnings.add(LxBackupWarning(kWarnFieldTypeMismatch, 'native_prefs.$key'));
      continue;
    }
    out[key] = v as Object;
  }
  return out;
}

/// §704 — секция `mixins`: записи без `id` (новый при разборе). Запись без
/// строковых `target`/`op` не применима — пропуск с
/// [kWarnFieldTypeMismatch] по пути поля. Неизвестный глагол доезжает до
/// сборки и становится её отказом, как у миксина из Debug API.
List<Mixin> _parseMixins(
  Map<String, dynamic> decoded,
  List<LxBackupWarning> warnings,
) {
  final out = <Mixin>[];
  final items = decoded['mixins'];
  final list = items is List ? items : const [];
  for (var i = 0; i < list.length; i++) {
    final item = list[i];
    if (item is! Map) continue;
    final j = item.cast<String, dynamic>();
    final bad = j['target'] is! String ? 'target' : (j['op'] is! String ? 'op' : null);
    if (bad != null) {
      warnings.add(LxBackupWarning(kWarnFieldTypeMismatch, 'mixins[$i].$bad'));
      continue;
    }
    out.add(Mixin.fromJson({...j, 'id': null}));
  }
  return out;
}

/// §438 — правила по оси `num`, стабильно; неразмеченные — в хвост, в
/// порядке файла (у них нет места на оси, и перебивать размеченных им не за
/// что). Порядок, который разбор отдаёт превью и слиянию.
List<CustomRule> sortRulesByAxis(List<CustomRule> rules) {
  final indexed = [
    for (var i = 0; i < rules.length; i++) (i, rules[i]),
  ];
  indexed.sort((a, b) {
    final an = a.$2.orderNum;
    final bn = b.$2.orderNum;
    if (an != null && bn != null && an != bn) return an.compareTo(bn);
    if (an == null && bn != null) return 1;
    if (an != null && bn == null) return -1;
    return a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}
/// Ключ упразднённого механизма провоза (BACKUP_PRINCIPLES.md П3).
const String _extensionsKey = 'extensions';

const Set<String> _exportedByKeys = {'app', 'version', 'platform'};
const Set<String> _routeKeys = {'final'};
const Set<String> _directionKeys = {
  'tag',
  // §405 — `label` Направления объявлен в схеме, и применяет его только
  // LxBox (колонка «Поддержка» `docs/BACKUP.md` §2, D-094): читается в модель
  // и пишется обратно; лаунчер не применяет и провозит молча.
  'label',
  'enabled',
  'filter',
  'invert',
  'default',
  'include_direct',
  'include_block',
  'include',
  'interrupt_exist_connections',
  // §409 — бюджет теста узла у Направления (`ping_options.groups[tag]`,
  // §040). Поля объявлены в схеме, применяет их только LxBox (колонка
  // «Поддержка» `docs/BACKUP.md` §2); лаунчер не применяет и провозит молча.
  // Без них файл LxBox ловил бы `backup_unknown_field` на собственном
  // экспорте.
  'ping_url',
  'ping_timeout_ms',
  'auto',
};

const Set<String> _directionAutoKeys = {
  'mode',
  'url',
  'interval',
  'tolerance',
  'idle_timeout',
  'interrupt_exist_connections',
  'pool',
  'pool_tolerance',
  'sticky_hash',
};
/// §704 — запись секции `mixins`; `value` — произвольный JSON, вглубь не
/// обходится.
const Set<String> _mixinKeys = {'name', 'enabled', 'target', 'op', 'value'};
/// Union обоих типов регистрации: запись объявляет свой `type`, и разбирать её
/// по типу значило бы завести две почти одинаковые таблицы ради ключей,
/// которых у чужого типа всё равно не бывает.
const Set<String> _warpKeys = {
  'type',
  'private_key',
  'peer_public',
  'client_v4',
  'client_v6',
  'client_id',
  'device_id',
  'token',
  'account_id',
  'license',
  'warp_plus',
  'created_at',
  'private_key_der',
  'server_pub_der',
  'server',
  'port',
  // §401, контракт 0.12.2 — плоские поля записи вместо упразднённого кармана
  // `extensions.lxbox`. `sni`/`idle_timeout` схема объявляет поимённо
  // (`extension: mobile`); `awg`/`endpoint`/`keep_alive` — «snake_case поля
  // самой регистрации» из открытой части секции (`additionalProperties`).
  'sni',
  'idle_timeout',
  'keep_alive',
  'awg',
  'endpoint',
};
/// Чем запись секции называется пользователю: код обязан показать «в подписке
/// https://…», а не «в записи №3», иначе предупреждение не с чем сопоставить.
const Map<String, String> _arrayLabelKeys = {
  'subscriptions': 'url',
  'servers': 'node_tag',
  'chains': 'tag',
  'directions': 'tag',
  'rules': 'name',
  'outbounds': 'tag',
  'warp': 'type',
};
/// Копит находки обхода: обычные неизвестные ключи по одному, упразднённый
/// `extensions` — списком затронутых записей.
class _UnknownScan {
  final _fields = <String>[];
  final _seenField = <String>{};
  final _extensionsAt = <String>[];
  final _seenExtension = <String>{};

  void _note(String where, String key) {
    if (key == _extensionsKey) {
      final place = where.isEmpty ? '<file root>' : where;
      if (_seenExtension.add(place)) _extensionsAt.add(place);
      return;
    }
    final name = where.isEmpty ? key : '$where.$key';
    if (_seenField.add(name)) _fields.add(name);
  }

  void object(String where, Map<String, dynamic> obj, Set<String> known) {
    for (final key in obj.keys) {
      if (!known.contains(key)) _note(where, key);
    }
  }

  void nested(Map<String, dynamic> parent, String key, Set<String> known) {
    final obj = (parent[key] as Map?)?.cast<String, dynamic>();
    if (obj == null) return;
    object(key, obj, known);
  }

  /// Вложенный объект ВНУТРИ записи: путь уже назван (`chains[relay]`), и имя
  /// ключа дописывается к нему, а не заменяет его.
  void nestedAt(
    Map<String, dynamic> parent,
    String where,
    String key,
    Set<String> known,
  ) {
    final obj = (parent[key] as Map?)?.cast<String, dynamic>();
    if (obj == null) return;
    object('$where.$key', obj, known);
  }

  /// §441 (Л5) — `vars` DNS-сервера 1.0 — поле только `kind: template`. У
  /// `user` и `preset` ключ не применяется (кодек его не читает) и называется
  /// как незнакомый. Запись чужого вида отбрасывает [_dns10] целиком — её
  /// ключи не называются.
  void dnsServer10Body(String where, Map<String, dynamic> item) {
    final kind = item['kind'];
    if ((kind == 'user' || kind == 'preset') && item.containsKey('vars')) {
      _note(where, 'vars');
    }
  }

  /// Вложенные уровни одного Направления. Общий для корневых `directions[]` и
  /// локальных `subscriptions[].outbounds[]`: форма у них одна.
  void directionBody(String where, Map<String, dynamic> item) {
    nestedAt(item, where, 'auto', _directionAutoKeys);
  }

  /// Обходит секцию-список. [deeper], если задан, вызывается на каждой записи
  /// с её ПОЛНЫМ путём — им секция спускается на свои вложенные уровни.
  void array(
    Map<String, dynamic> parent,
    String where,
    String key,
    Set<String> known,
    String? labelKey,
    void Function(String, Map<String, dynamic>)? deeper,
  ) {
    final items = parent[key];
    if (items is! List) return;
    final label = labelKey ?? _arrayLabelKeys[key] ?? '';
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is! Map) continue;
      final j = item.cast<String, dynamic>();
      final entry = '$where[${_entryLabel(j, label, i)}]';
      object(entry, j, known);
      if (deeper != null) deeper(entry, j);
    }
  }

  static String _entryLabel(
    Map<String, dynamic> item,
    String labelKey,
    int index,
  ) {
    final v = item[labelKey];
    if (v is String && v.isNotEmpty) return v;
    return '#${index + 1}';
  }

  List<LxBackupWarning> warnings() {
    final out = <LxBackupWarning>[];
    if (_extensionsAt.isNotEmpty) {
      final places = _extensionsAt.toList()..sort();
      out.add(LxBackupWarning(kWarnExtensionsDropped, places.join(', ')));
    }
    for (final name in _fields.toList()..sort()) {
      out.add(LxBackupWarning(kWarnUnknownField, name));
    }
    return out;
  }
}
/// Неприменённые ключи `identity` — ОДНИМ [kWarnSourceIdentityDropped] на
/// подписку: сначала ключи схемы в её порядке, затем чужие по алфавиту, чтобы
/// два импорта одного файла давали один и тот же перечень. Общий для входов
/// 0.x и 1.0.
void _noteIdentityDropped(
  Iterable<String> keys,
  String where,
  List<LxBackupWarning> warnings,
) {
  final set = keys.toSet();
  final ordered = [
    for (final k in _identityKeyOrder)
      if (set.contains(k)) k,
    ...(set.where((k) => !_identityKeyOrder.contains(k)).toList()..sort()),
  ];
  if (ordered.isEmpty) return;
  warnings.add(LxBackupWarning(
    kWarnSourceIdentityDropped,
    '$where: ${ordered.join(', ')}',
  ));
}
/// Ключи объекта `identity` в порядке схемы 0.12. Порядок фиксирован, а не
/// взят из обхода map: перечень в предупреждении обязан быть воспроизводимым.
const List<String> _identityKeyOrder = [
  'user_agent',
  'send_hwid',
  'hwid',
  'device_os',
  'ver_os',
  'device_model',
  'hash_device_model',
];
/// §441 (SPEC 129 §5.2) — template-сервер DNS, которого шаблон приёмника не
/// объявил, не ввозится: собрать его тело не из чего. Шаблона нет
/// ([RecordVarDecls.none]) — сверять не с чем, запись идёт как есть.
bool _templateServerDeclared(DnsServerRef server, RecordVarDecls recordVars) =>
    server is! DnsServerTemplate ||
    recordVars.dnsServers.isEmpty ||
    recordVars.dnsServers.containsKey(server.tag);
/// §393 B1 — каноническая форма → мобильное [Direction].
///
/// Переносится КАНОН, а не внутренняя структура: у сторон они разные. Отбор
/// узлов едет ТЕЛОМ регулярки — язык паттернов различается (`/re/i` у
/// лаунчера, [RegExp] у нас), а тело одинаково, и у мобилы [Direction.nodeFilter]
/// уже хранит тело. Эталон — `core/backup/directions.go:importDirection`.
///
/// §401 — неизвестные ключи здесь больше не пересчитываются: их называет
/// общий обход [_scanUnknown] полным путём.
///
/// §405 — `label` читается В МОДЕЛЬ: это поле применяет LxBox (колонка
/// «Поддержка» `docs/BACKUP.md` §2, D-094). Отсутствие ключа — пустое имя, и
/// показан будет тег ([Direction.displayLabel]).
Direction _directionFromCanon(Map<String, dynamic> j, String tag) {
  final rawAuto = j['auto'];
  return Direction(
    tag: tag,
    // §405 — пустое имя законно: отображаем тег.
    label: (j['label'] as String?) ?? '',
    // Отсутствие ключа = true (`enabled.default` схемы), а не false.
    enabled: j['enabled'] as bool? ?? true,
    nodeFilter: (j['filter'] as String?) ?? '',
    nodeFilterInvert: j['invert'] as bool? ?? false,
    defaultFilter: (j['default'] as String?) ?? '',
    // Служебные опции у сторон зовутся по-своему (`direct-out`/`block-out` у
    // лаунчера, `direct`/`block` у нас) и потому едут признаками, а не тегами.
    includeDirect: j['include_direct'] as bool? ?? false,
    includeBlock: j['include_block'] as bool? ?? false,
    include: _strList(j['include']),
    // Отсутствие ключа означает «решает шаблон», а не false: у мобилы
    // шаблонное значение — true (см. `Direction.interruptExistConnections`).
    interruptExistConnections:
        j['interrupt_exist_connections'] as bool? ?? true,
    auto: rawAuto is Map
        ? directionAutoFromRecord(rawAuto.cast<String, dynamic>())
        : null,
  );
}

/// §409 — `directions[].ping_url` / `directions[].ping_timeout_ms` → бюджет
/// теста узла ([LxDirectionPing]).
///
/// Отсутствие ключа = override нет, и это НЕ ошибка: подавляющее большинство
/// Направлений живёт на глобальном бюджете.
///
/// Валидация повторяет ту, что делает диалог §040 при сохранении: URL идёт
/// обрезанным по краям и пустым не сохраняется, таймаут — целое положительное.
/// Значение, не прошедшее её, ОТБРАСЫВАЕТСЯ, а Направление применяется без
/// него: пустой URL и нулевой таймаут не «строгий бюджет», а мёртвая кнопка
/// «Ping», и уронить из-за них весь файл значило бы потерять всё прочее (П6).
///
/// Тип разошёлся (строка вместо числа, число вместо строки) — знакомый ключ с
/// чужим значением: [kWarnFieldTypeMismatch], как у `subscriptions[].skip`
/// (§401). Значение ВНЕ диапазона своего типа (пустая строка, 0, минус)
/// предупреждения не даёт: тип тот, и приехало ровно то, что на этой стороне
/// означает «override сброшен».
LxDirectionPing _directionPingFromCanon(
  Map<String, dynamic> j,
  String tag,
  List<LxBackupWarning> warnings,
) {
  final rawUrl = j['ping_url'];
  if (rawUrl != null && rawUrl is! String) {
    warnings.add(
      LxBackupWarning(kWarnFieldTypeMismatch, 'directions[$tag].ping_url'),
    );
  }

  final rawTimeout = j['ping_timeout_ms'];
  // `bool` в Dart не `num`, поэтому отдельной проверки на него не нужно.
  if (rawTimeout != null && rawTimeout is! num) {
    warnings.add(
      LxBackupWarning(
        kWarnFieldTypeMismatch,
        'directions[$tag].ping_timeout_ms',
      ),
    );
  }

  // Пустую строку и неположительный таймаут отсеивает конструктор: тип у них
  // верный, и означают они «override сброшен», а не ошибку файла.
  return LxDirectionPing(
    url: rawUrl is String ? rawUrl : null,
    timeoutMs: rawTimeout is num ? rawTimeout.toInt() : null,
  );
}

/// §393 B2 — мобильное [Direction] → каноническая форма.
///
/// Прямые значения, без ссылок: у мобилы ссылочно-served полей (шаблонных
/// `@urltest_tolerance` лаунчера) нет вовсе — экспортируется то, что лежит.
///
/// §405 — `label` пишется, когда он непустой И отличается от тега. Поле
/// объявлено в схеме, применяет его только LxBox (колонка «Поддержка»
/// `docs/BACKUP.md` §2, D-094), лаунчер не применяет и провозит молча.
/// `label == tag` не пишем: там нет имени, там повтор тега, и на той стороне
/// он был бы неотличим от осознанно введённого имени.
///
/// §409 — `ping_url` / `ping_timeout_ms` пишутся ТОЛЬКО когда у Направления
/// есть соответствующий override в `ping_options.groups[tag]`: отсутствие
/// ключа и означает «override нет», а выписывать сюда разрешённое значение
/// (глобальное или шаблонное) значило бы превратить умолчание в
/// зафиксированную настройку на принимающей стороне.
Map<String, dynamic> _directionToJson(Direction d, LxDirectionPing? ping) => {
  'tag': d.tag,
  if (d.label.isNotEmpty && d.label != d.tag) 'label': d.label,
  // Ключ пишем только для выключенного: отсутствие = true по схеме, и
  // «enabled: true» у каждой записи раздувало бы файл без смысла.
  if (!d.enabled) 'enabled': false,
  if (d.nodeFilter.isNotEmpty) 'filter': d.nodeFilter,
  if (d.nodeFilterInvert) 'invert': true,
  if (d.defaultFilter.isNotEmpty) 'default': d.defaultFilter,
  if (d.includeDirect) 'include_direct': true,
  if (d.includeBlock) 'include_block': true,
  if (d.include.isNotEmpty) 'include': d.include,
  'interrupt_exist_connections': d.interruptExistConnections,
  if (ping?.url != null) 'ping_url': ping!.url,
  if (ping?.timeoutMs != null) 'ping_timeout_ms': ping!.timeoutMs,
  if (d.auto != null) 'auto': directionAutoToRecord(d.auto!),
};
/// §406 (D-095) — цель правила и `route.final` опознаются ТОЧНЫМ совпадением
/// после `trim()`.
///
/// Тег outbound'а у ядра регистрозависим: правило на `VPN-DE` при Направлении
/// `vpn-de` ядро не свяжет ни с чем. Регистронезависимое опознание объявляло
/// бы такую цель известной и пропускало правило ВКЛЮЧЁННЫМ — то есть ровно в
/// тот отказ конфига, ради которого гейт и стоит. Разошедшийся регистр — это
/// неизвестная цель, и правило обязано приехать выключенным.
///
/// Зарезервированные литералы сравниваются в каноническом написании ядра
/// (`_reservedOutbounds`, всё в нижнем регистре): `Direct` таким же
/// outbound'ом для ядра не является.
bool _isKnownOutbound(String tag, Set<String> known) {
  final t = tag.trim();
  return _reservedOutbounds.contains(t) || known.contains(t);
}

/// §441 (SPEC 129 Н9) — известна ли цель [tag] списку [known]
/// ([lxImportKnownTargets]) с зарезервированными литералами: та же проверка,
/// что у целей правил, для маршрута DNS-серверов.
bool lxIsKnownImportTarget(String tag, Set<String> known) =>
    _isKnownOutbound(tag, known);

/// D-117 — корневые имена результата импорта (BACKUP.md §3, NODE_LINK §8):
/// служебные теги шаблона приёмника ([systemTags]; без шаблона —
/// [kLxImportDefaultSystemTags]), теги Направлений и `-auto` тех, у кого есть
/// автовыбор, теги цепочек и корневые имена свёрток источников
/// ([replaceTags], фича 565 фаза B: `tag` и у `both` его `-auto`).
///
/// [directions] и [chainTags] — то, что окажется у приёмника после слияния:
/// его собственные записи и приехавшие, прошедшие гейт тегов. Запись файла,
/// отсеянная гейтом, целью не становится: её тег либо уже есть у приёмника,
/// либо служебный и Направлению не положен.
///
/// Это часть списка известных целей ([lxImportKnownTargets]), которая
/// известна ДО слияния узлов: её получает подъём ссылок
/// ([mergeBackupServers], `rootNames`), а корневые узлы результата он
/// добавляет сам тем же [lxImportRootNodeTags].
Set<String> lxImportRootNames({
  Iterable<Direction> directions = const [],
  Iterable<String> chainTags = const [],
  Set<String> systemTags = const {},
  Iterable<String> replaceTags = const [],
}) {
  final names = <String>{};
  void add(String tag) {
    final t = tag.trim();
    if (t.isNotEmpty) names.add(t);
  }

  (systemTags.isEmpty ? kLxImportDefaultSystemTags : systemTags).forEach(add);
  for (final d in directions) {
    if (d.tag.trim().isEmpty) continue;
    add(d.tag);
    // Двойник эмитится только у Направления с автовыбором
    // (`build_config.dart`, `emitAuto`): цель без него — ссылка в никуда.
    if (d.auto != null) add(d.autoTag);
  }
  chainTags.forEach(add);
  replaceTags.forEach(add);
  return names;
}

/// Теги корневых узлов [lists] — одиночных серверов, под которыми узел
/// эмитится (префикс сервера + тег узла, [containerFinalForm]).
Set<String> lxImportRootNodeTags(List<ServerList> lists) => {
      for (final l in lists)
        if (l is UserServer)
          // Сервер, заведённый этим импортом, узлов ещё не разобрал: они в тексте.
          for (final n in l.nodes.isNotEmpty ? l.nodes : _nodesOf(l.rawBody))
            if (n.tag.isNotEmpty) containerFinalForm(l, n.tag),
    };

/// D-117 — ЕДИНСТВЕННЫЙ список известных целей импорта (BACKUP.md §3): цели
/// правил (`backup_unknown_outbound`), `route.final`
/// (`backup_final_dropped`) и корневые имена подъёма ссылок.
///
/// Считается ПОСЛЕ слияния, по тому, что окажется у приёмника:
/// [lxImportRootNames] (служебные теги шаблона, Направления и их `-auto`,
/// цепочки), корневые узлы результата [lists], имена, которые приёмник знает
/// сам ([receiverTargets]), и зарезервированные литералы.
///
/// Раньше списков было два: экран строил его из хранения приёмника ДО
/// слияния, декодер дописывал теги файла, и ни один не видел `-auto`,
/// корневых узлов файла и служебных тегов шаблона — импорт в пустое состояние
/// выключал правила на цели, приехавшие этим же файлом.
///
/// `null` — «проверять нечем»: ни шаблона, ни Направлений, ни цепочек, ни
/// узлов, ни имён приёмника. Тогда цели не режутся — выключить всё подряд
/// хуже, чем импортировать как есть; умолчания служебных тегов такой список не
/// открывают.
Set<String>? lxImportKnownTargets({
  Iterable<Direction> directions = const [],
  Iterable<String> chainTags = const [],
  List<ServerList> lists = const [],
  Set<String> systemTags = const {},
  Set<String> receiverTargets = const {},
}) {
  final rootNodes = lxImportRootNodeTags(lists);
  final replaceTags = sourceReplaceNames(lists);
  final receiver = {
    for (final t in receiverTargets)
      if (t.trim().isNotEmpty) t.trim(),
  };
  if (systemTags.isEmpty &&
      directions.every((d) => d.tag.trim().isEmpty) &&
      chainTags.every((t) => t.trim().isEmpty) &&
      rootNodes.isEmpty &&
      replaceTags.isEmpty &&
      receiver.isEmpty) {
    return null;
  }
  return {
    ..._reservedOutbounds,
    ...lxImportRootNames(
      directions: directions,
      chainTags: chainTags,
      systemTags: systemTags,
      replaceTags: replaceTags,
    ),
    ...rootNodes,
    ...receiver,
  };
}

/// Цель правила так, как её называет файл: `outbound` правила inline/srs
/// (`reject` у отказа), `outbound` тела правила вида json. У пресета цели
/// нет — она из шаблона. Пустая строка — цели нет, проверять нечего.
String _ruleTarget(CustomRule r) => switch (r) {
      CustomRuleTree(:final outbound) => outbound,
      CustomRulePreset() => '',
      CustomRuleJson(:final json) => switch (_tryDecodeObject(json.trim())) {
          {'outbound': final String o} => o,
          _ => '',
        },
    };

/// D-117 — цели правил и `route.final` файла против списка известных целей
/// [known] ([lxImportKnownTargets]). Один проход на оба формата файла.
///
/// Правило с целью, которой нет, приезжает ВЫКЛЮЧЕННЫМ с
/// [kWarnUnknownOutbound], а не теряется: включённое правило с несуществующей
/// целью роняет конфиг ядра целиком. `route.final` в никуда не применяется
/// ([kWarnFinalDropped]): маршрут по умолчанию уводил бы весь трафик в
/// несуществующий outbound. `known == null` — проверять нечем, файл как есть.
///
/// Возвращает новый [LxBackupFile]: правила в том же порядке, предупреждения
/// дописаны в конец отчёта в порядке правил.
LxBackupFile gateLxBackupTargets(LxBackupFile file, Set<String>? known) {
  if (known == null) return file;
  final warnings = [...file.warnings];
  final rules = <CustomRule>[];
  for (final r in file.rules) {
    final target = _ruleTarget(r);
    if (target.isEmpty || _isKnownOutbound(target, known)) {
      rules.add(r);
      continue;
    }
    warnings.add(LxBackupWarning(kWarnUnknownOutbound,
        '${r.name.isEmpty ? r.kind.name : r.name} → $target'));
    rules.add(r.withEnabled(false));
  }
  var routeFinal = file.routeFinal;
  if (routeFinal != null &&
      routeFinal.isNotEmpty &&
      !_isKnownOutbound(routeFinal, known)) {
    warnings.add(LxBackupWarning(kWarnFinalDropped, routeFinal));
    routeFinal = null;
  }
  return LxBackupFile(
    version: file.version,
    exportedByApp: file.exportedByApp,
    exportedByVersion: file.exportedByVersion,
    exportedAt: file.exportedAt,
    directions: file.directions,
    directionPing: file.directionPing,
    rules: rules,
    rulesDeclared: file.rulesDeclared,
    chains: file.chains,
    chainHops: file.chainHops,
    chainPositions: file.chainPositions,
    subscriptions: file.subscriptions,
    servers: file.servers,
    folders: file.folders,
    dns: file.dns,
    warp: file.warp,
    mixins: file.mixins,
    vars: file.vars,
    routeFinal: routeFinal,
    warnings: warnings,
  );
}

List<String> _strList(Object? v) {
  if (v is List) return [for (final e in v) '$e'];
  return const [];
}

String _str(Object? v) => v is String ? v : '';

String _trimmed(Object? v) => v is String ? v.trim() : '';

Map<String, dynamic>? _obj(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : null;

List<Object?> _list(Object? v) => v is List ? v : const [];

/// §439 (D-111, BACKUP.md §2 «Одно правило — одно тело») — запись правила,
/// у которой на месте тела ([body]) массив, раскладывается на записи по
/// элементу-объекту в порядке массива, как если бы массив был развёрнут в
/// файле подряд: имена `name`, `name #2`… по порядку получившихся записей
/// (безымянная остаётся безымянной), `enabled` общий, `id` только у первой.
/// `num` общий: номера файла LxBox сохраняет ([renumberBackupAxis]), и
/// стабильная сортировка оси держит части подряд на месте исходной записи.
///
/// Элемент не объект — [kWarnUnknownField] ([where] называет место), прочие
/// части идут. Пустой массив — запись отбрасывается тем же кодом. Не массив —
/// запись как есть.
List<Map<String, dynamic>> _splitRuleBodies(
  Map<String, dynamic> record,
  Object? body,
  String where,
  List<LxBackupWarning> warnings,
) {
  if (body is! List) return [record];
  final name = _str(record['name']);
  final parts = <Map<String, dynamic>>[];
  for (var i = 0; i < body.length; i++) {
    final item = body[i];
    if (item is! Map) {
      warnings.add(
          LxBackupWarning(kWarnUnknownField, '$where[$i]: not an object'));
      continue;
    }
    parts.add({
      for (final e in record.entries)
        if (e.key != 'id' || parts.isEmpty) e.key: e.value,
      'name': parts.isEmpty || name.isEmpty ? name : '$name #${parts.length + 1}',
      'body': item.cast<String, dynamic>(),
    });
  }
  if (body.isEmpty) {
    warnings.add(LxBackupWarning(kWarnUnknownField, '$where: empty array'));
  }
  return parts;
}
/// Узлы текста одиночного сервера; не разобрался — пусто.
List<NodeSpec> _nodesOf(String raw) {
  if (raw.trim().isEmpty) return const [];
  try {
    return parseAll(decode(raw), own: true);
  } catch (_) {
    return const [];
  }
}
