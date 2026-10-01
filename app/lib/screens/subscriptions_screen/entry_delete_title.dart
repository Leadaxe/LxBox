import '../../models/server_list.dart';
import '../../services/l10n/locale_controller.dart';

/// §603 — заголовок подтверждения удаления записи по её типу. Свой сервер
/// раньше спрашивал «Delete subscription?». Общий для long-press меню списка и
/// экрана деталей.
String deleteEntryTitle(ServerList list) => list is UserServer
    ? getLocalText.s("Delete server?")
    : getLocalText.s("Delete subscription?");
