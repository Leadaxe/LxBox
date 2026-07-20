import 'dart:async';
import 'dart:io';

import '../models/ui_msg.dart';
import '../models/validation.dart';

/// Превращает технический exception в user-facing сообщение (night T2-2).
///
/// §219 — НЕ путать с `formatUserError` (error_format.dart): «detailed»
/// разбор по типу для сетевых операций подписок. `formatUserError` — «quick»
/// generic-очистка для VPN-старта. Выбирай по домену, не конкурируют.
///
/// §279 — возвращает [UiMsg]: собственные фразы рендерятся по локали в момент
/// показа, payload (`.message` исключений, kernel-строки) — passthrough в
/// [RawMsg].
///
/// Поведение (английский рендер):
/// - `SocketException` / network errors → `No connection to <host>` если host
///   удаётся извлечь, иначе generic "No connection"
/// - `TimeoutException` → "Timed out after Ns" если `.duration` известен,
///   иначе generic "Request timed out"
/// - `HttpException` с `HTTP NNN` → короткое описание по коду
/// - `FormatException` → "Can't parse response (invalid format)"
/// - [FatalValidationException] → [ValidationFatalMsg] (§141 P0.1 — полный
///   перечень fatal-issues, рендер в момент показа)
/// - Всё остальное — оригинальное `.toString()` с префиксом отрезанным
///   (удаляем "Exception: " чтобы не показывать юзеру).
UiMsg humanizeError(Object e) {
  if (e is FatalValidationException) {
    return ValidationFatalMsg(e.issues);
  }
  if (e is SocketException) {
    final host = _extractSocketHost(e);
    return host.isNotEmpty
        ? NoConnectionToHost(host)
        : const ErrMsg(ErrKey.noConnection);
  }
  if (e is TimeoutException) {
    final secs = e.duration?.inSeconds ?? 0;
    if (secs > 0) return TimedOutAfter(secs);
    return const ErrMsg(ErrKey.requestTimedOut);
  }
  if (e is HttpException) {
    final msg = e.message;
    final m = RegExp(r'HTTP (\d{3})').firstMatch(msg);
    if (m != null) {
      return HttpStatusMsg(int.parse(m.group(1)!));
    }
    return RawMsg(msg);
  }
  if (e is FormatException) {
    return const ErrMsg(ErrKey.cantParseResponse);
  }
  if (e is FileSystemException) {
    return PrefixedMsg(ErrPrefix.fileError, RawMsg(e.message));
  }
  final raw = e.toString();
  // Trim leading "Exception: " / "TypeError: " / etc — keep message only.
  final trimmed = raw.replaceFirst(RegExp(r'^[A-Za-z_]*(Exception|Error): '), '');
  return RawMsg(
      trimmed.length > 140 ? '${trimmed.substring(0, 137)}...' : trimmed);
}

/// Пытается достать host из `SocketException`. `e.address` обычно `null` при
/// DNS-lookup failure, поэтому сначала смотрим в `e.message` ("Failed host
/// lookup: 'api.example.com'", "No address associated with hostname") и лишь
/// затем — в `e.osError?.message`. Возвращает пустую строку, если host не
/// удалось идентифицировать.
String _extractSocketHost(SocketException e) {
  final addrHost = e.address?.host ?? '';
  if (addrHost.isNotEmpty) return addrHost;

  // Формат "Failed host lookup: 'host.name'" на Android/Linux.
  final m = RegExp(r"host lookup:\s*'([^']+)'", caseSensitive: false)
      .firstMatch(e.message);
  if (m != null) {
    final host = m.group(1)?.trim() ?? '';
    if (host.isNotEmpty) return host;
  }
  return '';
}
