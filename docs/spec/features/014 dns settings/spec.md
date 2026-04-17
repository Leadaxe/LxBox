# 014 — DNS Settings

| Поле | Значение |
|------|----------|
| Статус | Спека |

## Контекст

Сейчас DNS настраивается через 4 скалярные переменные в Settings. Нет возможности управлять DNS серверами и DNS правилами — они зашиты в wizard template.

Нужен отдельный экран **DNS Settings**, доступный из drawer.

## Секции экрана

### 1. DNS Servers

Список DNS серверов. Каждый сервер — JSON объект sing-box формата.

**UI элементы:**
- Switch enabled/disabled на каждом сервере
- Subtitle: `tag · type · server`
- Кнопка Edit → JSON editor
- Кнопка Delete (с подтверждением)
- Кнопка Add → шаблон нового сервера
- Locked серверы (из wizard_template) — switch disabled, edit/delete disabled

### 2. DNS Strategy

Дропдаун: `prefer_ipv4`, `prefer_ipv6`, `ipv4_only`, `ipv6_only`.

### 3. Independent Cache

Чекбокс / Switch.

### 4. DNS Rules

JSON editor (MultiLineEntry) для массива DNS rules.

### 5. DNS Final + Default Domain Resolver

Два дропдауна:
- **Final** — тег DNS сервера для fallback
- **Default Domain Resolver** — тег DNS сервера для резолва доменов

Опции — теги enabled DNS серверов.

## Пресеты серверов

| Пресет | type | server | port |
|--------|------|--------|------|
| Cloudflare | tls | 1.1.1.1 | 853 |
| Cloudflare HTTPS | https | https://1.1.1.1/dns-query | — |
| Google | tls | 8.8.8.8 | 853 |
| Google HTTPS | https | https://dns.google/dns-query | — |
| Yandex | udp | 77.88.8.8 | 53 |
| Yandex Safe | udp | 77.88.8.88 | 53 |
| Yandex Family | udp | 77.88.8.7 | 53 |
| Yandex DoT | tls | common.dot.dns.yandex.net | 853 |
| Quad9 | tls | 9.9.9.9 | 853 |
| AdGuard | tls | dns.adguard-dns.com | 853 |
| AdGuard Family | tls | family.adguard-dns.com | 853 |
| Custom | — | — | — |

## Хранение

В `boxvpn_settings.json`:

```json
"dns_options": {
  "servers": [ ... ],
  "rules": [ ... ]
}
```

## Файлы

| Файл | Изменения |
|------|-----------|
| `lib/screens/dns_settings_screen.dart` | UI экран |
| `lib/services/settings_storage.dart` | getDnsOptions / saveDnsOptions |
| `lib/services/config_builder.dart` | Применение пользовательских DNS серверов и правил |

## Критерии приёмки

- [ ] Экран DNS Settings доступен из drawer
- [ ] Список серверов с enable/disable, add, edit (JSON), delete
- [ ] Locked серверы из шаблона — видны, не редактируемы
- [ ] Strategy дропдаун, Independent cache чекбокс
- [ ] DNS rules JSON editor
- [ ] Final и Default resolver дропдауны
- [ ] Автосохранение (как в Routing/Settings)
