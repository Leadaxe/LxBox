/// Переменные шаблона, пробрасываемые в `NodeSpec.emit(vars)`.
///
/// v1 брал их из `SettingsStorage` + `wizard_template.json` в разных местах;
/// v2 собирает один раз в `buildConfig` и передаёт вниз. Расширять по мере
/// нужды — пока только то, что реально влияет на emit узла.
class TemplateVars {
  /// Включить `tls_fragment: true` на первом хопе (без `detour`).
  final bool tlsFragment;

  /// Включить `tls_record_fragment: true` в паре с `tls_fragment`.
  final bool tlsRecordFragment;

  /// Глобальный mux — v2 пока не поддерживает на узле; заложено для будущего.
  final bool muxEnabled;

  /// Глобальный SNI-override (редко используется, обычно пусто).
  final String? sniOverride;

  const TemplateVars({
    this.tlsFragment = false,
    this.tlsRecordFragment = false,
    this.muxEnabled = false,
    this.sniOverride,
  });

  static const empty = TemplateVars();
}
