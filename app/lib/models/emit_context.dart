import '../services/builder/node_link_resolve.dart';
import '../services/builder/rule_set_registry.dart';
import '../services/builder/source_replace_build.dart' show ReplacePlan;
import 'node_spec.dart';
import 'singbox_entry.dart';
import 'template_vars.dart';

/// Контекст одного вызова `buildConfig`. `ServerList.build(ctx)` использует
/// его, чтобы:
///  - взять глобальные флаги (tls_fragment и пр.) — `vars`;
///  - зарезервировать уникальный тег — `allocateTag(base)`;
///  - положить entry в итоговый `outbounds[]` / `endpoints[]` — `addEntry(e)`
///    (sealed-switch внутри ctx по типу);
///  - отметить entry как участника preset-групп:
///    - `addToSelectorTagList(e)` → попадёт в vpn-1/2/3;
///    - `addToAutoList(e)` → попадёт в auto-proxy-out (urltest).
///
/// Регистрируем **entry целиком**, не просто тэг. SingboxEntry сам отдаёт
/// текущий `tag` через геттер — если post-step переименует, preset-группы
/// увидят новое имя.
abstract class EmitContext {
  TemplateVars get vars;

  /// Зарезервировать уникальный тег на базе `baseTag`. Если уже занят —
  /// возвращает `baseTag-1`, `-2` и т.д.
  String allocateTag(String baseTag);

  /// Положить entry в outbounds[] или endpoints[] (по sealed-типу).
  void addEntry(SingboxEntry entry);

  /// Пометить, что этот entry попадает в selector-группы (vpn-1/2/3).
  void addToSelectorTagList(SingboxEntry entry);

  /// Пометить, что этот entry попадает в auto-proxy-out (urltest).
  void addToAutoList(SingboxEntry entry);

  /// §272/§322 — глобальная настройка «Passive health check»: пока свежий
  /// успешный дайл подтверждает узел, периодическая проба пропускается.
  /// Направления получают её напрямую в `buildConfig`; узлам автовыбора (§322)
  /// она нужна здесь — их эмитит `ServerList.build`, куда настройки не
  /// доходят. Дефолт `false` — апстрим-поведение, как omitempty у ядра.
  bool get passiveCheck => false;

  /// Общий реестр для `route.rule_set` / `route.rules` секций. Живёт один
  /// на весь `buildConfig`, доступен post-steps и ServerList.build'у.
  /// Flush в `config.route` делает сам `buildConfig` в конце.
  RuleSetRegistry get ruleSets;

  /// §435 — финальный тег эмитированного узла (после префикса контейнера и
  /// `allocateTag`). По нему `buildConfig` инжектит секции узла
  /// (`@self` → этот тег); узел, которого здесь нет, секций не даёт.
  void noteEmitted(NodeSpec node, String finalTag) {}

  /// Фича 478 / PARSING_PRINCIPLES §9.3 — дополнительный outbound (хоп родной цепочки)
  /// ведёт к [owner], а не к своему звену. При коллизии с main-тегом того же
  /// узла побеждает [noteEmitted].
  void noteEmittedAlias(String finalTag, NodeSpec owner) {}

  /// §473 — запись, чьё тело взято ДОСЛОВНО из JSON-источника (§455,
  /// `verbatimBodyOf`), а не собрано `emit()` модели.
  ///
  /// Нужно гарду реестра на сборке: у такой записи вход — `singbox`, и
  /// правило `max_when.except_sources` оставляет ей значение, которое на
  /// прочих входах заменило бы потолком. Гард работает над `SingboxEntry`, а
  /// он источника не знает и знать не может — карту ведёт тот, кто тело
  /// подставил.
  void noteVerbatim(SingboxEntry entry) {}

  /// §435 — предупреждение сборки из `ServerList.build` (гейт ядра и т.п.):
  /// уходит в `emitWarnings` наравне с остальными строками отчёта.
  void warn(String line) {}

  /// Фича 565 фаза B (§74) — свёрнутый источник отдаёт узлы не в пул
  /// Направлений, а плану свёртки; группы разворачивает сборка после
  /// отбраковок узлов (`source_replace_build.dart`).
  void addReplacePlan(ReplacePlan plan) {}

  /// §435 — строка версии ядра для текста предупреждения гейта.
  String get coreVersion => '';

  /// §439 (D-112) — словарь целей ссылок на узлы этой сборки: `build`
  /// записывает сюда финальные теги узлов под их адресами. `null` — адреса
  /// никому не нужны.
  NodeLinkTargets? get linkTargets => null;

  /// §439 — detour-ссылка узла разрешается вторым проходом, когда финальные
  /// теги всех источников известны (`resolveDeferredDetours`). Контекст без
  /// сборки конфига ссылку отбрасывает.
  void deferDetour(DeferredDetour detour) {}
}
