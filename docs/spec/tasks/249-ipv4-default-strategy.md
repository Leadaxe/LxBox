# 249 — ipv4_only дефолт + развязка тумблера IPv6 от prefer_ipv6

## Контекст

Хвост §246: `prefer_ipv6` (ставился тумблером «Enable IPv6») на сетях без
рабочего глобального IPv6 давал мёртвые direct-коннекты. Эксперимент §246
показал: `prefer_*` — сортировка **внутренних** резолвов ядра, проходящие
DNS-ответы приложениям не фильтрует (AAAA утекал при любом prefer). Держать
`prefer_ipv6` глобальным дефолтом при включении v6 — хрупко и почти ничего
не даёт (приложения сами выбирают семейство).

## Решение (согласовано)

`wizard_template.json`:

- `dns_strategy` / `resolve_strategy`: `default_value` → **`ipv4_only`**
  (дефолт `ipv6_enabled=false` — AAAA приложениям не нужен вовсе);
- `on_change` тумблера `ipv6_enabled`:

```jsonc
"@dns_strategy":     {"#if": {"and": ["@ipv6_enabled"], "value": "prefer_ipv4", "else": "ipv4_only"}},
"@resolve_strategy": {"#if": {"and": ["@ipv6_enabled"], "value": "prefer_ipv4", "else": "ipv4_only"}}
```

Включение v6 → `prefer_ipv4` (v6 доступен, но v4-first); выключение →
жёсткий `ipv4_only`. Оба направления детерминированы — любое переключение
вычищает застрявший `prefer_ipv6` из storage у существующих юзеров.
Тонкая настройка остаётся: DNS Settings → Strategy (on_change — разовый
эффект переключения, не форс, §232).

UI-fallback'и `dns_settings_screen.dart` (`?? 'prefer_ipv4'` →
`?? 'ipv4_only'`) синхронизированы с default_value шаблона — иначе экран
показывал не то, что применит билдер при незаписанном var'е.

## Миграция

Нет. Сохранённый `prefer_ipv6` у существующих юзеров не переписываем
(выбор юзера); он уйдёт при первом переключении тумблера либо руками.
Строка в release notes: «включали IPv6 — проверьте DNS Settings → Strategy».

## Файлы

- `app/assets/wizard_template.json` — default_value ×2, on_change, tooltip
- `app/lib/screens/dns_settings_screen.dart` — fallback'и ×2
- `docs/TEMPLATE.md` — пример on_change + семантика тумблера
