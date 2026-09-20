/// §439 §1.3 — срез записи хранения для LX Backup 1.0: одна таблица полей.
///
/// Экспорт берёт запись хранения кодеком (`models/codec/`) и пропускает её
/// через [sliceBackupRecord]: поле контракта едет как есть, настройка LxBox
/// без дома в 1.0 срезается и называется, рантайм и служебные маркеры
/// срезаются молча. Импорт снимает те же поля с приехавшей записи
/// ([stripUndeclaredBackupFields]) до кодека: их называет обход неизвестных
/// ключей (`backup_unknown_field`), в состояние они не попадают.
///
/// Флаг [BackupField.declared] — ответ лаунчера Л2 (§439 §6.4): поле LxBox,
/// объявленное схемой с поддержкой «LxBox», едет в файл как есть, импорт его
/// применяет, а обход ключей его знает ([declaredBackupKeys]). Снять срез с
/// поля — правка флага в [kBackupFields], ничего больше. Контракт 1.0.1
/// объявил поля `BACKUP.md` §2 «Поля стороны LxBox»; не объявлено DNS-правило
/// `kind: srs`.
///
/// Таблица перечисляет ВСЕ ключи записей хранения: ключ, которого в ней нет,
/// экспорт срезает и называет, чтобы новое поле кодека не уехало и не
/// потерялось молча.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Вид записи хранения, чьи поля перечисляет [kBackupFields].
enum BackupRecord {
  subscription,
  server,
  folder,

  /// Член папки (`sources[].nodes[]`).
  folderNode,
  chain,

  /// Правило маршрута — корневое и в секциях узла.
  rule,
  dnsServer,
  dnsRule,
}

/// Что делает экспорт с полем записи хранения.
enum BackupFieldFate {
  /// Поле контракта 1.0: едет как есть.
  contract,

  /// Настройка пользователя без дома в 1.0: срезается и называется
  /// `backup_local_only_dropped`, пока контракт её не объявит.
  setting,

  /// Рантайм машины, кэш, служебный маркер: срезается молча.
  runtime,
}

/// Строка таблицы среза.
///
/// [key] — ключ записи хранения. Вид записи целиком, которого у контракта
/// нет, записан ключом `kind:<вид>` (DNS-правила `srs` и `template`): такая
/// запись не пишется вовсе.
final class BackupField {
  const BackupField(this.record, this.key, this.fate, {this.declared = false});

  final BackupRecord record;
  final String key;
  final BackupFieldFate fate;

  /// Л2 — поле объявлено схемой контракта с поддержкой «LxBox».
  final bool declared;

  /// Едет ли поле в файл.
  bool get travels => fate == BackupFieldFate.contract || declared;
}

const _c = BackupFieldFate.contract;
const _s = BackupFieldFate.setting;
const _r = BackupFieldFate.runtime;

/// Таблица среза (§439 §1.3). Порядок строк — порядок ключей записи в кодеке.
const List<BackupField> kBackupFields = [
  // ── подписка ──────────────────────────────────────────────────────────────
  BackupField(BackupRecord.subscription, 'kind', _c),
  BackupField(BackupRecord.subscription, 'id', _c),
  BackupField(BackupRecord.subscription, 'name', _c),
  BackupField(BackupRecord.subscription, 'enabled', _c),
  BackupField(BackupRecord.subscription, 'url', _c),
  BackupField(BackupRecord.subscription, 'tag_policy', _c),
  BackupField(BackupRecord.subscription, 'identity', _c),
  BackupField(BackupRecord.subscription, 'update', _c),
  BackupField(BackupRecord.subscription, 'disabled', _c),
  // Фича 478 / CANON §9.4 — ключ в allowlist хранения; в бэкап вердикт
  // страховки не едет (§489, решение 19.09.2026).
  BackupField(BackupRecord.subscription, 'warnings', _c),
  BackupField(BackupRecord.subscription, 'detour', _c),
  BackupField(BackupRecord.subscription, 'detour_policy', _s, declared: true),
  BackupField(BackupRecord.subscription, 'import_rules', _s, declared: true),
  BackupField(BackupRecord.subscription, 'import_rules_enabled', _s,
      declared: true),
  BackupField(BackupRecord.subscription, 'on_update_action', _s,
      declared: true),
  // BACKUP.md §2: метаданные выдачи и история обновлений — рантайм машины.
  BackupField(BackupRecord.subscription, 'meta', _r),
  BackupField(BackupRecord.subscription, 'last_updated', _r),
  BackupField(BackupRecord.subscription, 'last_update_attempt', _r),
  BackupField(BackupRecord.subscription, 'last_update_status', _r),
  BackupField(BackupRecord.subscription, 'last_node_count', _r),
  BackupField(BackupRecord.subscription, 'consecutive_fails', _r),

  // ── одиночный сервер ─────────────────────────────────────────────────────
  BackupField(BackupRecord.server, 'kind', _c),
  BackupField(BackupRecord.server, 'id', _c),
  BackupField(BackupRecord.server, 'tag', _c),
  BackupField(BackupRecord.server, 'enabled', _c),
  // Фича 478 — ключ хранения; в бэкап вердикт страховки не едет (§489).
  BackupField(BackupRecord.server, 'warnings', _c),
  BackupField(BackupRecord.server, 'origin', _c),
  // Хранение `body` не пишет; экспорт дописывает его JSON-исходнику (§4.1).
  BackupField(BackupRecord.server, 'body', _c),
  BackupField(BackupRecord.server, 'detour', _c),
  BackupField(BackupRecord.server, 'sections', _c),
  BackupField(BackupRecord.server, 'detour_policy', _s, declared: true),
  BackupField(BackupRecord.server, 'tag_policy', _s, declared: true),

  // ── папка ────────────────────────────────────────────────────────────────
  BackupField(BackupRecord.folder, 'kind', _c),
  BackupField(BackupRecord.folder, 'id', _c),
  BackupField(BackupRecord.folder, 'name', _c),
  BackupField(BackupRecord.folder, 'enabled', _c),
  BackupField(BackupRecord.folder, 'tag_policy', _c),
  BackupField(BackupRecord.folder, 'detour', _c),
  BackupField(BackupRecord.folder, 'detour_policy', _s, declared: true),
  BackupField(BackupRecord.folder, 'ping_url', _s, declared: true),
  BackupField(BackupRecord.folder, 'ping_timeout_ms', _s, declared: true),
  BackupField(BackupRecord.folder, 'created_at', _r),
  BackupField(BackupRecord.folder, 'nodes', _c),

  // ── член папки ───────────────────────────────────────────────────────────
  BackupField(BackupRecord.folderNode, 'kind', _c),
  BackupField(BackupRecord.folderNode, 'tag', _c),
  BackupField(BackupRecord.folderNode, 'enabled', _c),
  // Фича 478 — ключ хранения; в бэкап вердикт страховки не едет (§489).
  BackupField(BackupRecord.folderNode, 'warnings', _c),
  BackupField(BackupRecord.folderNode, 'origin', _c),
  BackupField(BackupRecord.folderNode, 'body', _c),
  BackupField(BackupRecord.folderNode, 'detour', _c),
  BackupField(BackupRecord.folderNode, 'reason', _c),
  BackupField(BackupRecord.folderNode, 'sections', _c),
  // Член-группа `kind: auto` (§439 N2): состав и стратегия — `group`; поля
  // стороны LxBox `members_rule` и `pool_badge` лежат внутри `group`
  // (контракт 1.0.1) и едут вместе с ним.
  BackupField(BackupRecord.folderNode, 'group', _c),

  // ── цепочка ──────────────────────────────────────────────────────────────
  BackupField(BackupRecord.chain, 'kind', _c),
  BackupField(BackupRecord.chain, 'tag', _c),
  BackupField(BackupRecord.chain, 'enabled', _c),
  BackupField(BackupRecord.chain, 'label', _s, declared: true),
  BackupField(BackupRecord.chain, 'body', _c),
  BackupField(BackupRecord.chain, 'hops', _c),

  // ── правило маршрута ─────────────────────────────────────────────────────
  BackupField(BackupRecord.rule, 'kind', _c),
  BackupField(BackupRecord.rule, 'id', _c),
  BackupField(BackupRecord.rule, 'name', _c),
  BackupField(BackupRecord.rule, 'enabled', _c),
  BackupField(BackupRecord.rule, 'num', _c),
  BackupField(BackupRecord.rule, 'refs', _c),
  BackupField(BackupRecord.rule, 'update_interval_hours', _s, declared: true),
  BackupField(BackupRecord.rule, 'ref', _c),
  BackupField(BackupRecord.rule, 'vars', _c),
  // Маркер: тело едет, настройки пользователя в нём нет (§1.3); объявлен
  // контрактом 1.0.1 и едет, чтобы тело на приёмнике не перетипизировалось.
  BackupField(BackupRecord.rule, 'verbatim', _r, declared: true),
  BackupField(BackupRecord.rule, 'body', _c),
  BackupField(BackupRecord.rule, 'dns', _c),
  BackupField(BackupRecord.rule, 'resolve', _c),

  // ── DNS-сервер ───────────────────────────────────────────────────────────
  BackupField(BackupRecord.dnsServer, 'kind', _c),
  BackupField(BackupRecord.dnsServer, 'tag', _c),
  BackupField(BackupRecord.dnsServer, 'ref', _c),
  BackupField(BackupRecord.dnsServer, 'enabled', _c),
  BackupField(BackupRecord.dnsServer, 'body', _c),
  // `vars` — поле только `kind: template` (Л5): у `user` и `preset` импорт
  // называет ключ `backup_unknown_field` (обход ключей `lx_backup.dart`).
  BackupField(BackupRecord.dnsServer, 'vars', _s, declared: true),
  BackupField(BackupRecord.dnsServer, 'description', _s, declared: true),

  // ── DNS-правило ──────────────────────────────────────────────────────────
  BackupField(BackupRecord.dnsRule, 'kind', _c),
  BackupField(BackupRecord.dnsRule, 'id', _c),
  BackupField(BackupRecord.dnsRule, 'name', _c),
  BackupField(BackupRecord.dnsRule, 'ref', _c),
  BackupField(BackupRecord.dnsRule, 'enabled', _c),
  BackupField(BackupRecord.dnsRule, 'body', _c),
  BackupField(BackupRecord.dnsRule, 'kind:srs', _s),
  // Ссылка на правило шаблона: сторона заводит его сама по своему шаблону.
  BackupField(BackupRecord.dnsRule, 'kind:template', _r),
];

Map<BackupRecord, Map<String, BackupField>> _index(List<BackupField> fields) => {
      for (final kind in BackupRecord.values)
        kind: {
          for (final f in fields)
            if (f.record == kind) f.key: f,
        },
    };

Map<BackupRecord, Map<String, BackupField>> _byRecord = _index(kBackupFields);

/// Подмена таблицы среза в тестах: проверка того, что снятие среза с поля —
/// правка флага [BackupField.declared], и больше ничего (Л2). `null` —
/// вернуть [kBackupFields].
@visibleForTesting
void overrideBackupFieldsForTesting(List<BackupField>? fields) {
  _byRecord = _index(fields ?? kBackupFields);
}

/// Ключи полей LxBox, объявленных контрактом (Л2): обход неизвестных ключей
/// импорта знает их наравне с полями контракта.
Set<String> declaredBackupKeys(BackupRecord record) => {
      for (final f in _byRecord[record]!.values)
        if (f.declared && f.fate != BackupFieldFate.contract) f.key,
    };

/// Пишется ли запись вида [kind] (строка `kind:<вид>` таблицы). Вид без
/// строки — вид контракта.
bool backupKindTravels(BackupRecord record, String kind) =>
    _byRecord[record]!['kind:$kind']?.travels ?? true;

/// Итог среза записи: запись файла (`null` — вид записи не пишется) и
/// названные потери — ключи срезанных настроек, отличных от умолчания.
typedef BackupSlice = ({Map<String, dynamic>? record, List<String> dropped});

/// Экспорт: запись хранения → запись файла по [kBackupFields].
///
/// Порядок ключей — порядок записи хранения. Секции узла и члены папки
/// срезаются той же таблицей; их потери называются путём
/// (`sections.dns.servers[<тег>].description`, `nodes[<тег>].…`).
BackupSlice sliceBackupRecord(
  BackupRecord record,
  Map<String, dynamic> stored,
) {
  final fields = _byRecord[record]!;
  final kindRow = fields['kind:${stored['kind']}'];
  if (kindRow != null && !kindRow.travels) {
    return (
      record: null,
      dropped: [
        if (kindRow.fate == BackupFieldFate.setting) '${stored['kind']}',
      ],
    );
  }
  final out = <String, dynamic>{};
  final dropped = <String>[];
  for (final e in stored.entries) {
    final field = fields[e.key];
    if (field == null) {
      // Ключа нет в таблице: не угадываем, едет ли он, — срез с названием.
      dropped.add(e.key);
      continue;
    }
    if (!field.travels) {
      if (field.fate == BackupFieldFate.setting &&
          !_isDefault(record, e.key, e.value, stored)) {
        dropped.add(e.key);
      }
      continue;
    }
    out[e.key] = switch (e.key) {
      'sections' when e.value is Map && _carriesSections(record) =>
        _sliceSections((e.value as Map).cast<String, dynamic>(), dropped),
      'nodes' when e.value is List && record == BackupRecord.folder =>
        _sliceNodes(e.value as List, dropped),
      _ => e.value,
    };
  }
  return (record: out, dropped: dropped);
}

/// Импорт: приехавшая запись без полей LxBox, которых контракт не объявил, —
/// вглубь секций узла и членов папки. Прочее не трогается.
Map<String, dynamic> stripUndeclaredBackupFields(
  BackupRecord record,
  Map<String, dynamic> incoming,
) {
  final fields = _byRecord[record]!;
  final out = <String, dynamic>{};
  for (final e in incoming.entries) {
    final field = fields[e.key];
    if (field != null && !field.travels) continue;
    out[e.key] = switch (e.key) {
      'sections' when e.value is Map && _carriesSections(record) =>
        _mapSections((e.value as Map).cast<String, dynamic>(),
            (kind, r) => stripUndeclaredBackupFields(kind, r)),
      'nodes' when e.value is List && record == BackupRecord.folder => [
          for (final n in e.value as List)
            n is Map
                ? stripUndeclaredBackupFields(
                    BackupRecord.folderNode, n.cast<String, dynamic>())
                : n,
        ],
      _ => e.value,
    };
  }
  return out;
}

bool _carriesSections(BackupRecord record) =>
    record == BackupRecord.server || record == BackupRecord.folderNode;

/// Поле настройки со значением «ничего не задано» потерей не называется.
///
/// Имя цепочки, равное её тегу, — то же, что пустое: показ падает на тег
/// (`SourceChain.displayLabel`), а Debug API заводит цепочку с `label` = тег.
/// Приехавшая без имени цепочка выглядит так же, потери нет.
bool _isDefault(
  BackupRecord record,
  String key,
  Object? v,
  Map<String, dynamic> stored,
) =>
    v == null ||
    (v is String && v.isEmpty) ||
    (v is Map && v.isEmpty) ||
    (v is List && v.isEmpty) ||
    (record == BackupRecord.chain && key == 'label' && v == stored['tag']);

List<dynamic> _sliceNodes(List<dynamic> nodes, List<String> dropped) => [
      for (var i = 0; i < nodes.length; i++)
        if (nodes[i] case final Map node)
          _sliceNested(BackupRecord.folderNode, node.cast<String, dynamic>(),
              'nodes[${_label(node, 'tag', i)}]', dropped)
        else
          nodes[i],
    ];

Map<String, dynamic> _sliceSections(
  Map<String, dynamic> sections,
  List<String> dropped,
) {
  final counters = <String, int>{};
  return _mapSections(sections, (kind, record) {
    final list = switch (kind) {
      BackupRecord.rule => 'rules',
      BackupRecord.dnsServer => 'dns.servers',
      _ => 'dns.rules',
    };
    final i = counters.update(list, (n) => n + 1, ifAbsent: () => 0);
    final label = _label(record, kind == BackupRecord.dnsServer ? 'tag' : 'name', i);
    return _sliceNested(kind, record, 'sections.$list[$label]', dropped);
  });
}

/// Срез вложенной записи; её потери — путём от записи-носителя. Вид записи,
/// который не пишется, в секциях узла не встречается (там только `user`), и
/// запись остаётся как есть.
Map<String, dynamic> _sliceNested(
  BackupRecord kind,
  Map<String, dynamic> record,
  String path,
  List<String> dropped,
) {
  final slice = sliceBackupRecord(kind, record);
  dropped.addAll(slice.dropped.map((k) => '$path.$k'));
  return slice.record ?? record;
}

/// Секции узла с записями, пропущенными через [each] по виду записи.
Map<String, dynamic> _mapSections(
  Map<String, dynamic> sections,
  Map<String, dynamic> Function(BackupRecord, Map<String, dynamic>) each,
) {
  List<dynamic> records(Object? list, BackupRecord kind) => [
        for (final r in list is List ? list : const [])
          r is Map ? each(kind, r.cast<String, dynamic>()) : r,
      ];

  final out = <String, dynamic>{};
  for (final e in sections.entries) {
    switch (e.key) {
      case 'rules' when e.value is List:
        out['rules'] = records(e.value, BackupRecord.rule);
      case 'dns' when e.value is Map:
        final dns = (e.value as Map).cast<String, dynamic>();
        out['dns'] = {
          for (final d in dns.entries)
            d.key: switch (d.key) {
              'servers' when d.value is List =>
                records(d.value, BackupRecord.dnsServer),
              'rules' when d.value is List =>
                records(d.value, BackupRecord.dnsRule),
              _ => d.value,
            },
        };
      default:
        out[e.key] = e.value;
    }
  }
  return out;
}

String _label(Map<dynamic, dynamic> record, String key, int index) {
  final v = record[key];
  return v is String && v.isNotEmpty ? v : '#${index + 1}';
}
