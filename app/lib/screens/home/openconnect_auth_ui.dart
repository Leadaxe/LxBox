import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/home_controller.dart';
import '../../services/l10n/locale_controller.dart';
import '../../services/openconnect_auth.dart';
import '../../services/url_launcher.dart';
import '../../vpn/cc_channel.dart';

/// §654 C — второй фактор и SSO openconnect на главном экране: диалог при
/// новом `challenge.id`, повторный показ по тапу на уведомление «Sign-in
/// required» или на метку узла. Паритет с лаунчером (SPEC 167 §2.5).
///
/// Диалог сам появляется один раз на id, и только когда приложение на
/// экране; висящий челлендж, пришедший в фоне, показывается при возврате.
class OpenConnectAuthPresenter {
  OpenConnectAuthPresenter(this.controller);

  final HomeController controller;
  final OpenConnectWrongCodeTracker tracker = OpenConnectWrongCodeTracker();

  /// `tag|id` челленджей, учтённых счётчиком неверных кодов.
  final Set<String> _seen = {};

  /// `tag|id` челленджей, диалог которых уже показывался сам.
  final Set<String> _shown = {};

  /// Тег узла открытого диалога; `null` — диалога нет.
  String? _openTag;

  /// Смена состояния контроллера. [foreground] — приложение на экране.
  void onState(BuildContext context, {required bool foreground}) {
    final endpoints = controller.state.openConnect.endpoints;
    for (final s in endpoints.values) {
      if (s.state == CcOpenConnectState.connected) tracker.connected(s.tag);
      final c = s.challenge;
      if (c == null) continue;
      final key = '${s.tag}|${c.id}';
      if (_seen.add(key)) tracker.challenge(s.tag, c);
    }
    if (!foreground || _openTag != null) return;
    for (final s in endpoints.values) {
      final c = s.challenge;
      if (c == null) continue;
      final key = '${s.tag}|${c.id}';
      if (_shown.contains(key)) continue;
      _shown.add(key);
      // Не из notifyListeners посреди кадра: маршрут — следующей задачей.
      scheduleMicrotask(() {
        if (context.mounted) unawaited(open(context, s.tag));
      });
      return;
    }
  }

  /// Тап по уведомлению: забрать тег у натива и открыть его диалог.
  Future<void> handleOpenRequest(BuildContext context) async {
    final tag = await CcChannel.instance.takeOpenConnectOpenRequest();
    if (tag == null || tag.isEmpty || !context.mounted) return;
    await controller.refreshOpenConnect();
    if (!context.mounted) return;
    await open(context, tag);
  }

  /// Показать диалог висящего челленджа узла [tag]; челленджа нет — no-op.
  Future<void> open(BuildContext context, String tag) async {
    if (_openTag != null) return;
    final s = controller.state.openConnect.endpoints[tag];
    final c = s?.challenge;
    if (c == null) return;
    _shown.add('$tag|${c.id}');
    _openTag = tag;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => OpenConnectChallengeDialog(
          controller: controller,
          tracker: tracker,
          tag: tag,
          challengeId: c.id,
        ),
      );
    } finally {
      _openTag = null;
    }
    // Пока диалог был открыт, мог прийти челлендж другого узла.
    if (context.mounted) onState(context, foreground: true);
  }
}

/// §654 C — диалог одного челленджа: форма, вход через браузер или «не
/// поддержано». Закрывается сам, когда челлендж исчез или сменился.
class OpenConnectChallengeDialog extends StatefulWidget {
  const OpenConnectChallengeDialog({
    super.key,
    required this.controller,
    required this.tracker,
    required this.tag,
    required this.challengeId,
  });

  final HomeController controller;
  final OpenConnectWrongCodeTracker tracker;
  final String tag;
  final String challengeId;

  @override
  State<OpenConnectChallengeDialog> createState() =>
      _OpenConnectChallengeDialogState();
}

class _OpenConnectChallengeDialogState
    extends State<OpenConnectChallengeDialog> {
  final Map<String, TextEditingController> _text = {};
  final Map<String, String> _select = {};
  final Set<String> _revealed = {};
  bool _busy = false;
  String _error = '';
  bool _closing = false;
  bool _listening = false;

  CcChannel get _cc => CcChannel.instance;

  CcOpenConnectChallenge? get _challenge {
    final c =
        widget.controller.state.openConnect.endpoints[widget.tag]?.challenge;
    return c != null && c.id == widget.challengeId ? c : null;
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    final c = _challenge;
    for (final f in c?.form ?? const <CcOpenConnectField>[]) {
      if (f.key.isEmpty) continue;
      if (f.kind.toLowerCase() == 'select') {
        _select[f.key] = f.value.isNotEmpty || f.options.isEmpty
            ? f.value
            : f.options.first.value;
      } else {
        _text[f.key] = TextEditingController(text: f.value);
      }
    }
    if (openConnectAuthKind(c) == OpenConnectAuthKind.browserCallback) {
      unawaited(_startListener(c!));
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    for (final t in _text.values) {
      t.dispose();
    }
    if (_listening) unawaited(_cc.stopOpenConnectCallback());
    super.dispose();
  }

  void _onChange() {
    if (_challenge == null) {
      _close();
    } else if (mounted) {
      setState(() {});
    }
  }

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    // Поверх может висеть подтверждение «Request a new code»: снимаем
    // именно свой маршрут, а не верхний.
    final nav = Navigator.of(context);
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      nav.removeRoute(route);
    } else {
      nav.pop();
    }
  }

  Future<void> _startListener(CcOpenConnectChallenge c) async {
    final prefixes = c.browser!.callbackUrlPrefixes;
    final port = openConnectCallbackPort(prefixes);
    final err = await _cc.startOpenConnectCallback(
      widget.tag,
      c.id,
      port,
      prefixes,
    );
    if (!mounted) return;
    setState(() {
      _listening = err == null;
      _error = err == null
          ? ''
          : getLocalText.s(
              "Cannot listen on 127.0.0.1:%s: the port is busy or blocked. Close the app that uses it and try again.",
              port,
            );
    });
  }

  Future<void> _submit(CcOpenConnectChallenge c) async {
    final edits = <String, String>{
      for (final e in _text.entries) e.key: e.value.text,
      ..._select,
    };
    final values = openConnectFormValues(c.form ?? const [], edits);
    setState(() {
      _busy = true;
      _error = '';
    });
    final err = await _cc.submitOpenConnectForm(widget.tag, c.id, values);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    widget.tracker.submitted(widget.tag, c.id);
    _close();
  }

  Future<void> _requestNewCode(CcOpenConnectChallenge c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Request a new code")),
        content: Text(getLocalText.s("The gateway will send a new code")),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(getLocalText.s("Request")),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    final err = await _cc.cancelOpenConnectChallenge(widget.tag, c.id);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    widget.tracker.cancelled(widget.tag);
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final c = _challenge;
    if (c == null) return const SizedBox.shrink();
    final title = getLocalText.s("Sign in: %s", widget.tag);
    switch (openConnectAuthKind(c)) {
      case OpenConnectAuthKind.form:
        return _buildForm(context, c, title);
      case OpenConnectAuthKind.browserCallback:
        return _buildBrowser(context, c, title);
      case OpenConnectAuthKind.browserUnsupported:
      case OpenConnectAuthKind.none:
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ..._header(context, c),
                Text(
                  getLocalText.s(
                    "SSO for this gateway type is not supported yet",
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: _close, child: Text(getLocalText.s("Close"))),
          ],
        );
    }
  }

  /// banner / message / error шлюза — как прислал шлюз.
  List<Widget> _header(BuildContext context, CcOpenConnectChallenge c) {
    final cs = Theme.of(context).colorScheme;
    return [
      for (final t in [c.banner, c.message])
        if (t.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(t.trim()), // l10n-exempt: gateway text as is
          ),
      if (c.error.trim().isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            c.error.trim(), // l10n-exempt: gateway text as is
            style: TextStyle(color: cs.error),
          ),
        ),
    ];
  }

  Widget _note(BuildContext context, String text, {bool error = false}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          color: error ? cs.error : Colors.orange.shade800,
        ),
      ),
    );
  }

  Widget _buildForm(
    BuildContext context,
    CcOpenConnectChallenge c,
    String title,
  ) {
    final fields = c.form ?? const <CcOpenConnectField>[];
    return AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ..._header(context, c),
            if (widget.tracker.shouldWarn(widget.tag))
              _note(
                context,
                getLocalText.s(
                  "Each wrong code triggers a new sign-in on the gateway",
                ),
              ),
            if (openConnectFormAsksPassword(c))
              _note(
                context,
                getLocalText.s(
                  "The gateway asks for the password again: the password saved in the server settings is probably wrong.",
                ),
              ),
            for (final f in fields)
              if (f.key.isNotEmpty) _field(f),
            if (_error.isNotEmpty) _note(context, _error, error: true),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _close,
          child: Text(getLocalText.s("Not now")),
        ),
        TextButton(
          onPressed: _busy ? null : () => unawaited(_requestNewCode(c)),
          child: Text(getLocalText.s("Request a new code")),
        ),
        FilledButton(
          onPressed: _busy ? null : () => unawaited(_submit(c)),
          child: Text(getLocalText.s("Submit")),
        ),
      ],
    );
  }

  Widget _field(CcOpenConnectField f) {
    final label = f.label.isNotEmpty ? f.label : f.name;
    final kind = f.kind.toLowerCase();
    if (kind == 'select') {
      final current = _select[f.key] ?? '';
      final hasCurrent = f.options.any((o) => o.value == current);
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: DropdownButtonFormField<String>(
          initialValue: hasCurrent ? current : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [
            for (final o in f.options)
              DropdownMenuItem(
                value: o.value,
                child: Text(o.label.isNotEmpty ? o.label : o.value),
              ),
          ],
          onChanged: _busy
              ? null
              : (v) => setState(() => _select[f.key] = v ?? ''),
        ),
      );
    }
    final password = kind == 'password';
    final shown = _revealed.contains(f.key);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: _text[f.key],
        enabled: !_busy,
        obscureText: password && !shown,
        autocorrect: false,
        enableSuggestions: !password,
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: password
              ? IconButton(
                  icon: Icon(shown ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(
                    () =>
                        shown ? _revealed.remove(f.key) : _revealed.add(f.key),
                  ),
                )
              : null,
        ),
      ),
    );
  }

  Widget _buildBrowser(
    BuildContext context,
    CcOpenConnectChallenge c,
    String title,
  ) {
    final url = c.browser!.url;
    final safe = openConnectWebUrl(url);
    final cb = widget.controller.state.openConnect.callback;
    final mine = cb != null && cb.tag == widget.tag && cb.challengeId == c.id
        ? cb
        : null;
    final String status;
    if (mine?.state == 'failed') {
      status = mine!.error;
    } else if (mine?.state == 'submitting' || mine?.state == 'submitted') {
      status = getLocalText.s("Signing in…");
    } else {
      status = getLocalText.s("Waiting for the browser to come back…");
    }
    final failed = mine?.state == 'failed';
    return AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ..._header(context, c),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(getLocalText.s("Sign in in your browser")),
            ),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    url, // l10n-exempt: sign-in link as is
                    maxLines: 3,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                IconButton(
                  tooltip: getLocalText.s("Copy"),
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => Clipboard.setData(ClipboardData(text: url)),
                ),
              ],
            ),
            if (!safe)
              _note(
                context,
                getLocalText.s(
                  "The sign-in link is not a web address, so it is not opened automatically.",
                ),
              ),
            if (_error.isNotEmpty)
              _note(context, _error, error: true)
            else if (_listening)
              _note(context, status, error: failed),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _close, child: Text(getLocalText.s("Not now"))),
        FilledButton(
          onPressed: safe && _listening
              ? () => unawaited(UrlLauncher.open(url))
              : null,
          child: Text(getLocalText.s("Open")),
        ),
      ],
    );
  }
}
