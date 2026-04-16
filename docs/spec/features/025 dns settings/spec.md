# 025 — DNS Settings

## Контекст

Сейчас DNS настраивается через 4 скалярные переменные в Settings (dns_strategy, dns_independent_cache, dns_default_domain_resolver, dns_final). Нет возможности управлять DNS серверами и DNS правилами — они зашиты в wizard template.

В лаунчере (Go десктоп) есть полноценная вкладка DNS:
- Список DNS серверов с enable/disable, add, edit (JSON), delete
- DNS rules (JSON editor)
- Strategy, independent_cache, final, default_domain_resolver — дропдауны/чекбокс
- Locked серверы (из шаблона) — видны но не редактируемы

Нужен аналогичный экран для мобильного приложения.

## Концепция

Отдельный экран **DNS Settings**, доступный из drawer (рядом с Routing и VPN Settings).

### Секции экрана

#### 1. DNS Servers

Список DNS серверов. Каждый сервер — JSON объект sing-box формата:

```json
{
  "type": "udp",
  "tag": "dns_cloudflare",
  "server": "1.1.1.1",
  "server_port": 53,
  "enabled": true,
  "description": "Cloudflare public DNS"
}
```

**UI элементы:**
- Switch enabled/disabled на каждом сервере
- Subtitle: `tag · type · server` (аналог лаунчера)
- Кнопка Edit → JSON editor (bottom sheet или fullscreen)
- Кнопка Delete (с подтверждением)
- Кнопка Add → шаблон нового сервера
- Locked серверы (из wizard_template) — switch disabled, edit/delete disabled

#### 2. DNS Strategy

Дропдаун: `prefer_ipv4`, `prefer_ipv6`, `ipv4_only`, `ipv6_only` (из wizard_template vars).

#### 3. Independent Cache

Чекбокс / Switch.

#### 4. DNS Rules

JSON editor (MultiLineEntry) для массива DNS rules. Формат — sing-box `dns.rules`.

Для MVP: текстовое поле с JSON. В будущем — визуальный builder.

#### 5. DNS Final + Default Domain Resolver

Два дропдауна:
- **Final** — тег DNS сервера для fallback (аналог route.final для DNS)
- **Default Domain Resolver** — тег DNS сервера для резолва доменов в DNS серверах

Опции обоих — теги enabled DNS серверов.

### Пресеты серверов

При нажатии **+** открывается список пресетов (не пустой JSON). Пользователь выбирает — сервер добавляется готовый, можно отредактировать.

| Пресет | type | server | port | Примечание |
|--------|------|--------|------|------------|
| Cloudflare | tls | 1.1.1.1 | 853 | Быстрый, глобальный |
| Cloudflare HTTPS | https | https://1.1.1.1/dns-query | — | DoH |
| Google | tls | 8.8.8.8 | 853 | |
| Google HTTPS | https | https://dns.google/dns-query | — | DoH |
| Yandex | udp | 77.88.8.8 | 53 | Базовый |
| Yandex Safe | udp | 77.88.8.88 | 53 | Блокирует фишинг |
| Yandex Family | udp | 77.88.8.7 | 53 | + блокирует adult |
| Yandex DoT | tls | common.dot.dns.yandex.net | 853 | |
| Quad9 | tls | 9.9.9.9 | 853 | Блокирует malware |
| AdGuard | tls | dns.adguard-dns.com | 853 | Блокирует рекламу |
| AdGuard Family | tls | family.adguard-dns.com | 853 | + adult |
| Custom | — | — | — | JSON editor с нуля |

### Пресеты DNS правил

При добавлении правил — готовые шаблоны:

| Пресет | Описание | Правило |
|--------|----------|---------|
| RU домены → Yandex | Русские домены резолвить через Yandex DNS | `{"server": "dns_yandex", "rule_set": ["ru-domains"]}` |
| Ads → block | Рекламные домены блокировать | `{"server": "dns_block", "rule_set": ["geosite-category-ads-all"]}` |
| Custom | Пустое JSON правило | `{}` |

Пресеты правил зависят от наличия соответствующих серверов — если Yandex DNS не добавлен, пресет "RU → Yandex" предложит сначала добавить сервер.

### Хранение

В `boxvpn_settings.json`:

```json
"dns_options": {
  "servers": [ ... ],
  "rules": [ ... ]
}
```

Скалярные переменные (strategy, cache, final, resolver) остаются в `vars`.

### Применение в ConfigBuilder

При генерации конфига:
1. Загрузить `dns_options` из settings
2. Если есть пользовательские серверы — заменить `config.dns.servers` (фильтруя disabled)
3. Если есть пользовательские rules — заменить `config.dns.rules`
4. Скалярные переменные подставляются как раньше через `@var_name`

### Шаблонные серверы (locked)

DNS серверы из wizard_template считаются locked:
- Показываются в списке с disabled switch
- Нельзя edit/delete
- Можно enable/disable (влияет на включение в конфиг)

Определение locked: тег сервера совпадает с тегом из `wizard_template.config.dns.servers`.

## UI макет

```
┌──────────────────────────────────┐
│  ← DNS Settings                  │
│                                  │
│  DNS Servers                [+]  │
│  ┌────────────────────────────┐  │
│  │ ☑ dns_main · tls · 1.1.1.1│🔒│
│  │ ☑ dns_ru · udp · 77.88.8.8│🔒│
│  │ ☑ my_dns · https · 8.8.8.8│✏🗑│
│  └────────────────────────────┘  │
│                                  │
│  Strategy        [prefer_ipv4 ▼] │
│  Independent cache          [☑]  │
│                                  │
│  DNS Rules                       │
│  ┌────────────────────────────┐  │
│  │ [{"server":"dns_ru",      │  │
│  │   "rule_set":["ru-dom"]}] │  │
│  └────────────────────────────┘  │
│                                  │
│  Final           [dns_main    ▼] │
│  Default resolver[dns_main    ▼] │
└──────────────────────────────────┘
```

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/dns_settings_screen.dart` | **Новый** — UI экран |
| `lib/services/settings_storage.dart` | getDnsOptions / saveDnsOptions |
| `lib/services/config_builder.dart` | Применение пользовательских DNS серверов и правил |
| `lib/screens/home_screen.dart` | Пункт DNS Settings в drawer |
| `assets/wizard_template.json` | Без изменений (шаблонные серверы определяются из текущего config.dns) |

## Критерии приёмки

- [ ] Экран DNS Settings доступен из drawer
- [ ] Список серверов с enable/disable, add, edit (JSON), delete
- [ ] Locked серверы из шаблона — видны, не редактируемы
- [ ] Strategy дропдаун работает
- [ ] Independent cache чекбокс работает
- [ ] DNS rules JSON editor
- [ ] Final и Default resolver дропдауны — опции из enabled серверов
- [ ] При генерации конфига применяются пользовательские серверы и rules
- [ ] Автосохранение (как в Routing/Settings)
