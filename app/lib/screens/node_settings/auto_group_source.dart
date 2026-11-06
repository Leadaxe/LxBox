/// §686 — вкладки Source и JSON карточки auto-узла папки (член `kind: auto`).
///
/// Текста узла у группы нет (§439): Source показывает запись, как она
/// хранится (`autoGroupMemberToRecord`), Save разбирает её
/// `autoGroupMemberFromRecord`. Форма группы на Settings правит этот текст:
/// заменяет `tag` и `group`, остальные ключи записи (`kind`, `enabled`,
/// `warnings`, набранные руками) остаются как есть.
library;

import 'dart:convert';

import '../../models/auto_select.dart';
import '../../models/codec/auto_group_record.dart';
import '../../models/node_spec.dart';
import '../../models/server_list.dart';
import '../../models/template_vars.dart';
import '../../services/contract/form_source_sync.dart';
import '../../services/l10n/locale_controller.dart';

const _encoder = JsonEncoder.withIndent('  ');

/// Текст Source auto-узла [group] члена [m] папки [folderId]: запись
/// `kind: auto` отформатированным JSON.
String autoGroupSourceText(
        FolderMember m, AutoSelectSpec group, String folderId) =>
    _encoder.convert(autoGroupMemberToRecord(m, group, folderId));

/// Текст Source [source] после правки формы: `tag` и `group` — из [group],
/// прочие ключи прежнего текста — как были. [source] не объект — запись
/// целиком.
String autoGroupSourceWith(String source, FolderMember m,
    AutoSelectSpec group, String folderId) {
  final record = autoGroupMemberToRecord(m, group, folderId);
  final before = formBodyFromSource(source);
  if (before == null) return _encoder.convert(record);
  final out = <String, dynamic>{...before};
  if (record.containsKey('tag')) {
    out['tag'] = record['tag'];
  } else {
    out.remove('tag');
  }
  out['group'] = record['group'];
  return _encoder.convert(out);
}

/// Группа для формы из текста Source — разбор терпимый, как у читателя
/// хранилища. `null` — текст не JSON-объект: форма неактивна. [current] даёт
/// `id` и синонимы: они не хранятся в записи.
AutoSelectSpec? autoGroupFromSourceText(
    String text, String folderId, AutoSelectSpec current) {
  final body = formBodyFromSource(text);
  if (body == null) return null;
  final read = autoGroupMemberFromRecord(body,
      folderId: folderId, where: 'Source');
  final node = read.member.node;
  return node is AutoSelectSpec ? _keepIdentity(current, node) : null;
}

/// Итог разбора Source при Save.
sealed class AutoGroupSourceParse {
  const AutoGroupSourceParse();
}

final class AutoGroupSourceReady extends AutoGroupSourceParse {
  const AutoGroupSourceReady(this.group, this.enabled);
  final AutoSelectSpec group;
  final bool enabled;
}

final class AutoGroupSourceRejected extends AutoGroupSourceParse {
  const AutoGroupSourceRejected(this.message);
  final String message;
}

/// Save вкладки Source: строгий разбор записи. Не JSON, не объект, `kind` не
/// `auto` или незнакомые ключи — отказ с путём ключа, запись не меняется.
AutoGroupSourceParse parseAutoGroupSource(
    String text, String folderId, AutoSelectSpec current) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text.trim());
  } on FormatException catch (e) {
    return AutoGroupSourceRejected(
        getLocalText.s("Invalid JSON: %s", e.message));
  }
  if (decoded is! Map) {
    return AutoGroupSourceRejected(
        getLocalText.s("Source is not a JSON object."));
  }
  final j = decoded.cast<String, dynamic>();
  if (j['kind'] != kNodeKindAuto) {
    return AutoGroupSourceRejected(
        getLocalText.s("\"kind\" must be \"auto\"."));
  }
  final unknown = <String>[];
  final read = autoGroupMemberFromRecord(j,
      folderId: folderId, where: 'Source', unknown: unknown);
  if (unknown.isNotEmpty) {
    return AutoGroupSourceRejected(
        getLocalText.s("Unknown keys: %s", unknown.join(', ')));
  }
  final node = read.member.node;
  if (node is! AutoSelectSpec) {
    return AutoGroupSourceRejected(
        getLocalText.s("\"kind\" must be \"auto\"."));
  }
  return AutoGroupSourceReady(
      _keepIdentity(current, node), read.member.enabled);
}

/// Группа из записи с `id` и синонимами [current]: запись их не несёт.
AutoSelectSpec _keepIdentity(AutoSelectSpec current, AutoSelectSpec read) =>
    current.copyWith(
      tag: read.tag,
      label: read.label,
      membership: read.membership,
      params: read.params,
      poolBadge: read.poolBadge,
      manualDefault: read.manualDefault,
      genus: read.genus,
    );

/// Вкладка JSON: тело группы для ядра. У группы-правила состав считает
/// сборка — вместо пустого `outbounds` строка об этом; у явного состава
/// (Pick) — сырые теги выбранных членов (`emitRaw`).
Map<String, dynamic> autoGroupJsonPreview(AutoSelectSpec group) {
  final map = <String, dynamic>{...group.emit(TemplateVars.empty).map};
  if (group.membership is RuleMembers) {
    map['outbounds'] = getLocalText.s("Members are resolved at build time");
  }
  return map;
}
