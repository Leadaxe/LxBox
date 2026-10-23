// §622 — экран приёма настроек на TV (фича 031, функция «Сессия приёма»).
//
// Пока экран открыт, слушает одна сессия [TransferReceiver]; уход с экрана
// её закрывает (P1). Принятый бэкап экран возвращает через `Navigator.pop`,
// восстановление делает вызывающий общим `restoreFromContents` (P4).
// Управление — D-pad: автофокус на «Cancel», обе кнопки в порядке фокуса,
// экран не гаснет (P8).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import '../services/app_log.dart';
import '../services/backup_service.dart';
import '../services/error_format.dart';
import '../services/l10n/locale_controller.dart';
import '../services/subscription/subscription_identity.dart';
import '../services/transfer/transfer_receiver.dart';
import '../services/url_launcher.dart';
import '../widgets/safe_bottom.dart';

/// Открывает экран приёма. Возвращает принятый бэкап или null.
Future<BackupContents?> openTransferReceiveScreen(BuildContext context) =>
    Navigator.of(context).push<BackupContents>(
      MaterialPageRoute(builder: (_) => const TransferReceiveScreen()),
    );

class TransferReceiveScreen extends StatefulWidget {
  const TransferReceiveScreen({super.key});

  /// Белое поле QR — тест раскладки ищет его по ключу.
  @visibleForTesting
  static const qrKey = ValueKey('transfer-receive-qr');

  /// Подмены для теста раскладки: адреса, сервер на loopback и кодировщик QR
  /// (zxing — нативная библиотека, в тестах её нет).
  @visibleForTesting
  static Future<List<String>> Function() addresses = localTransferAddresses;
  @visibleForTesting
  static Future<TransferReceiver> Function() openReceiver = TransferReceiver.open;
  @visibleForTesting
  static ({int side, List<bool> dark}) Function(String text) encodeQr =
      _QrMatrix.zxing;

  @override
  State<TransferReceiveScreen> createState() => _TransferReceiveScreenState();
}

enum _Phase { starting, waiting, noNetwork, expired, tooManyAttempts, failed }

class _TransferReceiveScreenState extends State<TransferReceiveScreen> {
  TransferReceiver? _rx;
  _Phase _phase = _Phase.starting;
  List<String> _addresses = const [];
  _QrMatrix? _qr;
  String? _error;
  DateTime? _deadline;
  Timer? _tick;

  /// Номер сессии: ответ закрытой сессии не трогает состояние новой.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(UrlLauncher.setKeepScreenOn(true));
    unawaited(_start());
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_rx?.close());
    unawaited(UrlLauncher.setKeepScreenOn(false));
    super.dispose();
  }

  String get _deviceName {
    final model = SubscriptionIdentity.deviceModel.trim();
    return model.isEmpty ? 'Android TV' : model;
  }

  Future<void> _start() async {
    final gen = ++_generation;
    _tick?.cancel();
    final old = _rx;
    _rx = null;
    if (old != null) await old.close();
    if (!mounted) return;
    setState(() {
      _phase = _Phase.starting;
      _qr = null;
      _error = null;
    });

    try {
      final addresses = await TransferReceiveScreen.addresses();
      if (!mounted || gen != _generation) return;
      if (addresses.isEmpty) {
        setState(() => _phase = _Phase.noNetwork);
        return;
      }
      final rx = await TransferReceiveScreen.openReceiver();
      if (!mounted || gen != _generation) {
        unawaited(rx.close());
        return;
      }
      AppLog.I.info('[transfer] ${addresses.length} local addresses');
      final code = rx.codeFor(addresses, _deviceName);
      _rx = rx;
      setState(() {
        _addresses = addresses;
        final m = TransferReceiveScreen.encodeQr(code.encode());
        _qr = _QrMatrix(m.side, m.dark);
        _deadline = DateTime.now().add(TransferReceiver.sessionTtl);
        _phase = _Phase.waiting;
      });
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      unawaited(rx.done.then((end) => _onEnd(gen, end)));
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _phase = _Phase.failed;
        _error = formatUserError(e).render();
      });
    }
  }

  void _onEnd(int gen, TransferSessionEnd end) {
    if (!mounted || gen != _generation) return;
    _tick?.cancel();
    switch (end) {
      case TransferReceived(:final contents):
        Navigator.of(context).pop(contents);
      case TransferExpired():
        setState(() => _phase = _Phase.expired);
      case TransferRejectedTooOften():
        setState(() => _phase = _Phase.tooManyAttempts);
      case TransferCancelled():
        break;
    }
  }

  String _remaining() {
    final d = _deadline?.difference(DateTime.now()) ?? Duration.zero;
    final s = d.isNegative ? 0 : d.inSeconds;
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(getLocalText.s("Receive settings"))),
      // Экран целиком помещается в окно без прокрутки (P8): на TV при
      // портретной фиксации окно — узкая колонка, и прокрутка уводила кнопки
      // за край, а поле QR — под AppBar. Поэтому сторона QR считается от того,
      // что осталось после подписей и кнопок; кнопки всегда на экране.
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24).withSafeBottom(context),
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth > box.maxHeight;
              // Прежний размер — верхняя граница: в окне, где всё влезало,
              // вид не меняется.
              final cap = (((wide ? box.maxHeight : box.maxWidth) + 48) * 0.75)
                  .clamp(160.0, 420.0);
              final info = _buildInfo(context);
              final actions = _buildActions(context);
              if (wide) {
                final side = math.min(
                    cap, math.min(box.maxHeight, (box.maxWidth - 32) / 2));
                return Align(
                  alignment: Alignment.topLeft,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _buildQr(side),
                      const SizedBox(width: 32),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(child: SingleChildScrollView(child: info)),
                            const SizedBox(height: 24),
                            actions,
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Flexible(
                    child: LayoutBuilder(
                      builder: (context, area) => Align(
                        alignment: Alignment.topCenter,
                        heightFactor: 1,
                        child: _buildQr(math.min(
                            cap, math.min(area.maxWidth, area.maxHeight))),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Подписи не отнимают у QR больше половины окна; длиннее —
                  // прокручиваются сами, кнопки остаются на месте.
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: box.maxHeight / 2),
                    child: SingleChildScrollView(child: info),
                  ),
                  const SizedBox(height: 24),
                  Align(alignment: Alignment.centerLeft, child: actions),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildQr(double side) {
    final qr = _qr;
    final cs = Theme.of(context).colorScheme;
    if (_phase != _Phase.waiting || qr == null) {
      return SizedBox(
        width: side,
        height: side,
        child: Center(
          child: _phase == _Phase.starting
              ? const CircularProgressIndicator()
              : Icon(Icons.qr_code_2,
                  size: side * 0.5, color: cs.onSurfaceVariant.withAlpha(90)),
        ),
      );
    }
    // Белое поле с тихой зоной: сканер телефона не читает код на тёмной теме.
    return Container(
      key: TransferReceiveScreen.qrKey,
      width: side,
      height: side,
      padding: EdgeInsets.all(side * 0.06),
      color: Colors.white,
      child: CustomPaint(painter: _QrPainter(qr)),
    );
  }

  Widget _buildInfo(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final rx = _rx;
    final lines = <Widget>[];

    switch (_phase) {
      case _Phase.starting:
        lines.add(Text(getLocalText.s("Preparing the code…"),
            style: theme.textTheme.titleMedium));
      case _Phase.waiting:
        lines.addAll([
          Text(
            getLocalText.s(
                "On your phone, open Backup & restore in LxBox, choose Send to TV and scan this code."),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          Text(getLocalText.s("Device: %s", _deviceName)),
          Text(getLocalText.s("Address: %s", _addresses.join(', '))),
          Text(getLocalText.s("Code expires in %s", _remaining())),
          const SizedBox(height: 12),
          Text(getLocalText.s("Waiting for the phone…"),
              style: TextStyle(color: cs.primary)),
        ]);
        if (rx != null) {
          lines.add(ValueListenableBuilder<TransferProblem?>(
            valueListenable: rx.problem,
            builder: (context, p, _) => switch (p) {
              null => const SizedBox.shrink(),
              TransferWrongKey(:final count) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    getLocalText.s("Rejected attempts with a wrong code: %1\$d of %2\$d",
                        count, TransferReceiver.maxRejects),
                    style: TextStyle(color: cs.error),
                  ),
                ),
              TransferInvalidBackup(:final reason) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    getLocalText.s(
                        "The phone sent settings that cannot be restored: %s",
                        reason),
                    style: TextStyle(color: cs.error),
                  ),
                ),
            },
          ));
        }
      case _Phase.noNetwork:
        lines.addAll([
          Text(getLocalText.s("No local network"),
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(getLocalText.s(
              "Connect this TV to Wi-Fi or Ethernet, then press New code.")),
        ]);
      case _Phase.expired:
        lines.add(Text(
            getLocalText.s("The code has expired. Press New code to get another one."),
            style: theme.textTheme.titleMedium));
      case _Phase.tooManyAttempts:
        lines.add(Text(
            getLocalText.s(
                "Too many attempts with a wrong code. The code is closed; press New code to get another one."),
            style: theme.textTheme.titleMedium?.copyWith(color: cs.error)));
      case _Phase.failed:
        lines.add(Text(getLocalText.s("Could not start receiving: %s", _error ?? ''),
            style: theme.textTheme.titleMedium?.copyWith(color: cs.error)));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: lines,
    );
  }

  Widget _buildActions(BuildContext context) => Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          OutlinedButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(),
            child: Text(getLocalText.s("Cancel")),
          ),
          FilledButton.icon(
            onPressed: _phase == _Phase.starting ? null : () => unawaited(_start()),
            icon: const Icon(Icons.refresh),
            label: Text(getLocalText.s("New code")),
          ),
        ],
      );
}

/// Матрица модулей QR: zxing кодирует с одним пикселем на модуль, рисуем сами
/// в любом размере без размытия.
class _QrMatrix {
  _QrMatrix(this.side, this.dark);

  final int side;
  final List<bool> dark;

  static ({int side, List<bool> dark}) zxing(String text) {
    final r = zx.encodeBarcode(
      contents: text,
      params: EncodeParams(
        format: Format.qrCode,
        width: 1,
        height: 1,
        margin: 0,
        eccLevel: EccLevel.medium,
      ),
    );
    final data = r.data;
    final w = r.width ?? 0;
    final h = r.height ?? 0;
    if (!r.isValid || data == null || w <= 0 || w != h) {
      throw StateError(r.error ?? 'QR encoding failed');
    }
    return (side: w, dark: [for (final b in data) b < 128]);
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.qr);

  final _QrMatrix qr;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.shortestSide / qr.side;
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var y = 0; y < qr.side; y++) {
      for (var x = 0; x < qr.side; x++) {
        if (qr.dark[y * qr.side + x]) {
          canvas.drawRect(
              Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.qr != qr;
}
