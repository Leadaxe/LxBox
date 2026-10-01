/// Переменные шаблона, пробрасываемые в `NodeSpec.emit(vars)`.
///
/// §593 — полей нет: фрагментация TLS пишется своим путём (016 · фрагментация
/// TLS), прежние поля флагов фрагментации, mux и SNI никто не читал. Класс остаётся как часть сигнатуры `emit`/`emitRaw`
/// (`node_spec.dart`); его снятие — отдельный рефакторинг.
class TemplateVars {
  const TemplateVars();

  static const empty = TemplateVars();
}
