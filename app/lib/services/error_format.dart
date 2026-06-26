import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;

/// §041: Превращает Dart exception в человекочитаемое сообщение для UI banner /
/// snackbar / debug log. Скрывает технические артефакты toString'ов
/// ("Future not completed", "errno = N", длинные address-кортежи и т.п.).
///
/// Не делает локализацию — это формат, не i18n. Если потребуется i18n —
/// отдельный layer поверх с lookup в `.arb` по типу exception'а.
///
/// Примеры:
///
///   TimeoutException(Duration(seconds:10))         → "timeout 10s"
///   SocketException("Connection refused", ...)     → "Connection refused"
///   FileSystemException("Cannot open", ...)        → "No such file or directory"
///   PlatformException(start_failed, "msg", ...)    → "msg"
///   FormatException("Unexpected character", ...)   → "Unexpected character"
String formatUserError(Object e) {
  if (e is TimeoutException) {
    final ms = e.duration?.inMilliseconds ?? 0;
    final s = (ms / 1000).toStringAsFixed(ms % 1000 == 0 ? 0 : 1);
    return 'timeout ${s}s';
  }
  if (e is FileSystemException) {
    final osMsg = e.osError?.message;
    if (osMsg != null && osMsg.isNotEmpty) return osMsg;
    return e.message;
  }
  if (e is SocketException) {
    final osMsg = e.osError?.message;
    if (osMsg != null && osMsg.isNotEmpty) return osMsg;
    return e.message;
  }
  if (e is HttpException) return e.message;
  if (e is FormatException) return e.message;
  if (e is PlatformException) {
    final m = e.message;
    if (m != null && m.isNotEmpty) return m;
    return 'platform error: ${e.code}';
  }
  // Fallback — strip "Exception: " prefix, truncate.
  var s = e.toString();
  if (s.startsWith('Exception: ')) s = s.substring('Exception: '.length);
  return s.length > 120 ? '${s.substring(0, 117)}…' : s;
}
