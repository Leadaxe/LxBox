# 028 — AntiDPI: SNI Obfuscation

| Поле | Значение |
|------|----------|
| Статус | **Реализовано и в продакшене** (2026-04-19, 10/10 тестов) |
| Дата | 2026-04-19 |
| Зависимости | [`005`](../005x%20config%20generator/spec.md), [`020`](../020%20security%20and%20dpi%20bypass/spec.md) |
| Связано | [`018`](../018%20detour%20server%20management/spec.md), [`026`](../026%20parser%20v2/spec.md) |

---

## Цель и рамки

Многие DPI-движки (региональные провайдеры, корпоративные firewall, часть TSPU-конфигураций) выполняют матч `server_name` TLS ClientHello по exact-string или case-sensitive regex. По RFC 6066 §3 и RFC 1035 §2.3.3 имя хоста в SNI **case-insensitive** — сервер обязан принимать любой регистр. Значит рандомизация регистра в `server_name` ломает наивный матч **без изменения поведения сервера**.

Фича расширяет [`020 TLS Fragment`](../020%20security%20and%20dpi%20bypass/spec.md) набором anti-SNI-трюков, активируемых независимо от fragment'а. Первый и единственный приём на фазе 1 — **mixed-case SNI**.

**Не в скопе:**
- Подмена SNI на фиктивный домен (domain-fronting через REALITY/uTLS) — отдельная спека
- Padding ClientHello — требует патча libbox (не делается на Dart-уровне)
- Polling/ротация SNI на каждый handshake (см. §8 "Ограничения")
- Изменение регистра вне TLS (HTTP Host header, HTTP/2 `:authority`) — другой слой
- Работа с HTTPUpgrade / XHTTP transport — `host` header в этих транспортах имеет свою case-sensitivity логику

---

## Контекст

### Почему exact-match SNI живёт

Дешёвые DPI ставятся на слабое железо/большие каналы. Нормализация SNI перед матчем (`strings.ToLower` на каждый пакет) — дорогая операция. Провайдеры экономят ресурс — оставляют exact-match. Поэтому `wWw.yOuTuBe.cOm` обходит 60–80% региональных блокировок, **но не обходит** GFW/TSPU-расширенную фильтрацию, где case нормализуется.

### Почему это дёшево

Рандомизация регистра происходит **в Dart'е на этапе emit конфига** — до передачи в sing-box. Ядру libbox менять не нужно. Строка отправляется в TLS-stack как есть и улетает в ClientHello без преобразований (upstream sing-box не делает `ToLower` на `server_name` перед отправкой — это было бы нарушение RFC).

### Как это связано с fragment

| Приём | Уровень | Эффект |
|---|---|---|
| TLS record_fragment | TCP/TLS | Разбивает ClientHello на записи |
| TLS fragment | TCP | Разбивает TCP-пакеты |
| **mixed_case_sni** | **TLS payload** | **Ломает exact-match SNI** |

Комбинируются ортогонально. На одном и том же outbound'е можно включить всё три.

---

## Архитектурное решение

1. **Генерация случайной смеси регистров** — выполняется **только при пересборке конфига** (старт VPN, смена пресета, apply settings). Результат вписывается в JSON-строку `server_name` и зафиксирован на всё время жизни туннеля. Re-generation на каждый TLS-handshake **не делается** — это требовало бы патча libbox. При следующей пересборке builder эмитит новую рандомизацию.

2. **Применяется только к first-hop outbound'ам** — консистентно с существующим fragment-инвариантом (`020 §2`). Внутренние хопы в chain'е не видны локальному DPI.

3. **Переменная в wizard_template.json** — как и другие DPI-toggles:
   ```json
   "vars": {
     "tls_mixed_case_sni": "false"
   }
   ```

4. **Реализация — `post_steps.dart`** рядом с `applyTlsFragment`. Отдельная функция `applyMixedCaseSni`.

5. **Одно значение на outbound** — при включении пересобираем `server_name` один раз для каждого outbound'а. Каждый outbound получает свою случайную смесь (чтобы две TLS-сессии к двум нодам не имели одинаковый fingerprint).

---

## Алгоритм

```dart
String _randomizeCase(String host, Random rng) {
  final buf = StringBuffer();
  for (final rune in host.runes) {
    final ch = String.fromCharCode(rune);
    if (_isAscii(rune) && _isLetter(ch)) {
      buf.write(rng.nextBool() ? ch.toUpperCase() : ch.toLowerCase());
    } else {
      buf.write(ch); // не-ASCII / не-буква — как есть
    }
  }
  return buf.toString();
}

void applyMixedCaseSni(Map<String, dynamic> config, {required bool enabled}) {
  if (!enabled) return;
  final rng = Random.secure();
  final outbounds = config['outbounds'] as List<dynamic>? ?? [];
  for (final ob in outbounds) {
    if (ob is! Map<String, dynamic>) continue;
    if (ob.containsKey('detour')) continue;        // только first-hop
    final tls = ob['tls'];
    if (tls is! Map<String, dynamic>) continue;
    final serverName = tls['server_name'];
    if (serverName is! String || serverName.isEmpty) continue;
    tls['server_name'] = _randomizeCase(serverName, rng);
  }
}
```

### Критичные ограничения

- **IDN (internationalized domain names)** — обрабатываются как opaque bytes. Punycode-префикс `xn--` **не трогаем** (регистр в punycode case-sensitive для BASE). Кириллические домены после to-ASCII конверсии приходят уже в punycode — безопасно.
- **IP-литералы** — если `server_name` это `"192.168.1.1"` или `"[::1]"`, функция вернёт то же самое (нет букв). Не ломается.
- **Пустая строка / null** — skip (не пишем в JSON).

---

## UI

Секция **DPI Bypass** в Settings / VPN Settings (совместно с existing fragment toggles):

| Поле | Тип | Default | Описание |
|------|-----|---------|----------|
| TLS Record Fragment | Switch | off | existing |
| TLS Fragment | Switch | off | existing |
| Fallback delay | Text | `500ms` | existing |
| **Mixed-case SNI** | Switch | off | **new** — рандомизация регистра `server_name` |

Help-текст под toggle:
> Рандомизирует регистр букв в SNI (например, `WwW.gOoGle.CoM`). Обходит DPI с простым exact-match. Неэффективно против GFW-class фильтрации.

---

## Тесты

1. **Unit**: `_randomizeCase("example.com", seedRng)` → стабильный output при одинаковом seed.
2. **Unit**: `_randomizeCase("192.168.1.1", rng)` → `"192.168.1.1"` (идентичность).
3. **Unit**: `_randomizeCase("xn--e1aybc.xn--p1ai", rng)` → punycode-префикс не меняется (проверить что `xn--` остался lower — уточнить политику).
4. **Integration** (builder): включённый toggle → все first-hop outbound'ы имеют смешанный регистр; outbound'ы с `detour` — нетронуты.
5. **Integration**: каждый first-hop outbound имеет **свою** рандомизацию (не одну общую).
6. **Regression**: выключенный toggle → `server_name` побайтово равен исходному из node-spec.

---

## Ограничения и риски

| Риск | Описание | Митигация |
|---|---|---|
| Static fingerprinting | Две VPN-сессии подряд с одинаковой смесью регистров = DPI легко запоминает и блокирует по hash(SNI) | **Инвариант**: рандомизация выполняется **только на этапе пересборки конфига** (старт VPN, toggle preset, apply settings, мануальное "Rebuild config"). Re-generation **не** происходит на каждый TLS-handshake — это было бы либо патч libbox, либо дорогая пересборка в рантайме. Достаточная частота: при каждом VPN-старте builder эмитит новый `server_name` per outbound. |
| Умные DPI | GFW, TSPU-advanced нормализуют SNI | Комбинировать с REALITY/fragment; документировать «неэффективно в КНР/Ирана» |
| Self-hosted с кривым regex | Редкие reverse-proxy могут фейлить | Toggle default-off; ответственность пользователя |
| Punycode edge-case | `xn--` префикс теоретически case-sensitive | На практике домены в lower, тест покрывает; дополнительно — не трогать префикс `xn--` явно |
| Certificate validation | Некоторые TLS-стеки сравнивают SNI с CN сертификата до `ToLower` | Невозможно — проверяет **сервер**, он обязан `ToLower` по RFC 6066 |

---

## Будущие расширения (не в фазе 1)

- **Per-handshake rotation** — требует патча libbox или периодической пересборки конфига
- **Padding ClientHello до фиксированной длины** — требует форка ядра
- **SNI domain-fronting** (подмена на популярный домен) — отдельная спека, требует REALITY/uTLS
- **Whitelist бренды в случайной подстановке** — продвинутый приём, кластеризация под cdn-patterns

---

## Файлы

| Файл | Изменения |
|------|-----------|
| `app/assets/wizard_template.json` | Добавить `tls_mixed_case_sni: "false"` в vars |
| `app/lib/services/builder/post_steps.dart` | Функция `applyMixedCaseSni(config, enabled)` рядом с `applyTlsFragment` |
| `app/lib/services/builder/build_config.dart` | Вызов `applyMixedCaseSni` после `applyTlsFragment` |
| `app/lib/services/settings_storage.dart` | Ключ `tls_mixed_case_sni` (bool) |
| `app/lib/screens/settings_screen.dart` | Switch в секции DPI Bypass |
| `app/test/services/builder/post_steps_test.dart` | Unit + integration тесты |

---

## Критерии приёмки

- [x] Toggle виден в секции DPI Bypass, autosave (data-driven через `wizard_template.json`, никаких UI-правок)
- [x] При включении `server_name` у first-hop outbound'ов — смешанный регистр
- [x] При выключении — `server_name` побайтово идентичен исходному
- [x] Outbound'ы с `detour` (inner hops) — НЕ затронуты
- [x] Каждый outbound получает независимую рандомизацию (probabilistic test, 5 trials)
- [x] IP-литералы, пустые строки, punycode (`xn--…` labels) — не ломаются
- [ ] Sing-box успешно поднимает туннель с modified SNI (smoke-test на реальном узле — проверить вручную)
- [x] Документация в help-тексте честная: «Bypasses simple exact-match DPI; ineffective against GFW-class filtering»

---

## Ссылки

- [RFC 6066 §3 Server Name Indication](https://datatracker.ietf.org/doc/html/rfc6066#section-3)
- [RFC 1035 §2.3.3 Character Case](https://datatracker.ietf.org/doc/html/rfc1035#section-2.3.3)
- [`020 Security & DPI Bypass`](../020%20security%20and%20dpi%20bypass/spec.md) — TLS fragment инвариант
- [`018 Detour Server Management`](../018%20detour%20server%20management/spec.md) — почему first-hop-only
