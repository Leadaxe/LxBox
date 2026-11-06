/// §643 (контракт 1.1.119, TEMPLATE_LANG §6.9) — ссылка на DNS-сервер в
/// `route.default_domain_resolver` (и `domain_resolver` исходящих): строка-тег
/// или объектная форма ядра `DomainResolveOptions` (`{server, …}`).
///
/// Читатель понимает обе формы; кто подменяет резолвер, меняет только
/// `server` — прочие поля объекта (`disable_optimistic_cache`, …) остаются.
library;

/// Тег сервера из значения [value]: строка как есть, у объекта — `server`
/// (строкой). Иная форма — null.
String? domainResolverServer(Object? value) => switch (value) {
      String s => s,
      Map m when m['server'] is String => m['server'] as String,
      _ => null,
    };

/// Значение [value] с сервером [server]: строка заменяется строкой, у объекта
/// меняется только `server`, остальные поля сохраняются.
Object withDomainResolverServer(Object? value, String server) =>
    value is Map
        ? <String, dynamic>{...value.cast<String, dynamic>(), 'server': server}
        : server;
