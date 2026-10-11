import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Прототип: нативный редактор (sora-editor) через platform view, hybrid
/// composition. Kotlin-сторона — `editor/SoraEditorPlatformView.kt`.
///
/// Текст живёт в нативном view: читать только через [getText], писать через
/// [setText]. До создания view значения копятся и уходят в creation params.
class LxNativeCodeEditorController {
  MethodChannel? _channel;
  String _pendingText = '';

  Future<String> getText() async {
    final ch = _channel;
    if (ch == null) return _pendingText;
    return await ch.invokeMethod<String>('getText') ?? '';
  }

  Future<void> setText(String text) async {
    final ch = _channel;
    if (ch == null) {
      _pendingText = text;
      return;
    }
    await ch.invokeMethod<void>('setText', {'text': text});
  }

  Future<void> search(String query) async =>
      _channel?.invokeMethod<void>('search', {'query': query});

  Future<void> searchNext() async => _channel?.invokeMethod<void>('searchNext');

  Future<void> searchPrevious() async =>
      _channel?.invokeMethod<void>('searchPrevious');

  void _attach(int id) {
    final ch = MethodChannel('com.leadaxe.lxbox/sora_editor_$id');
    _channel = ch;
    // Текст, пришедший до создания view, — одним вызовом после attach
    // (creation params собираются раньше и могли его не застать).
    if (_pendingText.isNotEmpty) {
      unawaited(ch.invokeMethod<void>('setText', {'text': _pendingText}));
    }
  }

  void _detach() => _channel = null;
}

class LxNativeCodeEditor extends StatefulWidget {
  const LxNativeCodeEditor({
    super.key,
    required this.controller,
    this.readOnly = false,
  });

  final LxNativeCodeEditorController controller;
  final bool readOnly;

  @override
  State<LxNativeCodeEditor> createState() => _LxNativeCodeEditorState();
}

class _LxNativeCodeEditorState extends State<LxNativeCodeEditor> {
  static const _viewType = 'lxbox/sora_editor';
  bool? _dark;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (_dark != null && _dark != dark) {
      unawaited(widget.controller._channel
          ?.invokeMethod<void>('setDark', {'dark': dark}));
    }
    _dark = dark;
  }

  @override
  void didUpdateWidget(LxNativeCodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.readOnly != widget.readOnly) {
      unawaited(widget.controller._channel?.invokeMethod<void>(
          'setReadOnly', {'readOnly': widget.readOnly}));
    }
  }

  @override
  void dispose() {
    widget.controller._detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      viewType: _viewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{
          Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
        },
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      ),
      onCreatePlatformView: (params) {
        final c = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: _viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: <String, Object?>{
            'dark': _dark ?? false,
            'readOnly': widget.readOnly,
          },
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        );
        c.addOnPlatformViewCreatedListener(params.onPlatformViewCreated);
        c.addOnPlatformViewCreatedListener(widget.controller._attach);
        unawaited(c.create());
        return c;
      },
    );
  }
}
