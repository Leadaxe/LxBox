# §172 — Битый detour роняет весь конфиг: деградация вместо fatal

**Тип:** bug-fix
**Статус:** Реализовано (device-verified, программно)
**Связано:** §084 H1 (detour-валидация), §073 (detour policy), §169 (тот же
паттерн: битая ссылка деградирует, не роняет конфиг)

## Симптом

На экране Servers: `Config invalid (150 issues): Outbound "🇫🇮 Finland,
Helsinki | 🌐 | [BL]" detour references missing outbound "warp gen"; …`.
Подписка (BLACK LIST) задаёт нодам `detour: "warp gen"` — WARP-цель, которой в
собранном конфиге нет (пресет выключен / не сгенерирован). Один битый detour →
`DanglingDetourRef` (fatal) → sing-box реджектит ВЕСЬ config → VPN не встаёт.

## Корень

`detour` присваивается ноде в `server_list_build.dart` слепо — из нативной
цепочки (`detours.first.tag`) или из `detourPolicy.overrideDetour` — БЕЗ
проверки, что target-tag существует среди всех собранных outbounds. В тот
момент проверить нельзя: другие подписки/пресеты добавляются позже. Проверка
есть только пост-фактум в `validateConfig` (`allTags` уже полон), но она лишь
РЕПОРТИТ fatal, не лечит → конфиг падает целиком.

## Решение (как §169 с REALITY: деградация, не выброс)

Новый post-step `healDanglingDetours(config)` —
[heal_dangling_detours.dart](app/lib/services/builder/post_steps/heal_dangling_detours.dart).
Зовётся в `buildConfig` ПЕРЕД `validateConfig`, когда config собран и все теги
известны. Проходит outbounds+endpoints; у тех, чей `detour ∉ allTags` —
**снимает поле `detour`** (нода работает напрямую, без цепочки). Валидатор уже
не видит dangling ref → конфиг валиден, VPN встаёт.

Снятые detour'ы → в `emitWarnings` (видно юзеру):
`Detour убран: outbound "X" ссылался на отсутствующий "Y" — нода работает
напрямую.`

Решение пользователя 2026-06-26: «нет сервера — автоматически убрать детур».

## Что НЕ делает

- Не трогает валидные detour'ы (цепочки на существующие outbounds/endpoints).
- Не выбрасывает ноду — она остаётся рабочей (прямое соединение).
- Циклы detour (`DetourCycle`) — отдельная fatal-проверка, не трогаем.

## Тесты

`heal_dangling_detours_test.dart`:
- битый `detour:"warp gen"` → снят, нода на месте, removed-запись с owner/target;
- валидный detour (на outbound / на endpoint wireguard) → не тронут;
- несколько битых → все сняты, валидный среди них остался;
- detour на endpoint тоже деградирует;
- нет detour → no-op.

## Открыто (отдельной задачей)

Источник подписки в тексте ошибки/у ноды — чтобы юзер знал ИЗ КАКОЙ подписки
битая нода (сейчас сообщение даёт только tag ноды). Требует протянуть
subscription name в `EmitContext`/`ValidationIssue`. Решение пользователя: «да,
имя подписки в сообщение» — но как отдельный шаг (этот фикс уже снимает fatal
для detour-кейса, так что острота спала).

## Результат (device CPH2411 wifi-adb, 2026-06-26, vc 2822)

✅ ПОДТВЕРЖДЁН программно. `/action/rebuild-config` → конфиг собрался (109941
байт, 248 outbounds+endpoints), **0 битых detour-ссылок** (detour ∉ allTags).
Раньше тот же конфиг падал на `DanglingDetourRef` про `warp gen`. Юнит: 7
degradation-тестов + builder-сьют 185 зелёных.

(Визуальный скрин экрана Servers не снят — телефон под locked keyguard, PIN
неизвестен; данные rebuild подтверждают исчезновение fatal.)
