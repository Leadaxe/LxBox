# 037 — NaïveProxy outbound (parser + emit + share-URI)

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата | 2026-04-25 |
| Issue | [Leadaxe/LxBox#2](https://github.com/Leadaxe/LxBox/issues/2) |
| Зависимости | [`026 parser v2`](../026%20parser%20v2/spec.md), [`docs/PROTOCOLS.md`](../../../PROTOCOLS.md) |
| Лэндинг | v1.6.0 (предв.) |
| Build-tag | `with_naive_outbound` — ✅ присутствует в `singbox-android/libbox` (см. §2) |

---

## 1. Задача

Поддержать **NaïveProxy** как полноправный протокол в Parser v2: пользователь добавляет в подписку строку `naive+https://user:pass@host:443/?...#Label`, в подписочном списке появляется узел, при сборке конфига `buildConfig` отдаёт sing-box outbound `type: "naive"`, в context-menu узла «Copy link» возвращает обратно эквивалентный URI.

**Не цели:**

- Не пишем свой naive-клиент. Heavy lifting делает sing-box / cronet-go внутри libbox.
- Не реализуем naive **server**-direction (только outbound).
- Не валидируем TLS-сертификаты — runtime sing-box.
- **`naive+quic`** в v1 откладываем (см. §10).
- Не делаем JSON-form парсинг в подписках для `type: "naive"` raw outbound — используется тот же `parseSingboxEntry` passthrough что и для других типов; работает as-is.

---

## 2. Build-tag в libbox — проверено

**Status: ✅ resolved.** Изначально это считалось блокером №1, но research показал, что текущий libbox **уже** включает naive.

### 2.1 Факты (проверено 2026-04-25)

1. Канонический build-tag в sing-box — **`with_naive_outbound`** (`include/naive_outbound.go:1`, `protocol/naive/outbound.go:1`).
2. Upstream `cmd/internal/build_libbox/main.go` ([SagerNet/sing-box](https://github.com/SagerNet/sing-box/blob/dev-next/cmd/internal/build_libbox/main.go)) собирает **два** Android-варианта:
   - `libbox.aar` — **main**, `androidApi=23+`, `sharedTags` включают `with_naive_outbound`. ✅
   - `libbox-legacy.aar` — legacy, `androidApi=21+`, `filterTags(sharedTags, "with_naive_outbound")` — naive **удалён**.
3. `release/DEFAULT_BUILD_TAGS` (Linux/Apple/Android) включает `with_naive_outbound`. `DEFAULT_BUILD_TAGS_OTHERS` (BSD, etc.) — не включает; не наш случай.
4. `singbox-android/libbox` ([repo](https://github.com/singbox-android/libbox)) — JitPack-redistributor: один файл `libbox.aar` (main вариант) + `build.gradle` с `maven-publish`. Релизы трекают upstream sing-box в пределах часов:

   | Upstream sing-box | singbox-android/libbox | Δ |
   |-------------------|------------------------|---|
   | v1.13.11 — 2026-04-23 00:44 UTC | 1.13.11 — 2026-04-23 12:46 UTC | +12 h |
   | v1.13.9 — 2026-04-20 09:22 UTC | 1.13.9 — 2026-04-23 08:45 UTC | +3 d |

   → они почти наверняка прогоняют upstream `build_libbox` без модификаций.
5. LxBox `minSdk = 26` (`app/CLAUDE.md`) ≥ `androidApi=23` → main-вариант валиден без legacy-fallback'а.
6. **APK size impact ≈ 0**: cronet-go уже встроен в текущий `libbox-1.12.12.aar` который мы тянем — добавление парсера не подключает новых нативных зависимостей.

### 2.2 Что остаётся как гигиена (а не блокер)

- **Runtime probe / NodeWarning.** Будущие апгрейды libbox теоретически могут регрессировать (например, переход на legacy-вариант). Поэтому в §6.4 оставляем `NaiveBuildTagWarning` и детект ошибки `naive outbound is not included in this build, rebuild with -tags with_naive_outbound` (точная строка из `include/naive_outbound_stub.go`) при старте sing-box. Это defensive-механизм, а не gating-условие.
- **Bump libbox-таргет до ≥1.13.x перед релизом** — желательно, т.к. в 1.13 был ряд фиксов в naive-стеке. Но на v1.6.0 не блокирует, текущий 1.12.12 поддерживает naive (тот же `sharedTags`, репозиторий не менял схему сборки между 1.12 и 1.13).

---

## 3. URI-формат

De-facto стандарт DuckSoft (2020), [gist](https://gist.github.com/DuckSoft/ca03913b0a26fc77a1da4d01cc6ab2f1). Поддерживается NekoBox / NaiveGUI / v2rayN / Hiddify.

### 3.1 Синтаксис

```
naive+https://<user>:<pass>@<host>:<port>/?<params>#<label>
```

`naive+quic://...` — синтаксически валидный, но в v1 **не** обрабатываем (см. §10).

- **Обязательно:** scheme = `naive+https`, `host`. `port` опционален → default `443`.
- **userinfo:** опциональна. Если только одна часть до `@` (без `:`) — это **password**, username пустой (как у hysteria2). Если есть `:` — слева username, справа password.
- **query:**
  - `padding=true|false` — sing-box **не** имеет соответствующего поля. **Игнор + log warning.** В URI сохранять не будем при round-trip.
  - `extra-headers=<urlencoded>` — `Header1: Value1\r\nHeader2: Value2` после URL-decode'а. `\r\n` → `%0D%0A`, `:` → `%3A`.
- **fragment:** human-readable label, `decodeFragment` (как у других протоколов).

### 3.2 Канонические примеры

```
naive+https://user:pass@server.example.com:443/?padding=false#JP-01
naive+https://server.example.com:8443                                    # anonymous, custom port
naive+https://onlypass@server.example.com                                # password only
naive+https://u:p@host?extra-headers=X-User%3Aalice%0D%0AX-Token%3Axyz
naive+https://u:p@host:443/?extra-headers=X-Forwarded-Proto%3Ahttps#%E2%9C%85%20DE
```

### 3.3 Что **не** в скопе v1

- `naive+quic://` — sing-box `naive` outbound в текущей версии библиотеки выполняет HTTPS поверх TCP, QUIC-mode зависит от cronet capabilities и ill-defined в URI. Откладываем в §10.
- `sni=`, `alpn=`, `fp=`, `insecure=` — **не** в de-facto спеке URI. NaïveProxy фундаментально завязан на Chrome TLS-fingerprint cronet'а, кастомизировать TLS-параметры через URI не принято. Если юзер очень хочет — правит JSON руками в редакторе конфига (spec 007).
- Multi-server URI, `insecure_concurrency` — не в спеке, не в клиентах.

---

## 4. Маппинг URI → sing-box outbound

[sing-box naive outbound docs](https://sing-box.sagernet.org/configuration/outbound/naive/).

### 4.1 JSON-форма

```json
{
  "type": "naive",
  "tag": "<tag>",
  "server": "<host>",
  "server_port": <port>,
  "network": "tcp",
  "username": "<user>",
  "password": "<pass>",
  "tls": {
    "enabled": true,
    "server_name": "<host>"
  }
}
```

С `extra-headers`:

```json
"extra_headers": {
  "X-User": "alice",
  "X-Token": "xyz"
}
```

### 4.2 Правила

1. `tls.enabled: true` **всегда** — naive без TLS бессмыслен.
2. `tls.server_name = server` (host из URI). Кастомный SNI через URI не поддерживается (см. §3.3).
3. **Никаких `alpn`, `min_version`, `utls`, `reality`, `fingerprint`, `insecure`** в TLS-блоке naive: sing-box их там не принимает. Это отдельная ветка от vless/trojan TLS-сборки.
4. `network: "tcp"` — явное указание, чтобы будущий QUIC-апгрейд (`network: "udp"`) не зацепил v1.
5. Если username пустой и password пустой — выпускаем без `username`/`password` (anonymous, sing-box примет).
6. Если только password (без `:` в userinfo) — `password = userinfo`, `username` отсутствует в JSON.

### 4.3 Парсинг extra-headers

URL-decoded строка вида `Header1: Value1\r\nHeader2: Value2`:

1. Split по `\r\n`.
2. Для каждой строки split по **первому** `:`.
3. Trim обе половины.
4. Header name validation (charset из DuckSoft):
   ```
   ^[!#$%&'*+\-.0-9A-Z\\^_`a-z|~]+$
   ```
5. Невалидные пары → drop с `app_log` warning. Остальные — сохранить.

Значение (value): любой байт кроме `\r`, `\n`, `\0`. Не пытаемся парсить дальше — оставляем как `String`.

---

## 5. Маппинг outbound → URI (round-trip / share-URI)

### 5.1 Правила

1. Scheme = `naive+https` (в v1 quic недоступен).
2. userinfo:
   - оба пустые → нет userinfo.
   - только password → `naive+https://<pass>@host:port`.
   - оба → `naive+https://<user>:<pass>@host:port`.
3. host/port из `server`/`server_port`. Если port==443, в URI **опускаем** (`naive+https://...host` без `:443`) — соответствует canonical-форме примеров DuckSoft.
4. fragment = `encodeFragment(label)` (та же утилита что для vless/trojan).
5. query:
   - `extra-headers` если `extra_headers` non-empty: ключи **сортируем лексикографически** (для детерминированного round-trip), соединяем `Header: Value` через `\r\n`, всё → `Uri.encodeQueryComponent`.
   - `padding` **не пишем** (sing-box про это не знает — изобретать нечестно).
6. Если в `extra_headers` ключ нарушает charset — skip с `app_log` warning, остальные сохраняем (defensive — на write такого быть не должно, но encoder робастный).

### 5.2 Round-trip инварианты

`parseUri(spec.toUri()).toUri() == spec.toUri()` — для:

- наличия/отсутствия userinfo;
- набора `extra_headers` (после сортировки);
- label с UTF-8 / emoji.

**Теряется в round-trip (by design):**

- `padding=true|false` в исходном URI — sing-box не хранит, мы тоже не хранили; на выходе пропадает.
- Порядок ключей `extra-headers` — нормализуется к лексикографическому.

---

## 6. Архитектура (LxBox Parser v2)

### 6.1 Sealed `NaiveSpec`

`app/lib/models/node_spec.dart` — добавить новый final-класс рядом с другими (Hysteria2 — ближайший по форме):

```dart
final class NaiveSpec extends NodeSpec {
  final String username;          // может быть пустым
  final String password;          // может быть пустым (anonymous)
  final TlsSpec tls;              // enabled=true, serverName=server, без alpn/insecure
  final Map<String, String> extraHeaders;  // отсортирован при сериализации

  NaiveSpec({...});

  @override
  String get protocol => 'naive';

  @override
  SingboxEntry emit(TemplateVars vars) => e.emitNaive(this, vars);

  @override
  String toUri() => e.toUriNaive(this);
}
```

Поле `chained: NodeSpec?` уже есть в base — naive может быть chain'ом любого другого узла как `detour`.

### 6.2 emit + toUri

`app/lib/models/node_spec_emit.dart`:

```dart
Outbound emitNaive(NaiveSpec s, TemplateVars vars) {
  final out = <String, dynamic>{
    'type': 'naive',
    'tag': s.tag,
    'server': s.server,
    'server_port': s.port,
    'network': 'tcp',
  };
  if (s.username.isNotEmpty) out['username'] = s.username;
  if (s.password.isNotEmpty) out['password'] = s.password;
  if (s.extraHeaders.isNotEmpty) {
    final sorted = SplayTreeMap<String, String>.from(s.extraHeaders);
    out['extra_headers'] = sorted;
  }
  out['tls'] = s.tls.toSingbox();   // enabled=true, server_name=host
  if (s.chained != null) out['detour'] = s.chained!.tag;
  return Outbound(out);
}

String toUriNaive(NaiveSpec s) { /* §5 */ }
```

### 6.3 Парсер

`app/lib/services/parser/uri_parsers.dart`:

- В диспетчер `parseUri` — добавить `case 'naive+https': return parseNaive(t);`. Регистр scheme мы уже lower-case'им (строка 15).
- Новая функция `parseNaive(String uri)`:
  - `Uri.tryParse` после `replaceFirst('naive+https://', 'https://')` — стандартный трюк, чтобы `Uri` корректно распарсил host/port/userinfo. В rawUri сохраняем оригинал (`uri`).
  - Извлекаем username/password по логике §3.1.
  - Парсим `extra-headers` через утилиту `_parseNaiveExtraHeaders` в том же файле (≈ 30 LOC).
  - `padding`-параметр — log warning через `app_log` и игнор.
  - Незнакомые query-keys — log warning, но узел всё равно создаём.
  - При невалидной структуре (host пуст, scheme не тот, etc.) — `return null` (общая для парсера v2 политика graceful).

### 6.4 Warnings

`app/lib/models/node_warning.dart` — добавить:

```dart
final class NaiveBuildTagWarning extends NodeWarning {
  const NaiveBuildTagWarning();
}
```

Когда вешаем:

- В `parseNaive` — **не** вешаем по умолчанию. Пусть UI decide на основе runtime-probe (§2.3).
- В `HomeController.startVpn` (или `BoxVpnClient`) — если sing-box отвечает ошибкой `naive outbound is not included in this build, rebuild with -tags with_naive_outbound` (точная строка из upstream `include/naive_outbound_stub.go`) → выставляем флаг `SettingsStorage.vars['libbox_lacks_naive'] = true` и при следующем чтении подписки добавляем warning ко всем `NaiveSpec`-узлам.

### 6.5 PROTOCOLS.md

Добавить новый раздел между «5. Hysteria2» и «6. SSH»:

```
## 5.5 NaïveProxy
...
```

С таблицей URI-параметров, JSON-маппингом, примером, и линком на §037 за деталями.

### 6.6 Файлы — итоговая diff-карта

**Новые:**

- `app/test/parser/uri_naive_test.dart` (≈ 250 LOC)
- `app/test/models/naive_emit_test.dart` (round-trip + emit)
- `docs/spec/features/037 naive proxy/spec.md` — этот файл.

**Изменённые:**

- `app/lib/models/node_spec.dart` — `NaiveSpec` (≈ 30 LOC).
- `app/lib/models/node_spec_emit.dart` — `emitNaive`, `toUriNaive` (≈ 50 LOC).
- `app/lib/models/node_warning.dart` — `NaiveBuildTagWarning`.
- `app/lib/services/parser/uri_parsers.dart` — dispatch + `parseNaive` + `_parseNaiveExtraHeaders` (≈ 80 LOC).
- `app/lib/controllers/home_controller.dart` (или `vpn/box_vpn_client.dart`) — детект ошибки `unknown outbound type: naive`, выставление флага.
- `docs/PROTOCOLS.md` — раздел 5.5.
- `RELEASE_NOTES.md` + `docs/releases/v1.6.0.md` — запись.
- `CHANGELOG.md` — запись.
- `app/CLAUDE.md` — обновить количество поддерживаемых протоколов (с «9» на «10»).
- `app/pubspec.yaml` — bump version.

**Не трогаем:**

- `app/lib/services/builder/build_config.dart`, `server_list_build.dart` — naive ничем не отличается от других outbound'ов в pipeline.
- `app/lib/services/parser/json_parsers.dart` — `parseSingboxEntry` уже принимает любой `type` через passthrough; raw `type: "naive"` в JSON-подписке поедет тем же маршрутом без изменений (но без типизации в `NaiveSpec` — это OK для v1).
- `app/lib/services/parser/transport.dart` — naive не имеет transport-слоя в нашем понимании (cronet всё прячет внутри).

---

## 7. Тесты

`app/test/parser/uri_naive_test.dart`:

- `parses canonical with user+pass+port+label`
- `parses with default port 443 omitted`
- `parses with password-only userinfo` (`naive+https://onlypass@host`)
- `parses anonymous (no userinfo)`
- `parses extra-headers, multiple, sorted on emit`
- `ignores padding query with warning`
- `ignores unknown query keys with warning`
- `rejects invalid scheme (naive:// без +https)` → null
- `rejects empty host` → null
- `rejects URI > 8 KB` → null (общая политика, проверяется в `parseUri`)
- `decodes UTF-8 fragment label`

`app/test/models/naive_emit_test.dart`:

- `emit minimal` → JSON shape без extras
- `emit with extra_headers` → `SplayTreeMap`-сортировка
- `emit anonymous` → нет username/password в JSON
- `emit with chained` → `detour` равен tag chained-узла
- `emit always sets tls.enabled=true and server_name=server`
- `toUri round-trip` для каждой формы из parser-тестов
- `toUri omits :443 port`
- `toUri sorts extra-headers keys`

`app/test/parser/parse_all_test.dart` — добавить наш URI в общий fixture (1 кейс) чтобы проверить что dispatcher не сломался.

**Live-тесты не добавляем.** Публичных naive-серверов почти не существует, и зависимость теста от внешнего сервера — anti-pattern.

---

## 8. UI / UX

- **Subscription detail / NodeRow:** badge `[NAIVE]` в subtitle (как `[VLESS]`, `[TROJAN]`). Иконка в `assets/protocols/`? — посмотреть, если нет общей конвенции, не плодить.
- **NaiveBuildTagWarning** (если выставлен): красный значок warning рядом с node, tooltip / dialog «Your sing-box build does not include NaïveProxy. Tap to learn more» → ссылка на FAQ-секцию `docs/PROTOCOLS.md#5.5-naïveproxy` (там добавим параграф «If you see this warning…»).
- **Copy link** в context-menu — работает «само», т.к. вызывает `spec.toUri()`.

---

## 9. Документация и релиз

В соответствии с release-flow ([memory: feedback_release_flow](../../../../.claude/projects/-Users-macbook-projects-LxBox/memory/feedback_release_flow.md)):

- `docs/spec/features/README.md` — добавить строку 037.
- `docs/PROTOCOLS.md` — раздел «5.5 NaïveProxy».
- `RELEASE_NOTES.md` (EN+RU секции) — «NaïveProxy support: parse `naive+https://` URIs, generate sing-box `type: naive` outbound, share-link round-trip».
- `docs/releases/v1.6.0.md` — то же.
- `CHANGELOG.md` — `[1.6.0] - Added: NaïveProxy outbound (#2)`.
- `app/CLAUDE.md` — счётчик протоколов и упоминание naive в списке моделей.
- `pubspec.yaml` — bump версии.
- `app/README.md` / `README_RU.md` — список поддерживаемых протоколов: добавить NaïveProxy с заметкой о required build tag.

---

## 10. Open questions / отложено

| # | Вопрос | Когда |
|---|--------|-------|
| 1 | `naive+quic://` URI + `quic_congestion_control` в outbound | После того как verifiy что libbox cronet поддерживает QUIC mode и есть стабильный URI-стандарт (на 2026-04 — нет). |
| 2 | Кастомный SNI / ECH через extension к URI | Если community-конвенция эволюционирует. |
| 3 | Bump libbox 1.12.12 → 1.13.x | Желательно перед релизом v1.6.0 — фиксы в naive/cronet. Не блокирует фичу. |
| 4 | Парсинг raw JSON `type: "naive"` в `parseSingboxEntry` с типизацией в `NaiveSpec` | После того как наберём кейсов «юзер кладёт naive в JSON-подписку». Сейчас passthrough работает. |
| 5 | UI-флоу при отсутствии build tag — banner с инструкцией, или просто warning per-node? | Решим на этапе UI implementation после фазы 0. |

---

## 11. Acceptance

- [x] Фаза 0 пройдена: `with_naive_outbound` присутствует в `singbox-android/libbox` (см. §2.1), решение по §2.2 не требуется.
- [ ] `naive+https://` URI парсится в `NaiveSpec`, попадает в подписочный список, не теряется на refresh.
- [ ] `buildConfig` с naive-узлом отдаёт валидный sing-box JSON, который libbox **не** отвергает на parse-фазе.
- [ ] Реальное соединение через тестовый naive-сервер (приватный, локальный) проходит. _(Если возможности нет — этот пункт переезжает в follow-up.)_
- [ ] Unit-тесты ≥ 95% покрытие новых файлов, общий test-suite зелёный (213 → ~225+).
- [ ] Round-trip `parseUri ↔ toUri` тесты проходят для всех канонических форм.
- [ ] PROTOCOLS.md, RELEASE_NOTES, CHANGELOG, releases/vX.Y.Z обновлены в одном PR с реализацией.
- [ ] Release APK arm64-only собирается, размер не вырос больше чем на ожидаемый delta из §2.2 (если выбран вариант A).
