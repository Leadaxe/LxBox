import '../../services/l10n/locale_controller.dart';
import '../../services/transfer/transfer_sender.dart';

/// §622 — итог отправки на TV одной строкой (фича 031, P6): каждый случай
/// назван, общего «Error» нет.
String transferSendResultText(TransferSendResult r) => switch (r.status) {
      TransferSendStatus.sent =>
        getLocalText.s("Sent. Confirm the restore on the TV."),
      TransferSendStatus.unreachable => getLocalText.s(
          "Cannot reach the TV. Both devices must be on the same network; "
          "guest Wi-Fi often keeps devices from seeing each other."),
      TransferSendStatus.expired => getLocalText.s(
          "The code has expired or was already used. Show a new code on the TV."),
      TransferSendStatus.rejected => getLocalText.s(
          "The TV did not accept the code. Show a new code on the TV and scan it again."),
      TransferSendStatus.tooLarge =>
        getLocalText.s("The settings are too large to send."),
      TransferSendStatus.invalid => getLocalText.s(
          "The TV cannot restore these settings: %s", r.detail ?? ''),
      TransferSendStatus.busy => getLocalText.s(
          "The TV is busy with another request. Try again in a moment."),
      TransferSendStatus.failed =>
        getLocalText.s("Sending failed: HTTP %d", r.httpStatus ?? 0),
    };
