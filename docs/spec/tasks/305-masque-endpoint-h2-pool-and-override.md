# 305 — MASQUE endpoint: расширение h2-пула + ручной override IP:port

## Мотивация (device-verified)

**ВАЖНО — методика:** первый скан (headless-probe при остановленном VPN) дал
ложный вывод «h3 = 0 живых»: headless-probe НЕ поднимает QUIC, отсюда артефакт.
Правильный тест — пинг через **работающий туннель** (боевое ядро). Повторный
скан 400 нод через рабочий VPN дал реальную картину:

- **h3 (QUIC) живёт и на чужих IP блока** — `.198.1/.198.2/.199.1/.199.2`,
  порты **443/4443/8095**. Прошлый вывод «h3 привязан к серверу реги» ОПРОВЕРГНУТ.
- **h2 (HTTP/2)** — блоки `.198`/`.199`, порты **500/4500/8443**.
- Блоки `.197`/`.192` — **0 живых** (убраны из пула).
- Порты РАЗДЕЛЬНЫ по транспорту: h3≠h2 (device-verified).

Итог: **и h3, и h2 варьируют IP:port** (форсинг h3→server снят). Оба сканируются
по своим блокам/портам.

Сейчас:
- пул `masque_v4_cidr` НЕ содержит `162.159.199.0/24` (хотя он живой для h2);
- `masque_port` — одиночный `443` (мультипорт не поддержан);
- ручная регистрация MASQUE (`addMasque`) НЕ даёт задать endpoint — берёт
  server/port из регистрации.

## Что делаем

**A. Пул** — добавить живой блок и мультипорт (asset).
**B. Генератор** — h2 варьирует порт по списку; h3 остаётся на 443/server.
**C. Визард** — ручной override endpoint IP:port, **только для h2**.

h3 во всех частях остаётся привязан к серверу регистрации (константа физики,
не наше ограничение).

---

## A. Пул `app/assets/warp_endpoints.json` (блок `scan`)

- `masque_v4_cidr`: добавить `"162.159.199.0/24"` (device-verified h2-живой).
  Парс (`scan_pool.dart` `strs('masque_v4_cidr')`) уже принимает список любой
  длины — кода не трогает.
- Ввести `masque_ports`: `[443, 500, 1701, 4500, 4443, 8443, 8095]`
  (все device-verified живые для h2). Старый `masque_port: 443` **оставить** —
  для обратно-совместимого фолбэка.

## B. Генератор

### `scan_pool.dart`
- Поле `masquePort` (int) → **`masquePorts` (`List<int>`)**.
- Парс: tolerant — читать `masque_ports` (list) через хелпер `ints`; при
  отсутствии → фолбэк на скаляр `masque_port` → `[value]`; дефолт `[443]`.
  (Защита от рассинхрона asset/код и от старых тест-фикстур.)

### `candidate_generator.dart`
- `_masqueCandidate` (метод знает `proto`): порт →
  `proto == masqueH2 ? _pick(masquePorts) : 443`.
  (h3 порт всё равно затрётся билдером на `acc.port`, но держим осмысленным.)
- `_variationOne` (фаза 2, знает протокол): та же развилка для masque-ветки.
- IP: остаётся `_pick(masqueV4Cidr)` → `randomIpInCidr` для обоих (для h3
  билдер IP игнорирует — `scan_node_builder.dart:77`).

### Не трогаем
- `scan_models.dart` — `ScanCandidate.port` (int) уже несёт любой порт.
- `scan_node_builder.dart` — h3 форсит `acc.server:acc.port`, h2 берёт
  `c.ip:c.port`. Мультипорт h2 «прорастает» сам через `c.port`.

### Замечание (вне scope)
Генератор льёт h3/h2 ~50/50; все h3 садятся на один `acc.server` → дубли.
Эффективность генератора НЕ трогаем в этой таске (отдельная тема).

---

## C. Визард — ручной override endpoint (`warp_wizard_screen.dart`)

MASQUE-блок — standalone `Card` при `if (_isMasque)` (строки 438-581), НЕ в
Advanced-панели. Внутри: Transport h3/h2 (dropdown, `_masqueNetwork`), SNI, idle,
keep-alive. Прецедент гейта по network уже есть: keep-alive `enabled` завязан на
`_masqueNetwork == 'h3'` (строка 547).

### UI — новое, для ОБОИХ транспортов (h3 и h2)
После Transport-блока (endpoint override работает для h3 И h2 — оба варьируют
IP по своим блокам/портам, см. Мотивацию):

- **Endpoint IP** — `TextField` `_masqueIp` (ручной ввод) + 🎲-кнопка «случайный
  из блока» (реюз паттерна dice у SNI). Пусто → регистрационный server.
- **Endpoint port** — `DropdownMenu` (free-text combo) из
  `masquePortsFor(_masqueNetwork)` — набор адаптируется к транспорту (h3 vs h2).
  Пусто → 443.
- Подпись: «Leave IP empty to use the server from registration. HTTP/3 and
  HTTP/2 live on different ports — the list adapts to the transport.»

Список конкретных IP в dropdown НЕ делаем — их сотни, перечисление бессмысленно.
IP = ручной ввод + dice-реролл из блока. **Порт** — combo пресетов по транспорту.

### Источник IP/порта для 🎲
Пула конкретных IP нет — только CIDR. Геттеры на `WarpEndpointPicker`:
`randomMasqueIp()` (случайный IP из блока), `randomMasquePortFor(network)`
(случайный порт набора транспорта).

### Проброс override
- `SubscriptionController.addMasque` — добавить `String? server, int? port`.
- После получения/реюза `account`, перед `_addMasqueNode`, при заданном
  **server ИЛИ port** — пересобрать `MasqueAccount` полным конструктором
  (copyWith НЕ несёт server/port). Пустое поле → значение из реги. Порт-only
  override НЕ теряется. Модель — `scan_node_builder.dart:_masqueUri`.
- `SettingsStorage.setMasqueAccount` пишет **канонический** account (без
  override) — кеш держит регистрационный server.
- `_registerMasque` — распарсить `_masqueIp`/`_masquePort` и передать (для обоих
  транспортов).
- Downstream (`_addMasqueNode`/`toMasqueUri`/`parseMasqueUri`) не трогаем.

### Окно эксперимента (JSON-override пула)
`_askExperiment` заменяет `_askExperimentSize`: количество нод + редактируемый
JSON пула (по умолчанию bundled asset через `WarpEndpointPicker.loadRawJson`).
`_parsePoolJson` → `ScanPool.fromFullJson`; битый JSON → error в диалоге, не
роняет визард. Валидный → `generateWarp(poolOverride:)`. Диалог: контент в
`SingleChildScrollView` (высокий JSON-редактор не должен ронять AlertDialog).

---

## UI-строки (английские, `getLocalText.s`)

- «HTTP/2 works across the whole Cloudflare block — pick any IP/port from the
  pool or type your own.»
- «HTTP/3 uses the server from registration — the endpoint is fixed.»
- «Endpoint IP (optional)», «Port» — через `_label` (как остальные лейблы
  визарда, НЕ через getLocalText — они сырые).
- Русский перевод helper-строк — `assets/l10n/ru/ui.json`.

## Тесты

- `scan_pool_test`: `masque_ports` парсится в список; фолбэк `masque_port`
  (скаляр) → `[443]`; дефолт при отсутствии обоих → `[443]`.
- `candidate_generator_test`: h2-кандидаты получают порт из `masquePorts`
  (не только 443); h3-кандидат остаётся валиден.
- `MasqueAccount` rebuild с override server/port → `toMasqueUri` несёт новый
  `@ip:port`; round-trip через `parseMasqueUri`.
- `addMasque(server:, port:, network:'h2')` → нода с override endpoint;
  `network:'h3'` + override → endpoint игнорируется (server регистрации).
- Существующие тесты со старым `masque_port: 443` — обновить синхронно.

## Границы

- h3 endpoint нигде не переопределяется (device-verified физика).
- Эффективность генератора (h3/h2 50/50, дубли h3) — вне scope.
- MASQUE probe требует остановленного VPN (`__vpn_running__`) — только для
  ручной диагностики, кода не касается.
