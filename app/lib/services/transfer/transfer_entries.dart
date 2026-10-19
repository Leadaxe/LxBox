// §622 — где показывать пункты передачи настроек (фича 031, P10).

import '../url_launcher.dart';

/// Какие пункты передачи видит это устройство.
class TransferEntries {
  const TransferEntries({required this.receive, required this.send});

  /// «Receive from phone» — только на TV.
  final bool receive;

  /// «Send to TV» — не на TV и только с камерой (сканер QR).
  final bool send;

  static const none = TransferEntries(receive: false, send: false);
}

/// Решение «показывать пункт» — чистая функция для юнитов.
TransferEntries transferEntriesFor({
  required bool isTelevision,
  required bool hasCamera,
}) =>
    TransferEntries(
      receive: isTelevision,
      send: !isTelevision && hasCamera,
    );

/// То же решение по признакам устройства.
Future<TransferEntries> loadTransferEntries() async {
  final r = await Future.wait([
    UrlLauncher.isTelevision(),
    UrlLauncher.hasCamera(),
  ]);
  return transferEntriesFor(isTelevision: r[0], hasCamera: r[1]);
}
