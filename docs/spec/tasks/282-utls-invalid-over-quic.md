# §282 — uTLS/fingerprint поверх QUIC (hysteria2/tuic) = мёртвая нода: срез при эмите

**Тип:** bug-fix
**Статус:** Реализовано
**Связано:** §281 (нормализация fingerprint — но для QUIC его надо не
нормализовать, а убрать), §136/§130 (WARP/MASQUE QUIC — masque не трогаем,
у него свой h3-путь), ядро sing-box-lx `SPECS/027-UTLS_OVER_QUIC`
(причинно-следственный аудит блокера + предписание app-side лечения)

## Симптом

Нода `hysteria2`/`tuic` с `tls.utls.fingerprint` (обычно `fp=chrome` из
xray-подписок) валидна и стартует, но **не устанавливает ни одного
соединения** — QUIC-хендшейк падает `unsupported usage for uTLS`. Не
config-fatal (валидатор не ловит) → пользователь видит «нода не коннектится»
без причины.

## Корень

uTLS поверх QUIC в ядре не работает в принципе. Выбор TLS-клиента —
`common/tls/client.go:105`: при `utls.enabled` создаётся `UTLSClientConfig`.
QUIC-путь (`sing-quic/qtls/quic.go`, `CreateTransport`/`Dial`) при
non-QUIC-конфиге фолбэчит на `config.STDConfig()`, а
`UTLSClientConfig.STDConfig()` возвращает ошибку `unsupported usage for
uTLS` (uTLS by design не отдаёт `*crypto/tls.Config` — весь смысл в своём
ClientHello). Ни один клиентский конфиг ядра не реализует QUIC-интерфейс,
так что plain-TLS-over-QUIC работает (через `STDConfig()`), а
uTLS-over-QUIC — нет.

**Ключевое:** `fp` на hysteria2/tuic — это мусор генераторов подписок,
которые вешают xray-поля transport-агностично. У Xray transport hysteria2/
tuic секции uTLS нет вообще — `fingerprint` там неоткуда взяться осмысленно
(TUIC в Xray-core вообще нет, а его hysteria2 uTLS к QUIC не применяет).

Аудит ядра `SPECS/027-UTLS_OVER_QUIC` (статус complete) фиксирует, что
настоящий uTLS-over-QUIC на текущих зависимостях **недостижим** и отложен
(тройная стена: ни один TLS-конфиг не реализует `qtls.Config` → фолбэк на
`STDConfig()` = ошибка; `quic-go` прибит к `crypto/tls`; `metacubex/utls`
не пишет обязательный по RFC 9001 §8.2 `quic_transport_parameters` на
preset-пути). Настоящий фикс = форк двух чужих модулей, не осилил даже
Xray. Значит ждать ядро бессмысленно — лечение app-side.

Спека ядра прямо предписывает (§5): «на стороне LxBox — прекратить эмиссию
`fp` для hy2/tuic». И запрещает молчаливый фолбэк на std-TLS с подменой
fingerprint («тихо отправить Go-хелло вместо Chrome = регрессия
безопасности»). Наш срез `utls`-блока этому соответствует: для QUIC
fingerprint неприменим на любом пути, поэтому мы его не подменяем, а
убираем — нода честно идёт под plain-TLS (единственный рабочий путь QUIC).

## Решение

Новый метод `TlsSpec.toSingboxForQuic()` — как `toSingbox()`, но без
`utls` И без `reality`-блоков (reality поверх QUIC мёртв так же —
`RealityClientConfig.STDConfig()` → «unsupported usage for reality», см.
SPEC 027 §1). Применяется в `emitHysteria2`/`emitTuic`
([node_spec_emit.dart](../../../app/lib/models/node_spec_emit.dart)) —
единая точка выхода для ВСЕХ путей входа (URI hysteria2, raw sing-box JSON
для обоих, round-trip). Fingerprint в модели остаётся (round-trip в
share-URI сохраняет `fp`, чтобы не терять данные при ре-экспорте), но в
sing-box конфиг для QUIC не попадает.

TUIC URI-парсер fingerprint и так не пишет; hysteria2 URI-парсер пишет
(нормализованный §281) — но эмит его для QUIC срежет. masque (§130) не
трогаем: у него свой транспорт h3/h2 и отдельная логика.

**Пост-степ-гейт (находка ревью):** `healUnknownUtlsFingerprints` (§281)
итерирует ВСЕ outbound'ы и при `reality.enabled` дописывает `utls`-блок
(лечение TCP-reality). Для hy2/tuic это воскресило бы мёртвую QUIC-ноду
мимо эмиттера, если reality попал в JSON через vars/будущий путь. Гейт: для
`type` hysteria2/tuic post-step **снимает** и `utls`, и `reality`, а не
восстанавливает.

## Что НЕ делает

- Не трогает TCP-протоколы (vless/trojan/vmess/anytls/proxy-https) — там
  uTLS работает и нужен.
- Не трогает masque.
- Не удаляет fingerprint из модели — только из QUIC-эмита (round-trip URI
  сохраняет исходное значение).
- REALITY поверх QUIC не рассматривается (hy2/tuic REALITY не используют).

## Тесты

`test/parser/utls_fingerprint_test.dart` (или round_trip): hysteria2/tuic с
fingerprint → emit-конфиг без `utls`; TCP-протокол с fingerprint → `utls`
на месте; round-trip URI сохраняет `fp`.
