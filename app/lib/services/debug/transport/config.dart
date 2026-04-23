/// Конфигурация [DebugServer]'а. Immutable — рестарт под новые значения
/// (port/token) идёт через `start(newConfig, ctx)`.
class DebugServerConfig {
  const DebugServerConfig({
    required this.port,
    required this.token,
    this.requestTimeout = const Duration(seconds: 30),
    this.maxBodyBytes = 1024 * 1024,
    this.unauthenticatedPaths = const {'/ping', '/help'},
  });

  /// TCP-порт. Bind строго на `127.0.0.1`.
  final int port;

  /// Bearer-токен. Пустая строка → сервер не стартует.
  final String token;

  /// Максимальное время выполнения handler'а до `504 timeout`.
  final Duration requestTimeout;

  /// Максимальный размер тела запроса. Больше → `413 payload_too_large`.
  /// Default 1 MiB — `PUT /config` может принимать многокилобайтные
  /// sing-box JSON'ы (70–300 KB реально), мелкие CRUD body'ы (rules/subs/
  /// settings) всё равно <4 KB. Auth + host check отсекают злоупотребления.
  final int maxBodyBytes;

  /// Paths, которые пропускаются без `Authorization` header. Host check
  /// и всё остальное всё равно проверяется.
  final Set<String> unauthenticatedPaths;
}
