/// §576 п.5 — вход `singbox` при разборе принадлежит только АВТОРСКОМУ телу:
/// свой сервер или член папки с видом источника `singbox_outbound`
/// (PARSING_PRINCIPLES §10–§11). Узел подписки с тем же JSON — вход `other`:
/// исключения реестра по входу (`except_sources`) на него не действуют ни при
/// разборе, ни на сборке.
///
/// Контейнер разбору не виден: `parseAll` получает текст, а не запись. Его
/// называет вызывающий (`parseAll(own: true)`), и признак живёт ровно на
/// время синхронного разбора — проходы санитайзера внутри (`_sanitizedEntry`,
/// `annotateFromRawBody`, `bodySourceOf`) читают его отсюда, не протаскивая
/// параметр через каждый парсер.
library;

import '../contract/body_sanitizer.dart' show BodySource;

bool _authored = false;

/// Идёт разбор авторского тела (см. [withAuthoredBody]).
bool get parsingAuthoredBody => _authored;

/// Вход тела sing-box-формы в текущем разборе.
BodySource get singboxBodySource =>
    _authored ? BodySource.singbox : BodySource.other;

/// Выполнить синхронный разбор [body] с признаком авторского тела [on].
/// Вложенный вызов признак восстанавливает.
T withAuthoredBody<T>(bool on, T Function() body) {
  final prev = _authored;
  _authored = on;
  try {
    return body();
  } finally {
    _authored = prev;
  }
}
