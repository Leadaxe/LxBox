// §279 — pre-parse overlay display-текста wizard_template.json.
//
// Локализация шаблона = мутация декодированной JSON-map ДО WizardTemplate.fromJson
// и ДО preset_expand-снапшотов: каждый downstream-потребитель (парсенные модели
// и raw-map dns/ping/speed) локализуется бесплатно, call-site'ы не меняются.
//
// Схема адресов — жёсткий whitelist (§3.2 спеки 279): только display-поля.
// Machine-поля (config/parser_config, name/tag/value/default_value/preset_id,
// dns_options.rules[].name — identity-ключ) не адресуются by construction:
// walker их просто не посещает.
//
// Файл — pure Dart (без flutter-импортов): его использует и runtime-loader,
// и CLI-checkers (tool/l10n), и генерация en.json.

/// Callback walker'а: (адрес, map-узел, имя display-поля в узле).
typedef _Visit = void Function(String address, Map node, String field);

class TemplateOverlay {
  TemplateOverlay._();

  /// Применить [overlay] (адрес → перевод) к декодированному шаблону.
  /// Мутирует [templateJson] in-place. Отсутствующий в overlay адрес —
  /// тихий английский fallback (by design).
  static void apply(
      Map<String, dynamic> templateJson, Map<String, String> overlay) {
    if (overlay.isEmpty) return;
    _walk(templateJson, (address, node, field) {
      final v = overlay[address];
      if (v == null || v.isEmpty) return;
      // Load-bearing (не гигиена): overlay применяется ДО preset_expand, т.е.
      // строка с '@'-префиксом стала бы var-ссылкой, а '{' — ICU/подстановкой.
      // Checker (tool/l10n) режет такие значения в CI; тут — вторая линия.
      if (v.startsWith('@') || v.contains('{')) return;
      node[field] = v;
    });
  }

  /// Извлечь адрес → английское значение из декодированного шаблона.
  /// Hard-fail на дубликате адреса с конфликтующими значениями (last-wins
  /// запрещён — коллизия видна в момент внесения, не после отгрузки ru.json).
  static Map<String, String> extract(Map<String, dynamic> templateJson) {
    final out = <String, String>{};
    _walk(templateJson, (address, node, field) {
      final v = node[field] as String;
      final prev = out[address];
      if (prev != null && prev != v) {
        throw StateError(
            'duplicate overlay address "$address" with conflicting values: '
            '"$prev" vs "$v"');
      }
      out[address] = v;
    });
    return out;
  }

  /// Парсит содержимое locale-overlay файла (`assets/l10n/template/<tag>.json`)
  /// в плоскую Map. Записи — объектные `{"text": "...", "src": "<hash>"}`
  /// (`src` — durable stale-маркер для CI, в runtime игнорируется); плоские
  /// строковые значения тоже принимаются (формат en.json).
  static Map<String, String> parseLocaleFile(Map<String, dynamic> json) {
    final out = <String, String>{};
    json.forEach((key, value) {
      if (value is String) {
        out[key] = value;
      } else if (value is Map && value['text'] is String) {
        out[key] = value['text'] as String;
      }
    });
    return out;
  }

  // ---------------------------------------------------------------------------
  // Schema-driven walker — единственное знание о том, ГДЕ живёт display-текст.
  // apply и extract ходят одним маршрутом → их whitelist'ы совпадают всегда.
  // Посещаются только существующие непустые String-поля: apply не добавляет
  // полей, которых в английском шаблоне нет.
  // ---------------------------------------------------------------------------

  static void _walk(Map<String, dynamic> t, _Visit visit) {
    void str(dynamic node, String address, String field) {
      if (node is! Map) return;
      final v = node[field];
      if (v is String && v.isNotEmpty) visit(address, node, field);
    }

    // Var-узел: title/tooltip + object-form enum-опции (`{title, value}`).
    // Bare-string опции не адресуются (wire-значения). Ref-vars (`{"ref": n}`)
    // display-полей не несут — резолвятся против пропатченной декларации.
    void varNode(dynamic v, String base) {
      if (v is! Map || v['name'] is! String) return;
      str(v, '$base.title', 'title');
      str(v, '$base.tooltip', 'tooltip');
      final opts = v['options'];
      if (opts is List) {
        for (final o in opts) {
          if (o is Map && o['value'] is String) {
            str(o, '$base.option.${o['value']}', 'title');
          }
        }
      }
    }

    // sections[] — id (новое поле §279 Phase 0) скоупит name/description;
    // глобальные vars — плоский `var.<name>.*` (name = machine-id).
    final sections = t['sections'];
    if (sections is List) {
      for (final s in sections) {
        if (s is! Map) continue;
        final id = s['id'];
        if (id is! String || id.isEmpty) continue;
        str(s, 'section.$id.name', 'name');
        str(s, 'section.$id.description', 'description');
        final vars = s['vars'];
        if (vars is List) {
          for (final v in vars) {
            if (v is Map && v['name'] is String) {
              varNode(v, 'var.${v['name']}');
            }
          }
        }
      }
    }

    // selectable_rules[] — rule-локальные vars скоупятся preset_id (P0 ревью:
    // одноимённые vars разных пресетов несут разный текст, плоский неймспейс
    // молча схлопывал их last-wins). dns_servers тела пресета — по tag.
    final rules = t['selectable_rules'];
    if (rules is List) {
      for (final r in rules) {
        if (r is! Map) continue;
        final pid = r['preset_id'];
        if (pid is! String || pid.isEmpty) continue;
        str(r['ui'], 'preset.$pid.label', 'label');
        str(r['ui'], 'preset.$pid.description', 'description');
        final vars = r['vars'];
        if (vars is List) {
          for (final v in vars) {
            if (v is Map && v['name'] is String) {
              varNode(v, 'preset.$pid.var.${v['name']}');
            }
          }
        }
        final ds = r['dns_servers'];
        if (ds is List) {
          for (final d in ds) {
            if (d is Map && d['tag'] is String) {
              str(d, 'preset.$pid.dns_server.${d['tag']}.description',
                  'description');
            }
          }
        }
      }
    }

    // group_templates.magic_nodes — титулы magic-нод (auto/direct/block).
    final gt = t['group_templates'];
    if (gt is Map) {
      final magic = gt['magic_nodes'];
      if (magic is Map) {
        for (final e in magic.entries) {
          str(e.value, 'magic.${e.key}.title', 'title');
        }
      }
    }

    // default_channels[] — seed-метки каналов (после seed'а — user data).
    final channels = t['default_channels'];
    if (channels is List) {
      for (final c in channels) {
        if (c is Map && c['tag'] is String) {
          str(c, 'channel.${c['tag']}.label', 'label');
        }
      }
    }

    // dns_options.servers[] — tag живёт во вложенном server-объекте; description
    // и vars — на уровне entry. dns_options.rules[].name НЕ адресуется —
    // латентный identity-ключ (dns_rules.dart), никогда не локализуется.
    final dnsOptions = t['dns_options'];
    if (dnsOptions is Map) {
      final servers = dnsOptions['servers'];
      if (servers is List) {
        for (final s in servers) {
          if (s is! Map) continue;
          final server = s['server'];
          final tag = server is Map ? server['tag'] : null;
          if (tag is! String || tag.isEmpty) continue;
          str(s, 'dns_server.$tag.description', 'description');
          final vars = s['vars'];
          if (vars is List) {
            for (final v in vars) {
              if (v is Map && v['name'] is String) {
                varNode(v, 'dns_server.$tag.var.${v['name']}');
              }
            }
          }
        }
      }
    }

    // ping_options.presets[] / speed_test_options.servers[] — по id (§279
    // Phase 0: новые поля; runtime-выбор speed-сервера переведён на id).
    final ping = t['ping_options'];
    if (ping is Map) {
      final presets = ping['presets'];
      if (presets is List) {
        for (final p in presets) {
          if (p is Map && p['id'] is String) {
            str(p, 'ping.${p['id']}.name', 'name');
          }
        }
      }
    }
    final speed = t['speed_test_options'];
    if (speed is Map) {
      final servers = speed['servers'];
      if (servers is List) {
        for (final s in servers) {
          if (s is Map && s['id'] is String) {
            str(s, 'speed.${s['id']}.name', 'name');
          }
        }
      }
    }
  }
}
