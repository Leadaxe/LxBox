import 'package:flutter/material.dart';

class OutboundViewScreen extends StatelessWidget {
  const OutboundViewScreen({
    super.key,
    required this.tag,
    required this.kind,
    required this.json,
    required this.detourCount,
    required this.onCopy,
  });

  final String tag;
  final String kind;
  final String json;

  /// §099 — число detour-хопов у ноды (0 = нет). Определяет вид Copy-аффорданса
  /// и лейбл «server + detour(s)».
  final int detourCount;

  /// Копирование JSON-варианта (перенесено из контекстного меню ноды, §099).
  /// `mode`: `'server'` | `'detour'` | `'both'` → `copyNodeJson`.
  final void Function(String mode) onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // §099 — лейбл «both»: единственное «detour» или «detours(N)» при N>1.
    final bothLabel = detourCount > 1
        ? 'Copy server + detours($detourCount)'
        : 'Copy server + detour';
    return Scaffold(
      appBar: AppBar(
        title: Text('$kind · $tag', overflow: TextOverflow.ellipsis),
        actions: [
          // §099 — без detour: простая кнопка Copy (JSON ноды). С detour:
          // выпадашка (Copy server JSON / Copy detour / Copy server + detour(s)).
          if (detourCount > 0)
            PopupMenuButton<String>(
              tooltip: 'Copy',
              icon: const Icon(Icons.content_copy),
              onSelected: onCopy,
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'server',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.content_copy, size: 20),
                    title: Text('Copy server JSON'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'detour',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.alt_route, size: 20),
                    title: Text('Copy detour'),
                  ),
                ),
                PopupMenuItem(
                  value: 'both',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.copy_all, size: 20),
                    title: Text(bothLabel),
                  ),
                ),
              ],
            )
          else
            IconButton(
              tooltip: 'Copy JSON',
              icon: const Icon(Icons.content_copy),
              onPressed: () => onCopy('server'),
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: TextEditingController(text: json),
            readOnly: true,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: theme.colorScheme.onSurface,
            ),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.all(10),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerLow,
            ),
          ),
        ),
      ),
    );
  }
}
