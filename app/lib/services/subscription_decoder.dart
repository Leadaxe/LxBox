import 'dart:convert';
import 'dart:typed_data';

/// Decodes subscription content: base64 (4 variants), Xray JSON array, plain text.
/// Port of singbox-launcher `core/config/subscription/decoder.go`.
class SubscriptionDecoder {
  SubscriptionDecoder._();

  static Uint8List decode(Uint8List content) {
    if (content.isEmpty) {
      throw FormatException('Subscription content is empty');
    }

    final raw = utf8.decode(content, allowMalformed: true).trim();
    if (raw.isEmpty) return content;

    // 1. Try base64 (4 variants)
    final b64 = _tryDecodeBase64(raw);
    if (b64 != null) {
      if (b64.isEmpty) throw FormatException('Decoded content is empty');
      return b64;
    }

    // 2. JSON array (Xray-style)
    if (raw.startsWith('[')) {
      try {
        final list = jsonDecode(raw);
        if (list is List && list.isNotEmpty) {
          return Uint8List.fromList(utf8.encode(raw));
        }
      } catch (_) {}
    }

    // 3. Single JSON object or invalid JSON array: not a subscription
    if (raw.startsWith('{') || raw.startsWith('[')) {
      throw FormatException(
        'Subscription URL returned JSON configuration instead of '
        'subscription list (base64 or plain text links)',
      );
    }

    // 4. Plain text links
    if (raw.contains('://')) {
      return content;
    }

    throw FormatException('Failed to decode subscription content');
  }

  static Uint8List? _tryDecodeBase64(String s) {
    for (final codec in _base64Codecs) {
      try {
        final decoded = codec.decode(s);
        if (decoded.isNotEmpty && _isValidUtf8(decoded)) {
          return decoded;
        }
      } catch (_) {}
    }
    return null;
  }

  static bool _isValidUtf8(Uint8List bytes) {
    try {
      utf8.decode(bytes);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Base64 codecs: URL-safe no-pad, standard no-pad, URL-safe padded, standard padded.
final _base64Codecs = [
  _Base64Variant(base64Url, noPadding: true),
  _Base64Variant(base64, noPadding: true),
  _Base64Variant(base64Url, noPadding: false),
  _Base64Variant(base64, noPadding: false),
];

class _Base64Variant {
  _Base64Variant(this._codec, {required this.noPadding});
  final Base64Codec _codec;
  final bool noPadding;

  Uint8List decode(String s) {
    var input = s.replaceAll(RegExp(r'\s+'), '');
    if (noPadding) {
      final rem = input.length % 4;
      if (rem == 2) {
        input += '==';
      } else if (rem == 3) {
        input += '=';
      }
    }
    return Uint8List.fromList(_codec.decode(input));
  }
}
