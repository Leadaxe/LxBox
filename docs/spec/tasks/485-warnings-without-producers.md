# §485 — предупреждения без производителей

| | |
|---|---|
| **Статус** | Реализовано |
| **Дата** | 2026-09-19 |
| **Источник** | задача оркестратора: после перевода разбора на движок от реестра пять рукописных классов остались только образцами уровней в тестах §479 |
| **Связанные** | §482 (тексты из реестра, снятие классов), §479 (уровни уведомлений), фича 480 (движок-маппер) |

## Проблема

Пять кодов контракта (`tls_insecure`, `flow_deprecated`, `reality_short_id_invalid`,
`transport_unsupported`, `field_missing`) держались рукописными классами
`NodeWarning`, хотя после миграции URI/body на движок реестра их ставит только
санитайзер (`RegistryWarning` по данным `warnings.json`). В `app/lib` не
осталось ни одного `warnings.add(…)` на эти классы — они жили в тестах уровней
и в `kWarningCodes` как вторая таблица рядом с нормативной.

## Решение

| Код | Было | Стало |
|---|---|---|
| `tls_insecure` | `InsecureTlsWarning` | `RegistryWarning` (реестр `tls.json` → `insecure`, advisory) |
| `flow_deprecated` | `DeprecatedFlowWarning` | `RegistryWarning` (`protocols/vless.json` → `flow`) |
| `reality_short_id_invalid` | `RealityShortIdInvalidWarning` | `RegistryWarning` (`tls.json` → `reality.short_id`) |
| `transport_unsupported` | `UnsupportedTransportWarning` | `RegistryWarning` (`transports.json`) |
| `field_missing` | `MissingFieldWarning` | `RegistryWarning` (санитайзер обязательных полей) |

Классы, записи `kWarningCodes` и `handwrittenWarningPath`, ключи l10n их
текстов (ru/zh) сняты. Образцы уровней в `node_notifications_test.dart` и
соседних тестах заменены на живые `RegistryWarning` тех же кодов.

## Критерии приёмки

- В `app/lib` нет классов и производителей для пяти кодов; предупреждения
  приходят только как `RegistryWarning`.
- `flutter analyze` — без новых issues.
- Затронутые тесты зелёные; чекеры `tool/l10n/*_check.dart --strict` — 0
  failures / 0 warnings.
- Таблица «код → производитель или удалён» в отчёте исполнителя.
