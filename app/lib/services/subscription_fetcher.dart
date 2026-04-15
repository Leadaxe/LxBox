import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/proxy_source.dart';
import 'subscription_decoder.dart';

/// Result of a subscription fetch — decoded content + metadata from HTTP headers.
class FetchResult {
  FetchResult({required this.content, this.title, this.userInfo, this.supportUrl, this.webPageUrl});
  final Uint8List content;
  final String? title;
  final SubscriptionUserInfo? userInfo;
  final String? supportUrl;
  final String? webPageUrl;
}

/// Parsed `subscription-userinfo` header.
class SubscriptionUserInfo {
  SubscriptionUserInfo({this.upload = 0, this.download = 0, this.total = 0, this.expire = 0});
  final int upload;
  final int download;
  final int total;
  final int expire; // unix timestamp, 0 = unlimited

  static SubscriptionUserInfo? parse(String? header) {
    if (header == null || header.isEmpty) return null;
    int upload = 0, download = 0, total = 0, expire = 0;
    for (final part in header.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length != 2) continue;
      final key = kv[0].trim();
      final val = int.tryParse(kv[1].trim()) ?? 0;
      switch (key) {
        case 'upload': upload = val;
        case 'download': download = val;
        case 'total': total = val;
        case 'expire': expire = val;
      }
    }
    return SubscriptionUserInfo(upload: upload, download: download, total: total, expire: expire);
  }
}

/// Fetches and decodes a subscription from URL.
class SubscriptionFetcher {
  SubscriptionFetcher._();

  static const Duration _timeout = Duration(seconds: 30);
  static const int _maxResponseSize = 10 * 1024 * 1024; // 10 MB

  /// Downloads subscription from [url], decodes, returns content + metadata.
  static Future<FetchResult> fetchWithMeta(String url) async {
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
      if (bytes.isEmpty) throw Exception('Subscription returned empty content');
      if (bytes.length > _maxResponseSize) {
        throw Exception('Subscription content too large');
      }

      // Parse profile-title header (may be base64-encoded)
      final rawTitle = streamed.headers['profile-title'];
      String? title;
      if (rawTitle != null && rawTitle.isNotEmpty) {
        if (rawTitle.startsWith('base64:')) {
          try {
            title = utf8.decode(base64Decode(rawTitle.substring(7)));
          } catch (_) {
            title = rawTitle.substring(7);
          }
        } else {
          title = rawTitle;
        }
      }

      final userInfo = SubscriptionUserInfo.parse(
        streamed.headers['subscription-userinfo'],
      );

      final supportUrl = streamed.headers['support-url'];
      final webPageUrl = streamed.headers['profile-web-page-url'];

      return FetchResult(
        content: SubscriptionDecoder.decode(Uint8List.fromList(bytes)),
        title: title,
        userInfo: userInfo,
        supportUrl: supportUrl,
        webPageUrl: webPageUrl,
      );
    } finally {
      client.close();
    }
  }

  /// Simple fetch — returns decoded bytes only (backward compat).
  static Future<Uint8List> fetch(String url) async {
    final result = await fetchWithMeta(url);
    return result.content;
  }
}
