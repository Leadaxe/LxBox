/// §392 — предопределённый диагностический чекер: адрес, по которому уходит GET
/// через проверяемый узел.
///
/// Тело ответа приложение НЕ интерпретирует (kernel SPEC 058 §5 отдаёт парсинг
/// клиенту, а мы сознательно не парсим вовсе): пользователь читает сырой ответ.
/// Поэтому в модели нет ни парсера, ни схемы полей — только адрес и подпись.
///
/// Ввода произвольного URL нет намеренно: поле ввода превратило бы диагностику
/// в HTTP-клиент общего назначения через чужие туннели.
class DiagnosticCheck {
  const DiagnosticCheck({
    required this.id,
    required this.title,
    required this.url,
  });

  /// Стабильный ключ (для запоминания выбора; в UI не показывается).
  final String id;

  /// Подпись в выпадающем списке. Английский текст = ключ перевода (§285).
  final String title;

  final String url;
}

/// Список чекеров в порядке показа. Первый — дефолт при открытии вкладки.
///
/// `cdn-cgi/trace` идёт первым: без ключа, читаемые `key=value` построчно,
/// и это единственный источник строки `warp=` (включён ли WARP на самом деле).
/// Вариант по имени хоста стоит рядом с вариантом по IP намеренно — расхождение
/// между ними само по себе диагностично (резолв домена против прямого адреса).
///
/// `ip2location.io` без API-ключа отдаёт урезанный ответ и жёстко лимитирован
/// по числу запросов; его 429 — обычный результат со статусом, а не признак
/// нерабочего узла (см. [CcGetUrlResult]).
const List<DiagnosticCheck> kDiagnosticChecks = [
  DiagnosticCheck(
    id: 'cf_trace',
    title: 'Cloudflare trace',
    url: 'https://1.1.1.1/cdn-cgi/trace',
  ),
  DiagnosticCheck(
    id: 'cf_trace_host',
    title: 'Cloudflare trace (hostname)',
    url: 'https://cloudflare.com/cdn-cgi/trace',
  ),
  DiagnosticCheck(
    id: 'ip2location',
    title: 'IP & location',
    url: 'https://api.ip2location.io/',
  ),
  DiagnosticCheck(
    id: 'ipinfo',
    title: 'IP info',
    url: 'https://ipinfo.io/json',
  ),
];
