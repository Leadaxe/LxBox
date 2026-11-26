part of '../subscription_controller.dart';

// Подпись уведомления о погашенных ссылках (§439). Вынесено `part`'ом из
// `subscription_controller.dart` (задача 740) без изменений.

/// §439 (D-114) — что удалено: подпись уведомления о погашенных ссылках.
final class NodeLinkSubject {
  const NodeLinkSubject._(this.kind, this.name, [this.count = 1]);

  /// Источник целиком: одиночный сервер, подписка или папка. [name] —
  /// подпись записи в списке (у подписки без имени — адрес).
  factory NodeLinkSubject.of(ServerList list, {String? name}) =>
      switch (list) {
        UserServer u => NodeLinkSubject._(
            NodeLinkSubjectKind.server,
            u.nodes.isNotEmpty
                ? containerFinalForm(u, u.nodes.first.tag)
                : (name ?? u.name),
          ),
        SubscriptionServers s => NodeLinkSubject._(
            NodeLinkSubjectKind.subscription, name ?? s.name),
        FolderServers f =>
          NodeLinkSubject._(NodeLinkSubjectKind.folder, f.name),
      };

  /// Член папки [folder].
  factory NodeLinkSubject.member(FolderServers folder, FolderMember m) =>
      NodeLinkSubject._(
        NodeLinkSubjectKind.server,
        m.node == null ? '' : containerFinalForm(folder, m.node!.tag),
      );

  /// Несколько серверов разом.
  factory NodeLinkSubject.servers(int count) =>
      NodeLinkSubject._(NodeLinkSubjectKind.servers, '', count);

  final NodeLinkSubjectKind kind;
  final String name;
  final int count;
}

enum NodeLinkSubjectKind { server, subscription, folder, servers }

/// §439 (D-114) — удаление погасило ссылки: кого удалили и кого задело.
final class NodeLinkNotice {
  const NodeLinkNotice({required this.subject, required this.change});

  final NodeLinkSubject subject;
  final NodeLinkChange change;
}
