# 418 — Get WARP: `api.devices.cloudflare.com` по умолчанию, `api.cloudflareclient.com` запасным, список хостов в asset

| Поле | Значение |
|------|----------|
| Статус | Done (unit) · DEVICE-PENDING (регистрация из приложения на телефоне) |
| Дата старта | 2026-09-04 |
| Дата завершения | 2026-09-04 |
| Коммиты | см. ветку задачи |
| Связанные spec'ы | [features/025](../features/025%20warp%20integration/spec.md), [features/130](../features/130%20masque-warp-transport/spec.md), [tasks/305](305-masque-endpoint-h2-pool-and-override.md), [tasks/386](386-warp-endpoint-preset-combobox.md) |

Повод — PR #101 (форк, закрыт автором без обсуждения): среди прочего менял
`WarpApi.base` на `api.devices.cloudflare.com` с комментарием «незабаненная
ссылка на API для Zero Trust». Проверено замером; хост действительно нужен.

## Симптом

Из России «Get WARP» не работает: `api.cloudflareclient.com` не отвечает на
TCP 443 вовсе (не 4xx, не RST — тишина до таймаута). Регистрация падала
через 15 с (тогдашний таймаут) с «network error», узел не добавлялся. Через VPN тот же хост
отвечает нормально.

## Замер (04.09.2026, прямой канал провайдера, egress 93.100.173.230, loc=RU, colo=HEL)

| Хост | TCP 443 | POST /reg | PATCH /reg/{id} masque | GET account | DELETE |
|---|---|---|---|---|---|
| `api.cloudflareclient.com` | timeout | timeout | — | — | — |
| `api.devices.cloudflare.com` | ок | 200 | 200 | 200 | 204 |

Новый хост принимает тот же путь `v0a2158`, те же заголовки и отдаёт тот же
JSON: peer public key, endpoint `162.159.192.x` с портами 2408/500/1701/4500,
license, token; после PATCH — MASQUE-endpoint `162.159.198.2` с портами
443/500/1701/4500/4443/8443/8095. Через VPN (иностранный egress) хост тоже
отвечает 200. 20 регистраций подряд со случайными 32-байтными ключами — все
200, одна ранняя попытка через VPN дала 401 «Invalid public key»
(не воспроизвелась; см. «MASQUE» ниже).

`engage.cloudflareclient.com` в замер не входит: это host WG-пира из ответа
регистрации (data-plane, UDP 2408), к API он отношения не имеет.

## Что стало

**Asset `app/assets/warp_endpoints.json`** — новый раздел, первым в файле:

```json
"api": {
  "hosts": [
    "https://api.devices.cloudflare.com",
    "https://api.cloudflareclient.com"
  ]
}
```

Порядок = предпочтение. Парсится тем же `ScanPool.fromFullJson`, что и пулы
endpoint'ов (значит, доступен и JSON-override окна эксперимента §305):
пустые элементы отбрасываются, хвостовой `/` снимается.

**`WarpApi`** — `base` удалён. URL-хелперы `reg(base)`, `account(base, id)`,
`device(base, id)` принимают хост. `fallbackHosts` — const-копия списка из
asset на случай битого/старого asset; тест `warp_endpoint_picker_test`
держит их равными.

**`WarpClient`** — конструктор принимает `apiHosts` (null → asset → fallback).
`_postReg` перебирает хосты:

| Что случилось на хосте | Действие |
|---|---|
| исключение клиента (SocketException, таймаут `_timeout` = **5 с** на запрос, было 15) | лог `WARP: API host … unreachable`, следующий хост |
| любой HTTP-ответ, включая 4xx/5xx | итог; дальше не идём — хост жив, проблема не в доступности |
| все хосты дали исключение | `WarpException('network error: host1: …; host2: …')` |

Ответивший хост запоминается в `_activeHost`; PATCH enroll (MASQUE), PATCH
license и account идут на него же — устройство и token выданы им.
`WarpClient` живёт один поток регистрации (контроллер создаёт новый на
каждый вызов), между потоками победитель не кэшируется: операция редкая,
цена промаха — один таймаут.

**MASQUE** — первый POST /reg несёт настоящий одноразовый X25519-ключ
(`genKeypair().pub`) вместо `_randomWgKeyB64()` (удалён). Мимикрия та же,
зато нет шанса на «Invalid public key», если хост проверяет точку на кривой.

## Дополнение 05.09.2026 — SNI-пулы

По решению владельца в оба `sni_pool` (WG и MASQUE) добавлены `deepseek.com`,
`mail.ru`, `max.ru`, `vk.ru` — часть набора из PR #101. Все четыре резолвятся.
`consumer-masque.cloudflareclient.com` в DNS **не существует** (ни A, ни AAAA,
ни CNAME на 1.1.1.1) — это SNI, который официальный клиент шлёт на IP
MASQUE-edge. Edge `162.159.198.2:443` с этим SNI доводит TLS до запроса
клиентского сертификата (mTLS ключом регистрации), дальше curl без ключа не
проходит — это ожидаемо; то же с любым другим SNI (edge на имя не смотрит). Он уже первый и
`recommended_sni` в MASQUE-пуле, в WG-пул не добавлен: cloudflare-домены там
режутся по несовпадению SNI с назначением (см. `ScanPool.wgSniPool`).
Остальное из PR #101 (другие ru-домены, список WG-endpoint'ов) не переносилось.

## Проверка утверждений README из PR #101 (05.09.2026)

Замер живыми MASQUE-туннелями: бинарь лаунчера `sing-box 1.14.0-lx.30`,
конфиг с одним masque-outbound (одноразовая consumer-регистрация через
`api.devices.cloudflare.com`, ключ SEC1 DER), egress по `cdn-cgi/trace`.
Прямой канал провайдера (93.100.173.230). Дополнительно: QUIC-хендшейк
`openssl s_client -quic` и TLS по TCP с `cf-ray`.

| Утверждение | Итог | Чем подтверждено |
|---|---|---|
| Хост регистрации `api.devices.cloudflare.com` «незабанен» | верно | см. таблицу выше |
| `.198.*`, `.199.*` — для обычных пользователей | верно | туннели consumer-ключом подняты: 198.0/1/2/3, 199.0/1/2 |
| `.197.*` — только Zero Trust | наполовину | consumer-ключ отвергается на уровне логина, не сети: h3 «login failed», h2 `tls: access denied` (197.1, 197.2). Что ZT туда пускает — не проверить без ZT-аккаунта |
| последний октет 1 → только h3 (UDP) | верно | 198.1/199.1: h3 ок, h2 «remote endpoint has a different …» (по TCP 443 это обычный CDN-edge, отдаёт 530 с cf-ray) |
| последний октет 2 → h3 и h2 | верно | 198.2 h3+h2 ок, 199.2 h2 ок; QUIC-хендшейк на 197.2/198.2/199.2 |
| 0 и 3…255 → только h2 (TCP) | верно на выборке | 198.0/198.3/199.0 h2 ок; h3 на 198.0/198.3/199.3 `CRYPTO_ERROR 0x12a`; TLS-mTLS на 198.77/199.120 по TCP есть. Исключение: 197.3 по TCP — CDN-edge, не MASQUE |
| `.198.*` = colo HEL, `.199.*` = colo LED | верно с этой точки | cf-ray и trace: 198.x → HEL, 199.x → LED; anycast, из другого региона будет иначе. Egress-IP одинаковый (104.28.196.105) |

Практический вывод для пула §305: `h3_v4_cidr` (`.198.1/.2`, `.199.1/.2`) и
широкий h2-блок подтверждены заново; блок `.197` в пул не возвращать. Рецепт
замера — память `project_masque_h3_h2_scan`.

## Вне задачи

- Остальное из PR #101 — замена SNI-пулов на ru-домены и другой список
  WG-endpoint'ов — не проверялось и не переносилось.
- Ошибка при обоих глухих хостах остаётся сетевой; подсказки «зарегистрируй
  через detour» (features/025, Риски) как не было, так и нет.

## Проверка

- `flutter analyze` — чисто; `flutter test test/warp test/services` — зелёные.
  Новые тесты: `test/warp/warp_api_hosts_test.dart` (перебор, таймаут, HTTP
  без перебора, все глухи, fallback без asset, MASQUE на победителе),
  `scan_pool_test` (парс `api.hosts`), `warp_endpoint_picker_test` (asset =
  const).
- curl-замер с российского egress — таблица выше.
- DEVICE-PENDING: «Get WARP» (WG и MASQUE) из приложения на CPH2411 без VPN.

## Docs to update

- [x] `CHANGELOG.md` — Unreleased / Changed
- [x] `README.md`, `README.ru.md` — хост регистрации
- [x] `docs/PRIVACY_POLICY.md`, `docs/PRIVACY_POLICY.ru.md` — куда уходит публичный ключ
- [x] `docs/spec/features/025 warp integration/spec.md` — примечание про хосты, риск, acceptance
