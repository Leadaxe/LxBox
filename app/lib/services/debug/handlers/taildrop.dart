import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;

import '../../../models/node_spec.dart';
import '../../../screens/node_settings/exit_node_store.dart';
import '../../../vpn/cc_channel.dart';
import '../../builder/taildrop_emit.dart' show taildropAllowedByBody;
import '../../tag_resolver.dart';
import '../context.dart';
import '../contract/errors.dart';
import '../transport/request.dart';
import '../transport/response.dart';
import '_shared.dart';

/// §707 итер. 5 — `/taildrop/*`: Taildrop узлов Tailscale без тапов по
/// экрану. Те же нативные пути, что вкладка Network узла, «Send file…» и
/// кнопки уведомлений (через [TaildropDebugActions]).
///
/// Имена файлов и устройств, текст буфера и ссылки по умолчанию не
/// отдаются (правило 030); `?reveal=true` открывает их (маска — удобство,
/// не граница: Debug API — root-доступ by design).
///
/// Routes:
/// - `GET  /taildrop` — узлы Tailscale конфига
/// - `GET  /taildrop/peers?tag=` — устройства узла
/// - `GET  /taildrop/inbox?tag=` — входящие узла (принятые и принимаемые)
/// - `POST /taildrop/send` — отправка файла / заметки / служебного файла
/// - `POST /taildrop/inbox/save|delete|cancel` — как Save / Delete / Cancel
/// - `PUT  /taildrop/settings` — автосохранение, галка «Allow Taildrop»
/// - `PUT  /taildrop/permissions` — разрешение вида команды от устройства
/// - `GET  /taildrop/service-files` — счётчики разбора служебных файлов
Future<DebugResponse> taildropHandler(
    DebugRequest req, DebugContext ctx) async {
  final a = TaildropDebugActions.instance;
  switch ((req.method, req.path)) {
    case ('GET', '/taildrop'):
      return _nodes(req, ctx, a);
    case ('GET', '/taildrop/peers'):
      return _peers(req, ctx, a);
    case ('GET', '/taildrop/inbox'):
      return _inbox(req, ctx, a);
    case ('POST', '/taildrop/send'):
      return _send(req, ctx, a);
    case ('POST', '/taildrop/inbox/save'):
      return _inboxSave(req, ctx, a);
    case ('POST', '/taildrop/inbox/delete'):
      return _inboxDelete(req, ctx, a);
    case ('POST', '/taildrop/inbox/cancel'):
      return _inboxCancel(req, ctx, a);
    case ('PUT', '/taildrop/settings'):
      return _settings(req, ctx, a);
    case ('PUT', '/taildrop/permissions'):
      return _permissions(req, ctx, a);
    case ('GET', '/taildrop/service-files'):
      return _serviceFiles(req, a);
  }
  if (_paths.contains(req.path)) {
    throw BadRequest('method ${req.method} not allowed on ${req.path}');
  }
  throw NotFound('taildrop path: ${req.path}');
}

const _paths = {
  '/taildrop',
  '/taildrop/peers',
  '/taildrop/inbox',
  '/taildrop/send',
  '/taildrop/inbox/save',
  '/taildrop/inbox/delete',
  '/taildrop/inbox/cancel',
  '/taildrop/settings',
  '/taildrop/permissions',
  '/taildrop/service-files',
};

/// Сколько `POST /taildrop/send` ждёт итога передачи. Маршрут получает
/// свой предел запроса чуть больше ([kTaildropSendRequestTimeout]).
const kTaildropSendWait = Duration(seconds: 60);
const kTaildropSendRequestTimeout = Duration(seconds: 65);

/// Действия над нативом. Тесты подменяют [instance] фейком.
class TaildropDebugActions {
  const TaildropDebugActions();

  @visibleForTesting
  static TaildropDebugActions instance = const TaildropDebugActions();

  bool tunnelUp(DebugContext ctx) => ctx.home?.state.tunnelUp ?? false;

  /// Конфиг работающего ядра; его нет — сохранённый (с ним стартует VPN и
  /// его же читает натив: каталоги входящих, выключенные узлы).
  String configJson(DebugContext ctx) {
    final s = ctx.home?.state;
    if (s == null) return '';
    final running = s.tunnelUp ? s.runningConfigRaw : null;
    return running ?? s.configRaw;
  }

  /// Хранимое тело узла [tag] (свой сервер, член папки, узел подписки);
  /// `null` — не нашлось.
  Map<String, dynamic>? nodeBody(DebugContext ctx, String tag) {
    final sub = ctx.sub;
    if (sub == null) return null;
    final target = exitNodeTargetForTag(tag, sub.entries);
    if (target != null) return target.node.body;
    for (final e in sub.entries) {
      for (final n in e.list.nodes) {
        if (n is TailscaleSpec &&
            TagResolver.displayTag(e.list.tagPrefix, n.tag) == tag) {
          return n.body;
        }
      }
    }
    return null;
  }

  /// Галка «Allow Taildrop» в тело узла тем же путём, что блок Settings
  /// вкладки Network. `null` — записано, иначе текст отказа.
  Future<String?> setAllow(DebugContext ctx, String tag, bool allow) async {
    final sub = ctx.requireSub();
    final target = exitNodeTargetForTag(tag, sub.entries);
    if (target == null) {
      throw const Conflict('node body belongs to a subscription or the node '
          'has no own record; change it in the source');
    }
    return storeTailscaleFields(
        sub, target, {'disable_taildrop': allow ? false : null});
  }

  Future<CcTailscaleStatus?> status(String tag) async =>
      (await CcChannel.instance.getTailscaleStatus(tag)).status;

  Future<CcTaildropAutoSave?> autoSave(String tag) =>
      CcChannel.instance.taildropAutoSave(tag);

  Future<bool> setAutoSave(String tag, bool enabled) =>
      CcChannel.instance.setTaildropAutoSave(tag, enabled);

  Future<CcTaildropInbox?> inbox(String tag) =>
      CcChannel.instance.taildropInboxSnapshot(tag);

  Future<CcTaildropResult> save(String tag, String name) =>
      CcChannel.instance.taildropSave(tag, name, downloadsOnly: true);

  Future<String?> delete(String tag, String name) =>
      CcChannel.instance.taildropDelete(tag, name);

  Future<String?> cancelReceiving(String tag, String senderId, String name) =>
      CcChannel.instance.taildropCancelReceiving(tag, senderId, name);

  Future<Map<String, bool>?> permissions(String tag, String peerId) =>
      CcChannel.instance.taildropPermissions(tag, peerId);

  Future<bool> setPermission(String tag, String peerId, String peerName,
          String kind, bool allowed) =>
      CcChannel.instance
          .setTaildropPermission(tag, peerId, peerName, kind, allowed);

  Future<CcTaildropResult> send(
    String tag,
    String peerId,
    String peerName, {
    String? name,
    Uint8List? bytes,
    String? text,
  }) =>
      CcChannel.instance.taildropSendBytes(tag, peerId, peerName,
          name: name, bytes: bytes, text: text, wait: kTaildropSendWait);

  Future<Map<String, dynamic>?> serviceStats() =>
      CcChannel.instance.taildropServiceStats();

  /// Реестр служебных файлов (зеркало контракта в ассетах).
  Future<Map<String, dynamic>> serviceFilesRegistry() async {
    final raw = await rootBundle
        .loadString('assets/contract/registry/service_files.json');
    final root = jsonDecode(raw) as Map<String, dynamic>;
    return (root['service_files'] as Map).cast<String, dynamic>();
  }

  /// §707 итер. 7 — служебный файл собирает натив; `null` — канала нет.
  Future<CcServiceFile?> buildServiceFile(List<Object?> commands) =>
      CcChannel.instance.taildropBuildServiceFile(commands);

  /// §707 итер. 7 — получатель окна «Send clipboard» и ленты.
  Future<Map<String, dynamic>?> clipState() =>
      CcChannel.instance.taildropClipState();
}

// ─────────────────────────────── узлы ───────────────────────────────

/// Endpoint'ы `tailscale` конфига: тег → тело в собранном конфиге.
Map<String, Map<String, dynamic>> _configNodes(String json) {
  if (json.isEmpty) return const {};
  Object? root;
  try {
    root = jsonDecode(json);
  } on FormatException {
    return const {};
  }
  if (root is! Map) return const {};
  final out = <String, Map<String, dynamic>>{};
  final eps = root['endpoints'];
  if (eps is! List) return out;
  for (final e in eps) {
    if (e is! Map || e['type'] != 'tailscale') continue;
    final tag = e['tag'];
    if (tag is String && tag.isNotEmpty) out[tag] = e.cast<String, dynamic>();
  }
  return out;
}

Future<DebugResponse> _nodes(
    DebugRequest req, DebugContext ctx, TaildropDebugActions a) async {
  final up = a.tunnelUp(ctx);
  final nodes = _configNodes(a.configJson(ctx));
  final out = <Map<String, Object?>>[];
  for (final MapEntry(key: tag, value: built) in nodes.entries) {
    final body = a.nodeBody(ctx, tag);
    final auto = await a.autoSave(tag);
    CcTailscaleStatus? st;
    CcTaildropInbox? inbox;
    if (up) {
      st = await a.status(tag);
      inbox = await a.inbox(tag);
    }
    out.add({
      'tag': tag,
      'allow': body == null ? null : taildropAllowedByBody(body),
      'disable_taildrop': built['disable_taildrop'],
      'backend_state': st?.backendState,
      'can_share_files': st?.canShareFiles,
      'autosave': auto?.enabled,
      'autosave_supported': auto?.supported,
      'inbox_files': inbox?.files.length,
      'receiving': inbox?.receiving.length,
      'self_id': st?.self?.stableId,
    });
  }
  // §707 итер. 7 — окно «Send clipboard»: получатель (имя — с reveal) и
  // число сообщений лент; текст сообщений не отдаётся.
  final clip = await a.clipState();
  final target = clip?['target'];
  final feeds = clip?['feeds'];
  return JsonResponse({
    'tunnel_up': up,
    'nodes': out,
    'clip_target': target is Map
        ? {
            'tag': target['tag'],
            'peer_id': target['peer_id'],
            if (req.qBool('reveal')) 'name': target['name'],
          }
        : null,
    'clip_feeds': [
      if (feeds is List)
        for (final f in feeds)
          if (f is Map)
            {
              'tag': f['tag'],
              'peer_id': f['peer_id'],
              'messages': f['messages'],
            },
    ],
  });
}

/// Тег узла из запроса: есть в конфиге, иначе 404. Без префикса источника
/// (эмодзи и пробелы перед именем) — тоже, если такой узел один:
/// `ts-b` → `🕸️ ts-b`.
String _requireNode(DebugContext ctx, TaildropDebugActions a, String? tag) {
  final t = (tag ?? '').trim();
  if (t.isEmpty) throw const BadRequest('param "tag" required');
  final nodes = _configNodes(a.configJson(ctx));
  if (nodes.containsKey(t)) return t;
  final bare = _bareTag(t);
  final hits = nodes.keys.where((k) => _bareTag(k) == bare).toList();
  if (hits.length == 1) return hits.single;
  throw NotFound('tailscale node by tag: $t');
}

/// Тег без ведущих символов, не являющихся буквой или цифрой.
String _bareTag(String tag) =>
    tag.replaceFirst(RegExp(r'^[^\p{L}\p{N}]+', unicode: true), '');

void _requireTunnel(DebugContext ctx, TaildropDebugActions a) {
  if (!a.tunnelUp(ctx)) throw const Conflict('VPN is not running');
}

Future<CcTailscaleStatus> _requireStatus(
    TaildropDebugActions a, String tag) async {
  final st = await a.status(tag);
  if (st == null) throw Conflict('node "$tag" is not running in the core');
  return st;
}

// ─────────────────────────────── пиры ───────────────────────────────

/// Пир по `peer`: stable ID, имя устройства, MagicDNS-имя или адрес.
CcTailscalePeer _findPeer(CcTailscaleStatus st, String peer) {
  final p = peer.trim();
  if (p.isEmpty) throw const BadRequest('field "peer" required');
  final peers = st.peers;
  for (final x in peers) {
    if (x.stableId == p) return x;
  }
  for (final x in peers) {
    if (x.hostName == p || x.dnsNameClean == p || x.ips.contains(p)) return x;
  }
  // Значение не повторяется: это может быть имя устройства.
  throw const NotFound('peer not found among the node devices');
}

Future<DebugResponse> _peers(
    DebugRequest req, DebugContext ctx, TaildropDebugActions a) async {
  final tag = _requireNode(ctx, a, req.q('tag'));
  _requireTunnel(ctx, a);
  final st = await _requireStatus(a, tag);
  final reveal = req.qBool('reveal');
  final out = <Map<String, Object?>>[];
  for (final p in st.peers) {
    final perms = p.stableId.isEmpty
        ? const <String, bool>{}
        : await a.permissions(tag, p.stableId) ?? const <String, bool>{};
    out.add({
      'id': p.stableId,
      'os': p.os,
      'online': p.online,
      'can_receive_files': p.canReceiveFiles,
      'sharee': p.shareeNode,
      'permissions': perms,
      if (reveal) 'name': p.hostName,
    });
  }
  return JsonResponse({
    'tag': tag,
    'self_id': st.self?.stableId,
    'can_share_files': st.canShareFiles,
    'peers': out,
  });
}

// ───────────────────────────── входящие ─────────────────────────────

/// Принятые по времени изменения, при равенстве — по имени: индекс один и
/// тот же, пока входящие не менялись.
List<CcTaildropFile> _sortedFiles(CcTaildropInbox inbox) {
  final files = [...inbox.files];
  files.sort((x, y) {
    final c = x.modifiedAt.compareTo(y.modifiedAt);
    return c != 0 ? c : x.name.compareTo(y.name);
  });
  return files;
}

Future<CcTaildropInbox> _requireInbox(
    DebugContext ctx, TaildropDebugActions a, String tag) async {
  _requireTunnel(ctx, a);
  final inbox = await a.inbox(tag);
  if (inbox == null) {
    throw Conflict('no inbox for "$tag" from the core (node not running or '
        'Taildrop is off for this node)');
  }
  return inbox;
}

Future<DebugResponse> _inbox(
    DebugRequest req, DebugContext ctx, TaildropDebugActions a) async {
  final tag = _requireNode(ctx, a, req.q('tag'));
  final inbox = await _requireInbox(ctx, a, tag);
  final reveal = req.qBool('reveal');
  final nowS = ctx.now().millisecondsSinceEpoch ~/ 1000;
  final files = _sortedFiles(inbox);
  return JsonResponse({
    'tag': tag,
    'files': [
      for (var i = 0; i < files.length; i++)
        {
          'index': i,
          'size': files[i].size,
          'sha256': files[i].sha256,
          'age_s': files[i].modifiedAt > 0 ? nowS - files[i].modifiedAt : null,
          'sender_id': files[i].senderId,
          if (reveal) 'name': files[i].name,
          if (reveal) 'sender_name': files[i].senderName,
        },
    ],
    'receiving': [
      for (var i = 0; i < inbox.receiving.length; i++)
        {
          'index': i,
          'size': inbox.receiving[i].size,
          'received_bytes': inbox.receiving[i].receivedBytes,
          'progress': inbox.receiving[i].progress,
          'sender_id': inbox.receiving[i].senderId,
          if (reveal) 'name': inbox.receiving[i].name,
          if (reveal) 'sender_name': inbox.receiving[i].senderName,
        },
    ],
  });
}

/// Файл входящих по `index` (или `name`) тела.
Future<(String, CcTaildropFile)> _pickFile(
    DebugRequest req, DebugContext ctx, TaildropDebugActions a) async {
  final body = req.jsonBodyAsMap();
  final tag = _requireNode(ctx, a, fieldString(body, 'tag'));
  final inbox = await _requireInbox(ctx, a, tag);
  final files = _sortedFiles(inbox);
  final name = fieldString(body, 'name');
  final index = fieldInt(body, 'index');
  if (name != null) {
    for (final f in files) {
      if (f.name == name) return (tag, f);
    }
    throw const NotFound('inbox file by name');
  }
  if (index == null) throw const BadRequest('field "index" required');
  if (index < 0 || index >= files.length) {
    throw NotFound('inbox file index $index (files: ${files.length})');
  }
  return (tag, files[index]);
}

Future<DebugResponse> _inboxSave(
    DebugRequest req, DebugContext ctx, TaildropDebugActions a) async {
  final (tag, f) = await _pickFile(req, ctx, a);
  final r = await a.save(tag, f.name);
  if (r.status != 'saved') throw Conflict(r.error.isEmpty ? r.status : r.error);
  return JsonResponse({
    'ok': true,
    'action': 'taildrop-save',
    'tag': tag,
    'where': r.where,
    if (req.qBool('reveal')) 'name': r.name,
  });
}

Future<DebugResponse> _inboxDelete(
    DebugRequest req, DebugContext ctx, TaildropDebugActions a) async {
  final (tag, f) = await _pickFile(req, ctx, a);
  final err = await a.delete(tag, f.name);
  if (err != null) throw Conflict(err);
  return JsonResponse({'ok': true, 'action': 'taildrop-delete', 'tag': tag});
}

Future<DebugResponse> _inboxCancel(
    DebugRequest req, DebugContext ctx, TaildropDebugActions a) async {
  final body = req.jsonBodyAsMap();
  final tag = _requireNode(ctx, a, fieldString(body, 'tag'));
  final inbox = await _requireInbox(ctx, a, tag);
  final index = fieldInt(body, 'index');
  if (index == null) throw const BadRequest('field "index" required');
  if (index < 0 || index >= inbox.receiving.length) {
    throw NotFound('receiving index $index '
        '(receiving: ${inbox.receiving.length})');
  }
  final f = inbox.receiving[index];
  final err = await a.cancelReceiving(tag, f.senderId, f.name);
  if (err != null) throw Conflict(err);
  return JsonResponse({'ok': true, 'action': 'taildrop-cancel', 'tag': tag});
}

// ───────────────────────────── отправка ─────────────────────────────

Future<DebugResponse> _send(
    DebugRequest req, DebugContext ctx, TaildropDebugActions a) async {
  final body = req.jsonBodyAsMap();
  final tag = _requireNode(ctx, a, fieldString(body, 'tag'));
  final content = fieldString(body, 'content_base64');
  final text = fieldString(body, 'text');
  final hasCommands = body.containsKey('commands');
  final forms = [content != null, text != null, hasCommands]
      .where((x) => x)
      .length;
  if (forms != 1) {
    throw const BadRequest(
        'exactly one of "content_base64", "text", "commands" required');
  }
  String? name;
  Uint8List? bytes;
  if (content != null) {
    name = (fieldString(body, 'name') ?? '').trim();
    if (name.isEmpty) throw const BadRequest('field "name" required');
    try {
      bytes = base64Decode(content);
    } on FormatException {
      throw const BadRequest('field "content_base64" is not base64');
    }
  } else if (hasCommands) {
    final cmds = body['commands'];
    if (cmds is! List || cmds.isEmpty) {
      throw const BadRequest('field "commands" must be a non-empty array');
    }
    // §707 итер. 7 — собирает натив (формат один с окном «Send clipboard»);
    // команды не проверяются (Debug API шлёт и битые — проверять разбор
    // получателя), предел max_bytes — проверяется, как у отправителя (§7).
    final file = await a.buildServiceFile(cmds);
    if (file == null) throw const Conflict('native channel not available');
    switch (file.error) {
      case '':
        break;
      case 'too_large':
        throw BadRequest('service file is ${file.size} bytes, '
            'over max_bytes ${file.maxBytes}');
      default:
        throw InternalError('service file not built: ${file.error}');
    }
    name = file.name;
    bytes = file.bytes;
    if (name.isEmpty || bytes == null) {
      throw const InternalError('service file not built');
    }
  }
  _requireTunnel(ctx, a);
  final st = await _requireStatus(a, tag);
  final peer = _findPeer(st, fieldString(body, 'peer') ?? '');
  final r = await a.send(tag, peer.stableId, peer.hostName,
      name: name, bytes: bytes, text: text);
  final sent = bytes ?? (text == null ? null : utf8.encode(text));
  final reveal = req.qBool('reveal');
  final result = <String, Object?>{
    'tag': tag,
    'peer_id': peer.stableId,
    'status': r.status,
    if (sent != null) 'bytes': sent.length,
    if (sent != null) 'sha256': sha256.convert(sent).toString(),
    if (reveal) 'name': r.name.isEmpty ? name : r.name,
  };
  switch (r.status) {
    case 'sent':
      return JsonResponse({'ok': true, 'action': 'taildrop-send', ...result});
    case 'in_progress':
      return JsonResponse(
          {'ok': true, 'action': 'taildrop-send', ...result}, status: 202);
    case 'error' when r.error == 'vpn_off':
      throw const Conflict('VPN is not running');
    default:
      throw Conflict(r.error.isEmpty ? r.status : r.error);
  }
}

// ──────────────────────────── настройки ────────────────────────────

Future<DebugResponse> _settings(
    DebugRequest req, DebugContext ctx, TaildropDebugActions a) async {
  final body = req.jsonBodyAsMap();
  final tag = _requireNode(ctx, a, fieldString(body, 'tag'));
  final autosave = fieldBool(body, 'autosave');
  final allow = fieldBool(body, 'allow');
  if (autosave == null && allow == null) {
    throw const BadRequest('at least one of "autosave", "allow" required');
  }
  final out = <String, Object?>{
    'ok': true,
    'action': 'taildrop-settings',
    'tag': tag,
  };
  if (autosave != null) {
    final cur = await a.autoSave(tag);
    if (cur == null) throw const Conflict('native channel not available');
    if (autosave && !cur.supported) {
      throw const Conflict('saving to Downloads needs Android 10 or later');
    }
    if (!await a.setAutoSave(tag, autosave)) {
      throw const Conflict('autosave not written');
    }
    out['autosave'] = autosave;
  }
  if (allow != null) {
    final err = await a.setAllow(ctx, tag, allow);
    if (err != null) throw Conflict(err);
    out['allow'] = allow;
    out['note'] = 'allow applies after rebuild + VPN restart '
        '(?rebuild=true, then POST /action/reload-vpn)';
    out.addAll(await maybeRebuild(req, ctx));
  }
  return JsonResponse(out);
}

Future<DebugResponse> _permissions(
    DebugRequest req, DebugContext ctx, TaildropDebugActions a) async {
  final body = req.jsonBodyAsMap();
  final tag = _requireNode(ctx, a, fieldString(body, 'tag'));
  final kind = (fieldString(body, 'kind') ?? '').trim();
  final enabled = fieldBool(body, 'enabled');
  if (kind.isEmpty) throw const BadRequest('field "kind" required');
  if (enabled == null) throw const BadRequest('field "enabled" required');
  final kinds = (await a.serviceFilesRegistry())['kinds'];
  if (kinds is! Map || !kinds.containsKey(kind)) {
    throw BadRequest('field "kind" must be one of '
        '${kinds is Map ? kinds.keys.join(', ') : '(none)'}');
  }
  _requireTunnel(ctx, a);
  final st = await _requireStatus(a, tag);
  final peer = _findPeer(st, fieldString(body, 'peer') ?? '');
  if (peer.stableId.isEmpty) throw const Conflict('peer has no stable ID');
  if (!await a.setPermission(tag, peer.stableId, peer.hostName, kind, enabled)) {
    throw const Conflict('permission not written');
  }
  return JsonResponse({
    'ok': true,
    'action': 'taildrop-permission',
    'tag': tag,
    'peer_id': peer.stableId,
    'permissions': await a.permissions(tag, peer.stableId),
  });
}

// ───────────────────────── служебные файлы ─────────────────────────

Future<DebugResponse> _serviceFiles(
    DebugRequest req, TaildropDebugActions a) async {
  final stats = await a.serviceStats();
  if (stats == null) throw const Conflict('native channel not available');
  final out = Map<String, Object?>.of(stats);
  final last = stats['last'];
  if (last is Map) {
    final value = '${last['value'] ?? ''}';
    final atMs = last['at_ms'];
    out['last'] = {
      'kind': last['kind'],
      'at': atMs is int
          ? DateTime.fromMillisecondsSinceEpoch(atMs, isUtc: true)
              .toIso8601String()
          : null,
      'sha256': sha256.convert(utf8.encode(value)).toString(),
      if (req.qBool('reveal')) 'value': value,
    };
  }
  return JsonResponse(out);
}
