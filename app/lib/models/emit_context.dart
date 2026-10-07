import '../services/builder/node_link_resolve.dart';
import '../services/builder/rule_set_registry.dart';
import '../services/builder/source_replace_build.dart' show ReplacePlan;
import 'node_spec.dart';
import 'node_warning.dart' show RegistryWarning;
import 'singbox_entry.dart';
import 'template_vars.dart';

/// Контекст одного вызова `buildConfig`. `ServerList.build(ctx)` использует
/// его, чтобы:
///  - передать `vars` в `emit` узла (сейчас без полей, §593);
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

  /// Общий реестр для `route.rule_set` / `route.rules` секций. Живёт один
  /// на весь `buildConfig`, доступен post-steps и ServerList.build'у.
  /// Flush в `config.route` делает сам `buildConfig` в конце.
  RuleSetRegistry get ruleSets;

  /// §435 — финальный тег эмитированного узла (после префикса контейнера и
  /// `allocateTag`). По нему `buildConfig` собирает узлы для `for_each`
  /// пресетов (§578) и адресный индекс; узла, которого здесь нет, в конфиге
  /// нет.
  void noteEmitted(NodeSpec node, String finalTag) {}

  /// Фича 478 / PARSING_PRINCIPLES §9.3 — дополнительный outbound (хоп родной цепочки)
  /// ведёт к [owner], а не к своему звену. При коллизии с main-тегом того же
  /// узла побеждает [noteEmitted].
  void noteEmittedAlias(String finalTag, NodeSpec owner) {}

  /// §435 — предупреждение сборки из `ServerList.build` (гейт ядра и т.п.):
  /// уходит в `emitWarnings` наравне с остальными строками отчёта.
  void warn(String line) {}

  /// §612 (контракт 1.1.112–1.1.113) — запись отчёта сборки КОДОМ реестра
  /// (`group_default_dropped`): строку для `emitWarnings` рендерит сборка по
  /// тексту реестра, запись ложится в предупреждения адресата
  /// ([RegistryWarning.ownerTag] — финальный тег).
  void code(RegistryWarning w) {}

  /// Фича 565 фаза B (§74) — свёрнутый источник отдаёт узлы не в пул
  /// Направлений, а плану свёртки; группы разворачивает сборка после
  /// отбраковок узлов (`source_replace_build.dart`).
  void addReplacePlan(ReplacePlan plan) {}

  /// §77 п.5 (контракт 1.1.80) — свёртка источника [listId] не собирается:
  /// её тег занят другим объявленным именем (`replace_tag_conflict`), и
  /// источник идёт несвёрнутым.
  bool isReplaceBlocked(String listId) => false;

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
