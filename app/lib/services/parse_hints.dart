/// Эвристики для типичных причин, почему подписка распарсилась в 0 узлов
/// (night T3-3). Пробегаем по raw body и возвращаем короткую подсказку
/// юзеру ("это HTML страница, не подписка", "похоже на Clash YAML").
///
/// Возвращает `null` если эвристики не сработали — caller показывает
/// generic-месседж.
String? diagnoseEmptyParse(String rawBody) {
  if (rawBody.isEmpty) {
    return 'Empty response from server';
  }
  final sample = rawBody.length > 512 ? rawBody.substring(0, 512) : rawBody;
  final lowered = sample.toLowerCase().trimLeft();

  // HTML-страница (провайдер вернул landing/login).
  if (lowered.startsWith('<!doctype html') ||
      lowered.startsWith('<html') ||
      lowered.contains('<body')) {
    return 'Server returned a web page, not subscription data — '
        'URL may be wrong or requires login';
  }

  // Clash YAML (очень частый кейс у провайдеров).
  if (sample.contains('proxies:') ||
      sample.contains('proxy-groups:') ||
      sample.contains('port: 7890')) {
    return 'This looks like Clash YAML — not supported yet. '
        'Ask provider for URI-list subscription URL';
  }

  // JSON конфиг sing-box/V2Ray целиком (не outbound-only).
  final t = sample.trimLeft();
  if ((t.startsWith('{') || t.startsWith('[')) &&
      (sample.contains('"inbounds"') || sample.contains('"routing"'))) {
    return 'Input looks like a full sing-box config — not a subscription. '
        'Use only the outbounds array';
  }

  // Plain-text error from provider.
  if (sample.length < 200 && RegExp(r'[а-яА-Я\w\s]+').hasMatch(sample)) {
    return 'Server returned a plain message (not a subscription): '
        '"${sample.replaceAll("\n", " ").trim()}"';
  }

  return null;
}
