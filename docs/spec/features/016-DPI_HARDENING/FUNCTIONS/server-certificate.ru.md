[English](server-certificate.md) · [Русский](server-certificate.ru.md)

# Проверка сертификата сервера — хранилище CA, флаг insecure и пин ключа

LxBox даёт выбрать хранилище корневых CA для ядра и сохраняет у каждого узла
флаг `insecure`, пин сертификата и свой CA — целыми и на виду.

| Поле | Значение |
|------|----------|
| Фича | [016-DPI_HARDENING](../FEATURE.ru.md) |
| Обещания | P16 P17 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Держит проверку TLS-сервера такой строгой, как обещала подписка, и
даёт пользователю выбрать набор корневых сертификатов. Проверку
выполняет ядро; приложение отвечает за то, чтобы параметры проверки
не потерялись по дороге и чтобы её ослабление было видно.

## Параметры

| Ручка / вход | Значения | Умолчание | Ключ ядра |
|---|---|---|---|
| Certificate store (настройки ядра) | `system` · `mozilla` · `chrome` | `system` | `certificate.store` |
| `insecure` / `allowInsecure` / `allow_insecure` / `skipCertVerify` / `noverify` … в ссылке | `1`/`true`/`yes` | выкл | `tls.insecure` |
| `pinSHA256` в ссылке hysteria/hysteria2 | base64 SHA-256 публичного ключа, список | — | `tls.certificate_public_key_sha256` |
| JSON узла `tls.certificate` / `certificate_path` / `client_*` | PEM строкой или списком, путь | — | те же ключи |
| Xray `tlsSettings.certificates[0].certificateFile` | путь | — | `tls.certificate_path` |

Подсказка настройки: на Android 7.x и старше системное хранилище
устарело (нет Let's Encrypt и других современных центров) — TLS-узлы не
подключаются; `mozilla`/`chrome` берут актуальный набор, встроенный в
приложение.

## Входы / Выходы

**Входы:** выбор пользователя; параметры ссылок; TLS-поля JSON узла.
**Выходы:** `certificate.store` в конфиге; `tls.insecure`,
`tls.certificate_public_key_sha256`, `tls.certificate*` в outbound'е;
коды `tls_insecure` (info), `xray_cert_chain_pin_unsupported`.

## Правила и инварианты

- `insecure` из ссылки сохраняется (осознанный выбор провайдера), но
  узел получает код `tls_insecure` с путём и значением: защита от MITM
  снята. Все написания параметра читаются без учёта регистра.
- Пин ключа (`pinSHA256`) не теряется ни на разборе, ни в ссылке при
  экспорте; на QUIC (hysteria2) он действует и не срезается. Конфликт с
  `tls.certificate`/`certificate_path` снимается реестром.
- Свой корневой CA узла (`tls.certificate`) и соседние TLS-поля ядра
  проходят разбор и сохранение узла в форме прибытия (строка остаётся
  строкой, список — списком); незнакомые TLS-ключи отбрасываются, чтобы
  ядро не отвергло конфиг.
- Пин цепочки сертификатов Xray (`pinnedPeerCertificateChainSha256`)
  ядру не соответствует: не переносится, узел получает код.
- naive принимает из TLS только `certificate`, `certificate_path`, `ech`;
  `insecure` и пины у него запрещены схемой узла.

## Границы

- Настройки ядра вообще и переносимость в бэкап —
  [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.ru.md); «Certificate
  store» в межплатформенный бэкап не входит.
- Системное хранилище зависит от возможностей ОС.
- Не делается (снято с плана §020F): pinning сертификатов самого
  приложения, шифрованное хранение секретов, маскировка ссылок и
  учётных данных в UI и логах.
- Локальный прокси режима Proxy и его авторизация —
  [010-VPN_SERVICE](../../010-VPN_SERVICE/FEATURE.ru.md).

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [020F](../../../tasks/020F-security-and-dpi-bypass/spec.md) | Закрыто | Зонтичная security-спека; roadmap снят |
| 2 | [179](../../../tasks/179-rc6-platforminterface-systemcertificates-removed.md) | ✅ DEVICE-VERIFIED | Ядро перестало брать системные сертификаты у приложения |
| 3 | [385](../../../tasks/385-certificate-store-selector.md) | Реализовано, PENDING-DEVICE | Выбор хранилища CA: system / mozilla / chrome |
| 4 | [454](../../../tasks/454-tls-certificate-round-trip.md) | Выпущено v2.24.3 | `tls.certificate` и соседи не теряются на правке узла |
