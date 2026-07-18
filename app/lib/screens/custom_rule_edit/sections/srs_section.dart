import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../validators.dart' as v;
import '../widgets/section_header.dart';
import '../../../services/l10n/locale_controller.dart';

/// §053 Stage 2 — состояние ☁ кнопки рядом с SRS URL.
/// Public (раньше был private `_SrsDownloadState`).
enum SrsDownloadState { none, loading, cached, error }

/// §053 Stage 2 — RULE-SET URL section: URL field + ☁ download button
/// (тап → fetch, long-press → menu Refresh / Clear cache).
class SrsSection extends StatefulWidget {
  const SrsSection({
    super.key,
    required this.urlCtrl,
    required this.state,
    required this.onDownload,
    required this.onShowCloudMenu,
    required this.onUrlChanged,
  });

  final TextEditingController urlCtrl;
  final SrsDownloadState state;
  final VoidCallback onDownload;

  /// Long-press на ☁ — показать context menu (Refresh / Clear). Параметр —
  /// глобальная позиция тапа (Offset из onLongPressStart.globalPosition).
  final void Function(Offset globalPos) onShowCloudMenu;

  /// Юзер изменил URL — parent может сбросить error state в none.
  final VoidCallback onUrlChanged;

  @override
  State<SrsSection> createState() => _SrsSectionState();
}

class _SrsSectionState extends State<SrsSection> {
  @override
  void initState() {
    super.initState();
    widget.urlCtrl.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(covariant SrsSection old) {
    super.didUpdateWidget(old);
    if (old.urlCtrl != widget.urlCtrl) {
      old.urlCtrl.removeListener(_onTextChanged);
      widget.urlCtrl.addListener(_onTextChanged);
    }
  }

  @override
  void dispose() {
    widget.urlCtrl.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
    widget.onUrlChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final url = widget.urlCtrl.text.trim();
    final urlValid = url.isNotEmpty && v.isValidUrl(url);

    Widget cloud;
    if (widget.state == SrsDownloadState.loading) {
      cloud = const SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
        ),
      );
    } else {
      final (IconData icon, Color color) = switch (widget.state) {
        SrsDownloadState.cached =>
          (Icons.cloud_done_outlined, Colors.green),
        SrsDownloadState.error =>
          (Icons.cloud_off_outlined, t.colorScheme.error),
        SrsDownloadState.none || SrsDownloadState.loading => (
            Icons.cloud_download_outlined,
            t.colorScheme.onSurfaceVariant
          ),
      };
      cloud = GestureDetector(
        onTap: urlValid ? widget.onDownload : null,
        onLongPressStart: (d) => widget.onShowCloudMenu(d.globalPosition),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          child: Icon(icon, color: color, size: 20),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'RULE-SET URL',
          hint: 'Manual download only. Tap ☁ to fetch the .srs file '
              'locally.',
        ),
        TextField(
          controller: widget.urlCtrl,
          style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            isDense: true,
            // l10n-exempt: example URL, locale-independent
            hintText: 'https://example.com/rules.srs',
            prefixIcon: IconButton(
              icon: const Icon(Icons.link, size: 18),
              tooltip: getLocalText.s("Copy URL"),
              onPressed: () async {
                final text = widget.urlCtrl.text.trim();
                if (text.isEmpty) return;
                final messenger = ScaffoldMessenger.of(context);
                final copied = getLocalText.s("URL copied");
                await Clipboard.setData(ClipboardData(text: text));
                if (!mounted) return;
                messenger.showSnackBar(
                  SnackBar(content: Text(copied)),
                );
              },
            ),
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: cloud,
            ),
          ),
        ),
        const SizedBox(height: 4),
        TextButton.icon(
          icon: const Icon(Icons.content_paste, size: 14),
          label: Text(getLocalText.s("Paste"),
              style: const TextStyle(fontSize: 12)),
          onPressed: () async {
            final data = await Clipboard.getData(Clipboard.kTextPlain);
            final text = (data?.text ?? '').trim();
            if (text.isEmpty) return;
            widget.urlCtrl.text = text;
          },
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 28),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
        ),
      ],
    );
  }
}
