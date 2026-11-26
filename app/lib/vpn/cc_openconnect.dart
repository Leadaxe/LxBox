/// §654 C — модели потока ядра `SubscribeOpenConnectStatus` (канал
/// `lxbox/cc/openconnect`, `BoxCommandClient.kt`): состояние endpoint'ов
/// openconnect, висящий челлендж второго фактора или SSO, слушатель SSO.
///
/// Тексты шлюза, значения полей формы и ссылки входа — данные пользователя:
/// в журнал, дамп поддержки и Debug API не попадают.
library;

Map<String, dynamic> _map(Object? e) =>
    e is Map ? e.map((k, v) => MapEntry('$k', v)) : const <String, dynamic>{};

List<Object?> _list(Object? e) => e is List ? e : const <Object?>[];

List<String> _strings(Object? e) => [for (final s in _list(e)) '$s'];

/// Состояния endpoint'а словами ядра (строки, enum нет).
abstract final class CcOpenConnectState {
  static const connecting = 'connecting';
  static const authPending = 'auth-pending';
  static const connected = 'connected';
  static const error = 'error';
}

/// Вариант поля-выбора формы.
class CcOpenConnectChoice {
  const CcOpenConnectChoice({required this.value, required this.label});
  final String value;
  final String label;
}

/// Поле формы второго фактора как его отдал шлюз.
class CcOpenConnectField {
  const CcOpenConnectField({
    this.submissionKey = '',
    this.name = '',
    this.label = '',
    this.kind = '',
    this.value = '',
    this.options = const [],
  });

  final String submissionKey;
  final String name;
  final String label;

  /// `text` / `password` / `select` (и прочее, что пришлёт шлюз).
  final String kind;
  final String value;
  final List<CcOpenConnectChoice> options;

  /// Ключ значения в ответе: `submissionKey`, иначе `name`.
  String get key => submissionKey.isNotEmpty ? submissionKey : name;

  factory CcOpenConnectField.fromMap(Map<String, dynamic> m) =>
      CcOpenConnectField(
        submissionKey: '${m['submission_key'] ?? ''}',
        name: '${m['name'] ?? ''}',
        label: '${m['label'] ?? ''}',
        kind: '${m['kind'] ?? ''}',
        value: '${m['value'] ?? ''}',
        options: [
          for (final o in _list(m['options']))
            if (o is Map)
              CcOpenConnectChoice(
                value: '${_map(o)['value'] ?? ''}',
                label: '${_map(o)['label'] ?? ''}',
              ),
        ],
      );
}

/// Запрос входа через браузер (SSO).
class CcOpenConnectBrowser {
  const CcOpenConnectBrowser({
    this.url = '',
    this.callbackUrlPrefixes = const [],
    this.cookieNames = const [],
    this.headerNames = const [],
  });

  final String url;
  final List<String> callbackUrlPrefixes;
  final List<String> cookieNames;
  final List<String> headerNames;

  factory CcOpenConnectBrowser.fromMap(Map<String, dynamic> m) =>
      CcOpenConnectBrowser(
        url: '${m['url'] ?? ''}',
        callbackUrlPrefixes: _strings(m['callback_url_prefixes']),
        cookieNames: _strings(m['cookie_names']),
        headerNames: _strings(m['header_names']),
      );
}

/// Висящий челлендж ядра: форма ([form] не `null`) или браузер.
class CcOpenConnectChallenge {
  const CcOpenConnectChallenge({
    required this.id,
    this.banner = '',
    this.message = '',
    this.error = '',
    this.form,
    this.browser,
  });

  final String id;
  final String banner;
  final String message;
  final String error;

  /// Поля формы; `null` — челлендж не формой.
  final List<CcOpenConnectField>? form;
  final CcOpenConnectBrowser? browser;

  factory CcOpenConnectChallenge.fromMap(Map<String, dynamic> m) {
    final form = m['form'];
    final browser = m['browser'];
    return CcOpenConnectChallenge(
      id: '${m['id'] ?? ''}',
      banner: '${m['banner'] ?? ''}',
      message: '${m['message'] ?? ''}',
      error: '${m['error'] ?? ''}',
      form: form is List
          ? [
              for (final f in form)
                if (f is Map) CcOpenConnectField.fromMap(_map(f)),
            ]
          : null,
      browser: browser is Map
          ? CcOpenConnectBrowser.fromMap(_map(browser))
          : null,
    );
  }
}

/// Туннель endpoint'а (карта `tunnel`): что выдал шлюз. Адреса, DNS и
/// шлюз — данные пользователя (см. шапку файла).
class CcOpenConnectTunnel {
  const CcOpenConnectTunnel({
    this.server = '',
    this.flavor = '',
    this.transport = '',
    this.mtu = 0,
    this.connectedSince = 0,
    this.ipv4 = const [],
    this.ipv6 = const [],
    this.dns = const [],
  });

  /// Поле `server` узла как записано (хост, хост:порт или URL).
  final String server;
  final String flavor;
  final String transport;
  final int mtu;

  /// Секунды Unix; `0` — время не задано.
  final int connectedSince;

  /// Префиксы (`10.0.0.5/32`); у карты без списков (натив до §764) — пусто.
  final List<String> ipv4;
  final List<String> ipv6;
  final List<String> dns;

  static int _int(Object? v) => v is num ? v.toInt() : 0;

  factory CcOpenConnectTunnel.fromMap(Map<String, dynamic> m) =>
      CcOpenConnectTunnel(
        server: '${m['server'] ?? ''}',
        flavor: '${m['flavor'] ?? ''}',
        transport: '${m['transport'] ?? ''}',
        mtu: _int(m['mtu']),
        connectedSince: _int(m['connected_since']),
        ipv4: _strings(m['ipv4']),
        ipv6: _strings(m['ipv6']),
        dns: _strings(m['dns']),
      );
}

/// Состояние одного endpoint'а openconnect.
class CcOpenConnectStatus {
  const CcOpenConnectStatus({
    required this.tag,
    this.state = '',
    this.stateText = '',
    this.error = '',
    this.challenge,
    this.tunnel,
  });

  final String tag;
  final String state;
  final String stateText;
  final String error;

  /// Висящий челлендж; `null` — нет (пустой id тоже считается «нет»).
  final CcOpenConnectChallenge? challenge;

  /// §764 — туннель (карта `tunnel`); `null` — ключа нет.
  final CcOpenConnectTunnel? tunnel;

  /// id висящего челленджа; пусто — нет.
  String get pendingChallengeId => challenge?.id ?? '';

  factory CcOpenConnectStatus.fromMap(Map<String, dynamic> m) {
    final ch = m['challenge'];
    final t = m['tunnel'];
    final challenge = ch is Map
        ? CcOpenConnectChallenge.fromMap(_map(ch))
        : null;
    return CcOpenConnectStatus(
      tag: '${m['tag'] ?? ''}',
      state: '${m['state'] ?? ''}',
      stateText: '${m['state_text'] ?? ''}',
      error: '${m['error'] ?? ''}',
      challenge: challenge != null && challenge.id.isNotEmpty
          ? challenge
          : null,
      tunnel: t is Map ? CcOpenConnectTunnel.fromMap(_map(t)) : null,
    );
  }
}

/// Состояние нативного слушателя SSO (callback-режим).
class CcOpenConnectCallback {
  const CcOpenConnectCallback({
    required this.tag,
    required this.challengeId,
    required this.state,
    this.error = '',
  });

  final String tag;
  final String challengeId;

  /// `listening` / `submitting` / `submitted` / `failed`.
  final String state;
  final String error;

  factory CcOpenConnectCallback.fromMap(Map<String, dynamic> m) =>
      CcOpenConnectCallback(
        tag: '${m['tag'] ?? ''}',
        challengeId: '${m['challenge_id'] ?? ''}',
        state: '${m['state'] ?? ''}',
        error: '${m['error'] ?? ''}',
      );
}

/// Снапшот канала: endpoint'ы по тегу и слушатель SSO.
class CcOpenConnectSnapshot {
  const CcOpenConnectSnapshot({this.endpoints = const {}, this.callback});

  static const empty = CcOpenConnectSnapshot();

  final Map<String, CcOpenConnectStatus> endpoints;
  final CcOpenConnectCallback? callback;

  factory CcOpenConnectSnapshot.fromObject(Object? e) {
    final m = _map(e);
    final cb = m['callback'];
    return CcOpenConnectSnapshot(
      endpoints: {
        for (final x in _list(m['endpoints']))
          if (x is Map)
            for (final s in [CcOpenConnectStatus.fromMap(_map(x))])
              if (s.tag.isNotEmpty) s.tag: s,
      },
      callback: cb is Map ? CcOpenConnectCallback.fromMap(_map(cb)) : null,
    );
  }
}
