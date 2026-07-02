# §227 — полноценный IPv6 в туннеле (TUN inet6 + prefer_ipv6)

> **СТАТУС: РЕАЛИЗАЦИЯ.** Только шаблон (`wizard_template.json`). Ядро/native
> не трогаем — обвязка уже готова (см. «Native» ниже).

## Проблема

Шаблон был однобоким по IPv6. У TUN-инбаунда задавался только IPv4-адрес
(`"address": "@tun_address"`), а стратегии резолва стояли на `prefer_ipv4`.
Даже когда провайдер выдаёт рабочий IPv6, туннель не поднимал inet6-адрес на
интерфейсе → приложениям некуда было слать IPv6-пакеты, и весь трафик
сваливался в IPv4. IPv6-сайты (у кого есть AAAA) открывались по старому
IPv4-адресу либо не открывались вовсе.

## Решение

Четыре правки в `app/assets/wizard_template.json`:

1. **Новый var `tun_address6`** (секция TUN) — IPv6-адрес интерфейса, CIDR.
   Дефолт — стандартный sing-box ULA `fdfe:dcba:9876::1/126`.

2. **tun-инбаунд: массив адресов + явный `route_address`.**
   - `"address": ["@tun_address", "@tun_address6"]` — оба семейства на
     интерфейсе. `address` в sing-box 1.14 принимает массив со смешанными
     v4/v6 CIDR (`inet4_address`/`inet6_address` deprecated с 1.10, слиты в
     `address`).
   - `"route_address": ["0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"]` —
     заворачиваем в туннель весь IPv4 и весь IPv6. Каждое семейство разбито
     на две половины вместо `0.0.0.0/0` / `::/0`: единый default-route точно
     совпадает с системным шлюзом и на части устройств «не приживается»;
     две половины покрывают тот же диапазон без конфликта (стандартный приём).

   **Почему `route_address` обязателен, а не полагаемся на авто-роут:** при
   пустом `route_address` + `auto_route` ядро само добавляет только
   `0.0.0.0/0` (IPv4). IPv6-маршрут не создаётся, и на **Android < 13**
   inet6-адрес встаёт на интерфейс, но трафик по нему не роутится. На
   Android 13+ есть native-fallback `addRoute("::", 0)`, на старых —
   нет (см. Native). Явный `::/1`+`8000::/1` чинит все версии.

3. **`dns_strategy` дефолт `prefer_ipv4` → `prefer_ipv6`** (`config.dns.strategy`).

4. **`resolve_strategy` дефолт `prefer_ipv4` → `prefer_ipv6`** (route resolve-rule).

   `prefer_ipv6` = «сначала IPv6, при отсутствии AAAA — IPv4». Fallback
   встроен в семантику `prefer_`, поэтому дефолт безопасен и для сетей без
   IPv6. Это и обеспечивает «сначала v6, потом v4» для реального трафика.

## Что НЕ меняли и почему

- **DNS-серверы (адреса резолверов)** — оставлены на IPv4-дефолтах.
  v6-адреса уже есть в enum'ах (`2001:4860:4860::8888`, `2606:4700:4700::1111`
  и т.д.) как ручной выбор. Форсить v6-адрес резолвера по умолчанию **опасно**:
  в сети без IPv6 запрос на `[2001:...]:53` не ответит → резолв колом, интернета
  нет. v4-резолвер работает всегда и всё равно возвращает AAAA. «Предпочтение
  IPv6» для трафика даёт `strategy`, а не адрес сервера — sing-box не умеет
  v6→v4 fallback транспорта внутри одного DNS-сервера.

## Native (проверено, изменений не требует)

`BoxVpnService.openTun` (`app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt`)
уже симметрично дренирует inet6:

```kotlin
val inet6 = options.inet6Address
while (inet6.hasNext()) { val a = inet6.next(); builder.addAddress(a.address(), a.prefix()) }
```

Никакого IPv4-only гейта нет; `toIpPrefix()` парсит и IPv6. Маршруты для
inet6 тоже обрабатываются. **Ловушка версий:** на API 33+ при наличии
inet6-адреса без явного маршрута срабатывает fallback `addRoute("::", 0)`;
на API < 33 fallback'а нет — IPv6 default route зависит целиком от
`inet6RouteRange`, который ядро наполняет из нашего `route_address`. Отсюда
пункт 2 (явный `route_address` с IPv6-половинками).

## Файлы

- `app/assets/wizard_template.json`:
  - секция TUN — добавлен var `tun_address6`;
  - `config.inbounds[0]` tun-in — `address` → массив, добавлен `route_address`;
  - var `dns_strategy` — дефолт `prefer_ipv6`;
  - var `resolve_strategy` — дефолт `prefer_ipv6`.

## Связано

- Фича шаблона — [`docs/TEMPLATE.md`](../../TEMPLATE.md).
- §121 (routing = король над DNS) — `strategy` живёт и в dns, и в resolve-rule.
