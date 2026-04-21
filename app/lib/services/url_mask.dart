/// Маскирует URL подписки до `scheme://host/***`.
///
/// Провайдер-credentials обычно живут в path/token части URL
/// (`https://provider/sub/<secret>`), поэтому при выдаче в логи / debug
/// API / шеринг по умолчанию светим только host. Если нужен полный URL
/// (reveal=true в debug API) — caller сам решит.
///
/// Централизовано здесь (night T2-3), чтобы controllers не тянули
/// `debug/serializers/` только ради одной функции.
String maskSubscriptionUrl(String raw) {
  if (raw.isEmpty) return '';
  final u = Uri.tryParse(raw);
  if (u == null) return '***';
  if (u.host.isEmpty) return '***';
  return '${u.scheme}://${u.host}/***';
}
