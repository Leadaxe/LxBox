import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

class FreeVpnList {
  const FreeVpnList({
    required this.name,
    required this.description,
    required this.source,
    this.tagPrefix = '',
  });

  final String name;
  final String description;
  final String source;
  final String tagPrefix;
}

class GetFreePreset {
  const GetFreePreset({
    required this.title,
    required this.text,
    required this.link,
    required this.lists,
    required this.enabledRules,
  });

  final String title;
  final String text;
  final String link;
  final List<FreeVpnList> lists;
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
    final lists = (json['lists'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map((e) => FreeVpnList(
              name: e['name'] as String? ?? '',
              description: e['description'] as String? ?? '',
              source: e['source'] as String? ?? '',
              tagPrefix: e['tag_prefix'] as String? ?? '',
            ))
        .toList();
    final rules = (json['enabled_rules'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();

    _cached = GetFreePreset(
      title: meta['title'] as String? ?? 'Quick Start',
      text: meta['text'] as String? ?? '',
      link: meta['link'] as String? ?? '',
      lists: lists,
      enabledRules: rules,
    );
    return _cached!;
  }
}
