# 142 — WARP редизайн: reserved опционален + упрощение пресетов (+ Id/Ip/Ib как будущее)

| Field | Value |
|------|----------|
| Status | In progress |
| Started | 2026-06-16 |
| Trigger | Жалоба Iliya (Крым): WARP-узел из приложения НЕ подключается, ручные конфиги от warp-generator/WireSock — работают. Декодирование: наш i1 валиден (1250б QUIC Initial, GCM-тег ок, SNI внутри), endpoint не важен (дефолтный engage:2408 работает), один рабочий конфиг вообще БЕЗ i1. **Единственное отличие нашего узла от ВСЕХ 4 рабочих конфигов Ильи — `reserved` (client_id).** Все рабочие — БЕЗ reserved. |
| Related | [§025 warp integration](../features/025%20warp%20integration/spec.md) (reserved=client_id); [§126](126-warp-amneziawg-obfuscation.md)/[§136](136-warp-quic-i1-generator.md) (обфускация, i1-генератор); [[project_warp_integration]], [[project_warp_quic_sni_dpi]] |
| Files touched | `services/warp/warp_account.dart`, `controllers/subscription_controller.dart`, `screens/warp_wizard_screen.dart`, `assets/warp_endpoints.json` |

## Часть A — reserved (client_id) опционален [РЕАЛИЗУЕМ СЕЙЧАС]

### Что такое reserved (к чему привязывает)
`reserved` = 3 байта `client_id`, который **Cloudflare выдаёт при регистрации**
(POST /reg → `config.client_id`). **НЕ MAC, НЕ IP** — это идентификатор **записи
устройства в твоём WARP-аккаунте** на стороне Cloudflare. Каждый WG-пакет несёт
его в reserved-поле → Cloudflare понимает «пакет от вот этого зарегистрированного
устройства».

- **warp-generator/WireSock**: общий публичный ключ Cloudflare (`bmXOC...`, тот же
  что у нас) + БЕЗ client_id → обезличенное подключение к общему пулу.
- **наше приложение**: регистрирует отдельную запись устройства → персональный
  client_id → reserved. Эта привязка, видимо, режется (free-аккаунт в
  заблокированном регионе). Ключ общий → можно просто не класть reserved.

### Решение
`reserved` — опция (чекбокс «Bind to this device» в Advanced). Дефолт по галке:
- **обфускация ВКЛ** → reserved **ВЫКЛ** (как рабочие конфиги).
- **обфускация ВЫКЛ** (plain) → reserved **ВКЛ** (§025 своя регистрация).

| Где | Что |
|---|---|
| `warp_account.dart` | `toWireguardConf({includeReserved})` + `toWireguardUri({includeReserved})` |
| `subscription_controller.dart` | `addWarp({bool? includeReserved})` (null → `!obfuscate`) → оба add-пути |
| `warp_wizard_screen.dart` | чекбокс в Advanced; `_includeReserved`, дефолт следует за `_obfuscate` |

## Часть B — упрощение пресетов [РЕАЛИЗУЕМ СЕЙЧАС]

- **Убрать dropdown шаблона QUIC/SIP.** Всегда QUIC (рабочие конфиги — QUIC/DNS,
  SIP не востребован; device-smoke прошёл QUIC). SIP-генератор кода остаётся, но
  из UI-выбора убран.
- **Оставить параметры QUIC** в Advanced: SNI (combo-box), level, Jc/Jmin/Jmax.
- **Добавить `ozon.ru`** в SNI-пул (`assets/warp_endpoints.json`) — WireSock-доки
  и рабочий конфиг Ильи прямо его используют (`Id=ozon.ru`).

## Часть C — Id/Ip/Ib декларативная мимикрия [БУДУЩЕЕ, требует ядра]

**Источник формата — WireSock Secure Connect** (НЕ Amnezia; офиц. Amnezia-дока
`Id/Ip/Ib` не знает, только `I1..I5`):

| Поле | Значение | Допустимо |
|---|---|---|
| `Id` | Domain — домен маскировки | популярный домен региона (`ozon.ru`, `google.com`) |
| `Ip` | Protocol — протокол | **QUIC** или **DNS** |
| `Ib` | Browser — fingerprint | **Chrome / Firefox / cURL** (только при QUIC) |

Декларативный фронт: вместо ручного `I1=<b 0x…>` три строки, **движок генерит
пакет сам**. **НО наше ядро `sing-box-lx v1.13.13-lx.10` (форк amneziawg-go)
формат `Id/Ip/Ib` НЕ понимает** — это движок WireSock. Конфиг Ильи с
`Id=ozon.ru/Ip=dns/Ib=chrome` работал в WireSock на десктопе, не у нас.

**Путь к этому (отдельная большая таска):**
1. Воспроизвести идею нашими `I1`: UI Domain/Protocol/Browser → мы генерим готовый
   i1 (QUIC уже есть с SNI=Domain; добавить DNS-генератор для Ip=dns + browser
   JA3/fingerprint для Ib). Работает на текущем ядре. ← рекомендуемый.
2. ИЛИ затащить WireSock/новый форк в ядро, чтобы оно ело Id/Ip/Ib нативно —
   большая работа (пересборка, совместимость), риск.

Решено (2026-06-16): сейчас НЕ делаем; фиксируем направление. Сначала Часть A+B +
device-smoke reserved.

## Acceptance (Часть A+B)

- [ ] Обфускация ВКЛ + дефолт → узел БЕЗ reserved.
- [ ] Обфускация ВЫКЛ → узел С reserved (§025 не сломан).
- [ ] Чекбокс reserved в Advanced переопределяет дефолт.
- [ ] Dropdown QUIC/SIP убран; всегда QUIC; параметры QUIC в Advanced.
- [ ] `ozon.ru` в SNI-пуле.
- [ ] Тесты: conf/uri с includeReserved=false без reserved; =true с reserved.
- [ ] `flutter analyze` чисто; тесты зелёные.
- [ ] **Device-smoke (Илья): узел БЕЗ reserved подключается.** PENDING.

## NB
Если device-smoke покажет, что reserved НЕ корень — проблема в самой регистрации
(free-аккаунт режется), нужен другой подход. Опция reserved безвредна в любом случае.
