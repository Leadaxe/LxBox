/// §722 (контракт 1.1.165, PARSING_PRINCIPLES §11) — ДИАЛЕКТ хранимого текста
/// источника своего сервера и члена папки: поле записи `origin.kind`.
///
/// Вид определяется движком по реестру ОДИН раз — когда текст приходит
/// снаружи (вставка, импорт, Save на Source, обновление подписки:
/// `services/parser/source_classify.dart`), и хранится. Хранимый текст заново
/// не классифицируется: сборка, вкладки, бэкап ветвятся по этому полю.
///
/// Форма текста (голое тело / документ) в вид не входит — её видит движок за
/// одну проверку.
enum SourceDialect {
  /// sing-box: голое тело `{"type":…}` или документ с `outbounds`/`endpoints`.
  singbox('singbox'),

  /// Xray: outbound `{"protocol":…}` или конфиг с `outbounds`.
  xray('xray'),

  /// Ссылка (строки ссылок) и упакованная ссылка `vpn://`.
  uri('uri'),

  /// WireGuard/AmneziaWG `.conf` (wg-quick).
  wgIni('wg_ini');

  const SourceDialect(this.code);

  /// Значение `origin.kind` записи.
  final String code;

  /// `true` — диалект JSON (sing-box или Xray).
  bool get isJson => this == singbox || this == xray;

  /// Значение `origin.kind` → диалект; `null` — значение не из нового набора
  /// (старое `json`, пусто, чужое): решает миграция вызывающего.
  static SourceDialect? fromCode(Object? code) {
    for (final d in values) {
      if (d.code == code) return d;
    }
    return null;
  }
}
