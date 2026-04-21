import 'dart:async';
import 'dart:io';

/// Превращает технический exception в user-facing сообщение (night T2-2).
///
/// Поведение:
/// - `SocketException` / network errors → "No connection to server"
/// - `TimeoutException` → "Timed out after ... seconds"
/// - `HttpException` с `HTTP NNN` → короткое описание по коду
/// - `FormatException` → "Can't parse response (invalid format)"
/// - Всё остальное — оригинальное `.toString()` с префиксом отрезанным
///   (удаляем "Exception: " чтобы не показывать юзеру).
///
/// Возвращает строку ≤120 chars, подходящую для Snackbar / inline-error.
String humanizeError(Object e) {
  if (e is SocketException) {
    final host = e.address?.host ?? '';
    return host.isNotEmpty
        ? 'No connection to $host — check network or URL'
        : 'No connection — check network or URL';
  }
  if (e is TimeoutException) {
    return 'Request timed out — server slow or unreachable';
  }
  if (e is HttpException) {
    final msg = e.message;
    final m = RegExp(r'HTTP (\d{3})').firstMatch(msg);
    if (m != null) {
      final code = int.parse(m.group(1)!);
      return _httpStatusReason(code);
    }
    return msg;
  }
  if (e is FormatException) {
    return 'Can\'t parse response (invalid format)';
  }
  if (e is FileSystemException) {
    return 'File error: ${e.message}';
  }
  final raw = e.toString();
  // Trim leading "Exception: " / "TypeError: " / etc — keep message only.
  final trimmed = raw.replaceFirst(RegExp(r'^[A-Za-z_]*(Exception|Error): '), '');
  return trimmed.length > 140 ? '${trimmed.substring(0, 137)}...' : trimmed;
}

String _httpStatusReason(int code) {
  if (code == 401 || code == 403) {
    return 'Access denied ($code) — check subscription token';
  }
  if (code == 404) return 'Not found (404) — subscription URL may be removed';
  if (code == 410) return 'Gone (410) — subscription deleted by provider';
  if (code == 429) return 'Rate limited (429) — try again later';
  if (code >= 500 && code < 600) {
    return 'Server error ($code) — provider is down, try later';
  }
  if (code >= 400 && code < 500) return 'Request rejected ($code)';
  return 'HTTP $code';
}
