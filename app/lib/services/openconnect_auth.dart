/// §654 C — чистая логика второго фактора и SSO openconnect: какой диалог
/// показать, порт слушателя SSO, счётчик неверных кодов, ответ формой.
/// Паритет с лаунчером (SPEC 167 §2.5, `core/openconnect_sso_callback.go`,
/// `ui/servers_openconnect_auth.go`).
library;

import '../vpn/cc_openconnect.dart';

/// Порт слушателя SSO по умолчанию — как у FortiClient.
const int kOpenConnectDefaultCallbackPort = 8020;

/// После стольких неверных кодов подряд на узле — предупреждение.
const int kOpenConnectWrongCodeWarnAfter = 2;

/// Что показать на челлендж.
enum OpenConnectAuthKind {
  /// Челленджа нет (или он пустой).
  none,

  /// Форма полей (код, пароль, выбор).
  form,

  /// SSO с возвратом на loopback (FortiGate SAML): браузер + слушатель.
  browserCallback,

  /// SSO через cookie/заголовки (AnyConnect и др.) — не поддержано.
  browserUnsupported,
}

/// Хост и порт префикса `http://host:port/…`; порт `null`, если не назван
/// (`http://127.0.0.1:` тоже без порта). `null` — не http-адрес.
({String host, int? port})? _parseHttpPrefix(String raw) {
  final p = raw.trim();
  const scheme = 'http://';
  if (p.length < scheme.length ||
      p.substring(0, scheme.length).toLowerCase() != scheme) {
    return null;
  }
  var rest = p.substring(scheme.length);
  final slash = rest.indexOf('/');
  if (slash >= 0) rest = rest.substring(0, slash);
  String host;
  String portText = '';
  if (rest.startsWith('[')) {
    final end = rest.indexOf(']');
    if (end < 0) return null;
    host = rest.substring(1, end);
    final tail = rest.substring(end + 1);
    if (tail.startsWith(':')) portText = tail.substring(1);
  } else {
    final colon = rest.indexOf(':');
    host = colon < 0 ? rest : rest.substring(0, colon);
    if (colon >= 0) portText = rest.substring(colon + 1);
  }
  if (host.isEmpty) return null;
  final port = int.tryParse(portText);
  return (
    host: host,
    port: port != null && port > 0 && port <= 65535 ? port : null,
  );
}

/// Хост, который браузер приведёт на IPv4-слушатель 127.0.0.1.
bool _loopbackHost(String h) {
  if (h.toLowerCase() == 'localhost') return true;
  final parts = h.split('.');
  if (parts.length != 4) return false;
  final nums = parts.map(int.tryParse).toList();
  if (nums.any((n) => n == null || n < 0 || n > 255)) return false;
  return nums.first == 127;
}

/// Все префиксы ведут на этот телефон по http (и их больше нуля): только
/// тогда callback-режим поддержан.
bool openConnectCallbackLoopbackOnly(List<String> prefixes) {
  if (prefixes.isEmpty) return false;
  for (final p in prefixes) {
    final u = _parseHttpPrefix(p);
    if (u == null || !_loopbackHost(u.host)) return false;
  }
  return true;
}

/// Порт слушателя: из префикса, если шлюз его назвал, иначе 8020. Ключа в
/// теле узла под порт нет: тело уходит в ядро как есть, а незнакомые поля
/// ядро отвергает.
int openConnectCallbackPort(List<String> prefixes) {
  for (final p in prefixes) {
    final port = _parseHttpPrefix(p)?.port;
    if (port != null) return port;
  }
  return kOpenConnectDefaultCallbackPort;
}

/// Какой диалог нужен челленджу.
OpenConnectAuthKind openConnectAuthKind(CcOpenConnectChallenge? c) {
  if (c == null || c.id.isEmpty) return OpenConnectAuthKind.none;
  final b = c.browser;
  if (b != null) {
    return openConnectCallbackLoopbackOnly(b.callbackUrlPrefixes)
        ? OpenConnectAuthKind.browserCallback
        : OpenConnectAuthKind.browserUnsupported;
  }
  if (c.form != null) return OpenConnectAuthKind.form;
  return OpenConnectAuthKind.none;
}

/// Ссылка входа открывается только как http/https с хостом.
bool openConnectWebUrl(String s) {
  final u = Uri.tryParse(s.trim());
  if (u == null || u.host.isEmpty) return false;
  final scheme = u.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}

/// Поле пароля аккаунта (не кода): kind `password` и ключ/имя про пароль.
bool openConnectIsPasswordField(CcOpenConnectField f) {
  if (f.kind.toLowerCase() != 'password') return false;
  return '${f.submissionKey} ${f.name}'.toLowerCase().contains('password');
}

/// Форма просит пароль аккаунта — пароль в узле, вероятно, неверен.
bool openConnectFormAsksPassword(CcOpenConnectChallenge c) =>
    (c.form ?? const <CcOpenConnectField>[]).any(openConnectIsPasswordField);

/// Ответ формой: пары ключ → значение в порядке полей. Значение — введённое
/// человеком ([edits] по ключу поля), иначе то, что прислал шлюз. Поля без
/// ключа пропускаются.
List<MapEntry<String, String>> openConnectFormValues(
  List<CcOpenConnectField> fields,
  Map<String, String> edits,
) => [
  for (final f in fields)
    if (f.key.isNotEmpty) MapEntry(f.key, edits[f.key] ?? f.value),
];

/// Неверные коды подряд по узлу. Неверный код = после нашего Submit формы
/// пришёл новый челлендж-форма с ошибкой шлюза. Форма с паролем аккаунта
/// (неверный пароль) — не код, счёт не растёт. Отмена (новый код по
/// просьбе человека) и вход без ошибки счёт сбрасывают.
class OpenConnectWrongCodeTracker {
  final Map<String, String> _lastSubmitted = {};
  final Map<String, int> _streak = {};

  /// Человек отправил форму челленджа [challengeId].
  void submitted(String tag, String challengeId) =>
      _lastSubmitted[tag] = challengeId;

  /// Человек попросил новый код.
  void cancelled(String tag) {
    _lastSubmitted.remove(tag);
    _streak.remove(tag);
  }

  /// Новый челлендж узла (зовётся один раз на id).
  void challenge(String tag, CcOpenConnectChallenge c) {
    final prev = _lastSubmitted[tag];
    if (prev == null || prev == c.id) return;
    _lastSubmitted.remove(tag);
    if (c.form != null &&
        c.error.isNotEmpty &&
        !openConnectFormAsksPassword(c)) {
      _streak[tag] = (_streak[tag] ?? 0) + 1;
    } else {
      _streak.remove(tag);
    }
  }

  /// Узел подключился — серия закончилась.
  void connected(String tag) {
    _lastSubmitted.remove(tag);
    _streak.remove(tag);
  }

  int streak(String tag) => _streak[tag] ?? 0;

  bool shouldWarn(String tag) => streak(tag) >= kOpenConnectWrongCodeWarnAfter;
}

/// Метка состояния узла openconnect в строке списка.
enum OpenConnectRowKind { none, waiting, error }

/// Метка узла: висит челлендж → «Waiting for sign-in»; `error` → текст
/// ошибки ядра (иначе `stateText`).
({OpenConnectRowKind kind, String text}) openConnectRowState(
  CcOpenConnectStatus? s,
) {
  if (s == null) return (kind: OpenConnectRowKind.none, text: '');
  if (s.state == CcOpenConnectState.authPending ||
      s.pendingChallengeId.isNotEmpty) {
    return (kind: OpenConnectRowKind.waiting, text: '');
  }
  if (s.state == CcOpenConnectState.error) {
    final msg = s.error.trim().isNotEmpty ? s.error.trim() : s.stateText.trim();
    return (kind: OpenConnectRowKind.error, text: msg);
  }
  return (kind: OpenConnectRowKind.none, text: '');
}
