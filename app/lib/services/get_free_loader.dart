import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/proxy_source.dart';

class GetFreePreset {
  const GetFreePreset({
    required this.title,
    required this.text,
    required this.link,
    required this.proxySources,
    required this.enabledRules,
  });

  final String title;
  final String text;
  final String link;
  final List<ProxySource> proxySources;
  final List<String> enabledRules;
}

class GetFreeLoader {
  GetFreeLoader._();

  static GetFreePreset? _cached;

  static Future<GetFreePreset> load() async {
    if (_cached != null) return _cached!;
    final raw = await rootBundle.loadString('assets/get_free.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;

    final meta = json['get_free'] as Map<String, dynamic>? ?? {};
    final sources = (json['proxy_sources'] as List<dynamic>? ?? [])
        .map((e) => ProxySource.fromJson(e as Map<String, dynamic>))
        .toList();
    final rules = (json['enabled_rules'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();

    _cached = GetFreePreset(
      title: meta['title'] as String? ?? 'Quick Start',
      text: meta['text'] as String? ?? '',
      link: meta['link'] as String? ?? '',
      proxySources: sources,
      enabledRules: rules,
    );
    return _cached!;
  }
}
