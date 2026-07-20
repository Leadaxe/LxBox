import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;

import '../models/ui_msg.dart';

/// §041: Превращает Dart exception в человекочитаемое сообщение для UI banner /
/// snackbar / debug log. Скрывает технические артефакты toString'ов
/// ("Future not completed", "errno = N", длинные address-кортежи и т.п.).
///
/// §219 — НЕ путать с [humanizeError] (error_humanize.dart): это два разных
/// форматтера с разными зонами. `formatUserError` — «quick»/generic очистка
/// toString (VPN-старт/стоп в home_controller). `humanizeError` — «detailed»
/// разбор по типу (SocketException→"No connection to `<host>`", HTTP-коды) для
/// сетевых операций подписок (subscription_controller). НЕ конкурируют —
/// выбирай по домену.
///
/// §279 — возвращает [UiMsg]: собственные фразы форматтера рендерятся по
/// локали в момент показа (`render(l)`), payload исключений (osError.message,
/// kernel-строки) — passthrough в [RawMsg], не переводится.
///
/// Примеры (английский рендер):
///
///   TimeoutException(Duration(seconds:10))         → "timeout 10s"
///   SocketException("Connection refused", ...)     → "Connection refused"
///   FileSystemException("Cannot open", ...)        → "No such file or directory"
///   PlatformException(start_failed, "msg", ...)    → "msg"
///   FormatException("Unexpected character", ...)   → "Unexpected character"
UiMsg formatUserError(Object e) {
  if (e is TimeoutException) {
    return TimeoutError(e.duration?.inMilliseconds ?? 0);
  }
  if (e is FileSystemException) {
    final osMsg = e.osError?.message;
    if (osMsg != null && osMsg.isNotEmpty) return RawMsg(osMsg);
    return RawMsg(e.message);
  }
  if (e is SocketException) {
    final osMsg = e.osError?.message;
    if (osMsg != null && osMsg.isNotEmpty) return RawMsg(osMsg);
    return RawMsg(e.message);
  }
  if (e is HttpException) return RawMsg(e.message);
  if (e is FormatException) return RawMsg(e.message);
  if (e is PlatformException) {
    final m = e.message;
    if (m != null && m.isNotEmpty) return RawMsg(m);
    return PrefixedMsg(ErrPrefix.platformError, RawMsg(e.code));
  }
  // Fallback — strip "Exception: " prefix, truncate.
  var s = e.toString();
  if (s.startsWith('Exception: ')) s = s.substring('Exception: '.length);
  return RawMsg(s.length > 120 ? '${s.substring(0, 117)}…' : s);
}
