/// §704 — миксин: хранимая операция над итоговым конфигом ядра.
///
/// Цель — путь своего языка (`lib/services/mixins/mixin_path.dart`), глагол
/// [MixinOp] и JSON-значение. Применяется в самом конце сборки
/// (`applyMixins`, после `sanitizeOutboundGraph`), переживает пересборки,
/// едет в LX Backup (секция `mixins` без `id`), доступна через Debug API
/// `/mixins`. Один миксин = одна операция; группировка — порядок в списке
/// и имя.
library;

import 'dart:convert';

import '../services/parser/uri_utils.dart' show newUuidV4;

/// Глагол миксина. Имя в хранилище = [name] enum'а.
enum MixinOp {
  append,
  prepend,
  before,
  after,
  set,
  merge,
  remove;

  /// `null` — имя не из семи глаголов.
  static MixinOp? fromName(String? name) {
    for (final op in values) {
      if (op.name == name) return op;
    }
    return null;
  }
}

class Mixin {
  /// UUID v4; у записи из файла бэкапа — новый при импорте.
  final String id;

  /// Пустое допустимо: в списке тогда показывается `target → op`
  /// ([displayName]).
  final String name;

  /// Выключенный миксин при сборке пропускается.
  final bool enabled;

  /// Строка пути (§3 спеки 704). Пустая — корень конфига.
  final String target;

  /// Имя глагола как в хранилище. Строкой, а не [MixinOp]: неизвестный
  /// глагол (рука, чужой бэкап) должен дожить до сборки и стать issue, а не
  /// молча потеряться при чтении. Разобранный — [opKind].
  final String op;

  /// Любой JSON. У `remove` — `true` (узел целиком) или список ключей.
  final Object? value;

  Mixin({
    String? id,
    this.name = '',
    this.enabled = true,
    required this.target,
    required this.op,
    this.value,
  }) : id = (id == null || id.isEmpty) ? newUuidV4() : id;

  MixinOp? get opKind => MixinOp.fromName(op);

  /// Имя для списка и сообщений: пустое имя — `target → op`.
  String get displayName => name.isNotEmpty ? name : '$target → $op';

  /// Тело миксина без `id`/`name`/`enabled` — ключ совпадения при импорте
  /// бэкапа (одинаковые цель, глагол и значение — тот же миксин).
  String get bodyKey => jsonEncode([target, op, value]);

  Mixin copyWith({
    String? id,
    String? name,
    bool? enabled,
    String? target,
    String? op,
    Object? value = _keep,
  }) =>
      Mixin(
        id: id ?? this.id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        target: target ?? this.target,
        op: op ?? this.op,
        value: identical(value, _keep) ? this.value : value,
      );

  /// Форма хранилища и Debug API. `value` пишется всегда (в том числе
  /// `null`): ключ без значения у `set` — осмысленный `null`.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'target': target,
        'op': op,
        'value': value,
      };

  /// Запись секции `mixins` LX Backup: без `id`.
  Map<String, dynamic> toBackupJson() => {
        'name': name,
        'enabled': enabled,
        'target': target,
        'op': op,
        'value': value,
      };

  /// Терпимое чтение: битые поля — дефолты, отсутствующий `id` — новый.
  factory Mixin.fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final name = j['name'];
    final enabled = j['enabled'];
    final target = j['target'];
    final op = j['op'];
    return Mixin(
      id: id is String ? id : null,
      name: name is String ? name : '',
      enabled: enabled is bool ? enabled : true,
      target: target is String ? target : '',
      op: op is String ? op : '',
      value: j['value'],
    );
  }

  @override
  String toString() => 'Mixin($id, $displayName)';
}

const Object _keep = Object();
