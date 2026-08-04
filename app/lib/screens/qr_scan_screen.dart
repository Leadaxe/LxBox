// §375 — экран сканирования QR-кода.
//
// Источник строки для импорта: код с камеры уходит в тот же `addFromInput`,
// что paste/file. Экран ничего не добавляет сам — только возвращает исход,
// разбор формата и подтверждение остаются на вызывающем (subscriptions_screen).
//
// Контракт исходов зеркалит `PickOutcome` из services/file_import.dart:
// отмена — не ошибка (молчим), остальное — снекбар вызывающего.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/app_log.dart';
import '../services/error_format.dart';
import '../services/l10n/locale_controller.dart';

/// Результат работы экрана сканера.
sealed class ScanOutcome {
  const ScanOutcome();
}

/// Код распознан. [value] — сырое содержимое, не разобранное и не
/// провалидированное: разбор делает вызывающий тем же путём, что для буфера.
class ScannedCode extends ScanOutcome {
  const ScannedCode(this.value);

  final String value;
}

/// Юзер ушёл с экрана, не отсканировав. Не ошибка — вызывающий выходит молча.
class ScanCancelled extends ScanOutcome {
  const ScanCancelled();
}

/// Отказано в доступе к камере.
class ScanDenied extends ScanOutcome {
  const ScanDenied();
}

/// Прочий сбой камеры/детектора. [error] — исходное исключение для логов.
class ScanFailed extends ScanOutcome {
  const ScanFailed(this.error);

  final Object error;
}

/// Текст для не-успешного исхода — снекбаром у вызывающего, либо null для
/// [ScannedCode] и [ScanCancelled] (юзер сам ушёл — молчим).
///
/// Зеркало `pickProblemText` из file_import.dart.
String? scanProblemText(ScanOutcome outcome) => switch (outcome) {
      ScannedCode() || ScanCancelled() => null,
      ScanDenied() => getLocalText.s("Camera access denied"),
      ScanFailed(:final error) =>
        getLocalText.s("Camera error: %s", formatUserError(error).render()),
    };

/// Полноэкранный сканер. Возвращает [ScanOutcome] через `Navigator.pop`.
///
/// Вызов: `final outcome = await Navigator.push<ScanOutcome>(...)`. При уходе
/// системной кнопкой «назад» pop произойдёт без значения — вызывающий трактует
/// null как [ScanCancelled].
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _controller = MobileScannerController(
    // Сужаем до QR: не ловим случайные EAN/штрихкоды с окружающих предметов.
    formats: const [BarcodeFormat.qrCode],
  );

  /// Детектор отдаёт кадры пачками — один и тот же код придёт несколько раз
  /// подряд. Без флага получаем повторные pop'ы уже закрытого экрана.
  bool _handled = false;

  @override
  void dispose() {
    // Обязательно: иначе камера остаётся занятой после ухода с экрана.
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _finish(ScanOutcome outcome) {
    if (_handled || !mounted) return;
    _handled = true;
    Navigator.of(context).pop(outcome);
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value != null && value.isNotEmpty) {
        AppLog.I.info('[qr] scanned ${value.length} chars');
        _finish(ScannedCode(value));
        return;
      }
    }
  }

  void _onError(MobileScannerException e) {
    if (_handled) return;
    AppLog.I.warning('[qr] scanner error: ${e.errorCode}');
    _finish(e.errorCode == MobileScannerErrorCode.permissionDenied
        ? const ScanDenied()
        : ScanFailed(e));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(getLocalText.s("Scan QR code")),
        actions: [
          IconButton(
            tooltip: getLocalText.s("Torch"),
            onPressed: () => _controller.toggleTorch(),
            icon: ValueListenableBuilder(
              valueListenable: _controller,
              builder: (_, state, _) => Icon(
                state.torchState == TorchState.on
                    ? Icons.flash_on
                    : Icons.flash_off,
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (_, error) {
              // Ошибка приходит и сюда, и в onDetect-стрим: закрываем экран
              // из одного места, а на кадре показываем текст, пока не ушли.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _onError(error);
              });
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    scanProblemText(
                          error.errorCode ==
                                  MobileScannerErrorCode.permissionDenied
                              ? const ScanDenied()
                              : ScanFailed(error),
                        ) ??
                        '',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            },
          ),
          // Подсказка поверх превью — юзер видит, что от него хотят.
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              color: Colors.black54,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
              child: Text(
                getLocalText.s("Point the camera at a QR code"),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
