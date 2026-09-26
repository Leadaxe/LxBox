/// Свёртка источника в группу (фича 565, фаза B; контракт 1.1.78 §74,
/// `backup.schema.json#/$defs/replace`): папка или подписка отдаёт
/// Направлениям и правилам не свои узлы, а ОДНУ группу под корневым именем
/// [SourceReplace.tag]. Нет объекта у источника — источник не свёрнут.
///
/// Форма одна в хранении, в бэкапе и у лаунчера (`replace {mode, tag, auto}`);
/// кодек записи — `codec/source_replace_record.dart`. Параметры автовыбора —
/// та же модель, что у двойника Направления ([DirectionAuto]).
library;

import 'package:collection/collection.dart';

import 'direction.dart';

/// Режим свёртки. Имена значений — строки записи (`mode`).
enum ReplaceMode {
  /// Ручной селектор `tag` из всех узлов источника.
  manual,

  /// Автовыбор `tag` по параметрам [SourceReplace.auto].
  auto,

  /// Селектор `tag`, первая опция и умолчание — автовыбор `<tag>-auto`.
  both;

  /// Неизвестное значение читается как [manual] (§74): свёрнутый источник
  /// обязан дать хоть какую-то группу.
  static ReplaceMode fromWire(Object? raw) =>
      ReplaceMode.values.firstWhereOrNull((m) => m.name == raw) ??
      ReplaceMode.manual;
}

class SourceReplace {
  const SourceReplace({
    required this.mode,
    required this.tag,
    this.auto,
  });

  final ReplaceMode mode;

  /// Явное имя группы в конфиге — корневое имя (ссылка без `folder_id`).
  final String tag;

  /// Параметры автовыбора: у [ReplaceMode.auto] и [ReplaceMode.both]; `null`
  /// — умолчания [DirectionAuto]. У [ReplaceMode.manual] не хранится.
  final DirectionAuto? auto;

  /// Есть ли у свёртки автовыбор.
  bool get hasAuto => mode != ReplaceMode.manual;

  /// Есть ли у свёртки ручной селектор.
  bool get hasSelector => mode != ReplaceMode.auto;

  /// Параметры автовыбора для сборки.
  DirectionAuto get autoOrDefault => auto ?? const DirectionAuto();

  /// Тег автовыбора: у `both` — двойник `<tag>-auto` (формула двойников
  /// Направлений, [kDirectionAutoSuffix]), у `auto` — сам [tag].
  String get autoTag =>
      mode == ReplaceMode.both ? '${tag.trim()}$kDirectionAutoSuffix' : tag.trim();

  /// Корневые имена, которые свёртка занимает: [tag], у `both` ещё двойник.
  /// Пустой тег имён не даёт — групп у такой свёртки нет (§74 п.1).
  List<String> get names {
    final t = tag.trim();
    if (t.isEmpty) return const [];
    return [t, if (mode == ReplaceMode.both) '$t$kDirectionAutoSuffix'];
  }

  SourceReplace copyWith({
    ReplaceMode? mode,
    String? tag,
    DirectionAuto? auto,
  }) =>
      SourceReplace(
        mode: mode ?? this.mode,
        tag: tag ?? this.tag,
        auto: auto ?? this.auto,
      );

  static const _eq = DeepCollectionEquality();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SourceReplace &&
          mode == other.mode &&
          tag == other.tag &&
          _eq.equals(auto?.toJson(), other.auto?.toJson()));

  @override
  int get hashCode => Object.hash(mode, tag, _eq.hash(auto?.toJson()));
}
