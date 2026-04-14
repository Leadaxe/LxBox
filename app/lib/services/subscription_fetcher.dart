import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/proxy_source.dart';
import 'subscription_decoder.dart';

/// Fetches and decodes a subscription from URL.
/// Port of singbox-launcher `core/config/subscription/fetcher.go`.
class SubscriptionFetcher {
  SubscriptionFetcher._();

  static const Duration _timeout = Duration(seconds: 30);
  static const int _maxResponseSize = 10 * 1024 * 1024; // 10 MB

  /// Downloads subscription from [url], decodes base64/plain, returns raw bytes.
  static Future<Uint8List> fetch(String url) async {
    final uri = Uri.parse(url);
    final request = http.Request('GET', uri)
      ..headers['User-Agent'] = subscriptionUserAgent;

    final client = http.Client();
    try {
      final streamed = await client.send(request).timeout(_timeout);
      if (streamed.statusCode != 200) {
        throw Exception(
          'Subscription server returned status ${streamed.statusCode}',
        );
      }

      final bytes = await streamed.stream.toBytes();
      if (bytes.isEmpty) {
        throw Exception('Subscription returned empty content');
      }
      if (bytes.length > _maxResponseSize) {
        throw Exception(
          'Subscription content too large (exceeds $_maxResponseSize bytes)',
        );
      }

      return SubscriptionDecoder.decode(Uint8List.fromList(bytes));
    } finally {
      client.close();
    }
  }
}
