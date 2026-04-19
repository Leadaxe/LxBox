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
}
