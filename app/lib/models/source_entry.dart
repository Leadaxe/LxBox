import 'server_list.dart';
import 'source_chain.dart';

/// §524 — ЗАПИСЬ ОБЩЕГО СПИСКА ИСТОЧНИКОВ: один упорядоченный род сущности
/// над записями `sources[]` (§439/§509).
///
/// Решение владельца 24.09: «как мы храним по маркеру kind, так мы должны и
/// структуру держать. У нас есть узлы, прямые узлы, автоматические узлы,
/// узлы-цепочки и папки/подписки с узлами внутри. Разных списков быть не
/// должно.» На диске список УЖЕ единый — один массив `sources[]` с
/// дискриминатором `kind`, порядок записей нормативен. Расщепление жило
/// ВЫШЕ диска: `ServerList` (sealed «контейнер узлов») и `SourceChain`
/// (самостоятельный класс) не имели общего супертипа, и каждый слой сшивал
/// два списка сам.
///
/// Этот тип — ровно тот супертип. Формат на диске НЕ меняется: запись
/// сериализуется теми же кодеками (`codec/source_record.dart`,
/// `codec/chain_record.dart`), идентичность остаётся своей у каждого рода
/// (uuid у контейнера, тег у цепочки) — [sourceKey] лишь накрывает обе.
///
/// Члены:
///   • [ContainerEntry] — подписка / одиночный сервер / папка ([ServerList]);
///   • [ChainEntry]     — цепочка ([SourceChain]);
///   • [OpaqueEntry]    — запись, которую кодек не прочитал (§141 P1.8c):
///     чужой или будущий `kind`, битый JSON. Едет дословно, слот свой не
///     теряет (долг §511:54-59 закрыт: раньше такая запись выживала только
///     потому, что писатель её не трогал, — теперь она полноправный элемент
///     списка).
sealed class SourceEntry {
  const SourceEntry();

  /// Ключ записи в общем порядке: `id:<uuid>` у контейнера, `chain:<tag>` у
  /// цепочки, `raw:<индекс-в-массиве>` у непрозрачной (её нечем адресовать —
  /// у неё нет ни читаемого `id`, ни тега; см. [OpaqueEntry.slot]).
  ///
  /// Идентичность записи НЕ меняется: ключ производный, не хранится.
  String get sourceKey;

  /// `kind` записи на диске: `subscription`/`server`/`folder`/`chain` либо то,
  /// что стояло в нечитаемой записи (может быть пусто).
  String get kind;

  /// Участвует ли запись в сборке конфига. Непрозрачная — нет: модели её нет.
  bool get enabled;

  /// Имя для показа. У непрозрачной — пусто: врать о содержимом нельзя.
  String get displayLabel;
}

/// Подписка, одиночный сервер или папка — контейнер узлов.
final class ContainerEntry extends SourceEntry {
  const ContainerEntry(this.list);

  final ServerList list;

  @override
  String get sourceKey => sourceKeyForIdOf(list.id);

  @override
  String get kind => list.type;

  @override
  bool get enabled => list.enabled;

  @override
  String get displayLabel => list.name;
}

/// Цепочка — такой же источник, как одиночный или авто-сервер (решение
/// владельца: «Цепочки — такие же серверы, как авто-серверы»).
final class ChainEntry extends SourceEntry {
  const ChainEntry(this.chain);

  final SourceChain chain;

  @override
  String get sourceKey => sourceKeyForChainOf(chain.tag);

  @override
  String get kind => kSourceKindChainKey;

  @override
  bool get enabled => chain.enabled;

  @override
  String get displayLabel => chain.displayLabel;
}

/// Запись, которую кодек не прочитал. Держится дословно и на своём месте.
///
/// [slot] — индекс записи в массиве на момент чтения: единственная
/// адресация, которая у такой записи есть. Ключ поэтому нестабилен между
/// перестановками — это допустимо ровно потому, что записи нет ни в UI, ни в
/// сборке конфига: её адресуют только «останься где стоишь» (см.
/// `_writeEntries` в `sources_rules.dart`).
final class OpaqueEntry extends SourceEntry {
  const OpaqueEntry(this.record, this.slot);

  /// Сырая запись: пишется байт в байт тем же объектом, что прочитан.
  final Map<String, dynamic> record;

  final int slot;

  @override
  String get sourceKey => 'raw:$slot';

  @override
  String get kind => '${record['kind'] ?? ''}';

  @override
  bool get enabled => false;

  @override
  String get displayLabel => '';
}

/// Ключ записи подписки/сервера/папки в общем порядке `sources[]`.
///
/// Форма `id:<uuid>` / `chain:<tag>` — та же, что была у
/// `SettingsStorage.sourceKeyForId`/`sourceKeyForChain` (§509): ключи уже
/// лежат в state экранов и в логах, менять их незачем.
String sourceKeyForIdOf(String id) => 'id:$id';

/// Ключ записи цепочки в общем порядке `sources[]`.
String sourceKeyForChainOf(String tag) => 'chain:$tag';

/// `kind` цепочки. Дублируется здесь, а не импортируется из кодека, чтобы
/// модель не зависела от слоя сериализации.
const String kSourceKindChainKey = 'chain';
