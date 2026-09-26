# Contract documentation (mirror)

Эти страницы — копия `contract/docs/generated/**` из репозитория лаунчера,
байт в байт. Их собирает генератор `contract/tools/gendocs` по реестру
контракта; здесь они лежат для того, чтобы ссылка «Learn more» из карточки
предупреждения вела в наш репозиторий, а не в чужой.

| | |
|---|---|
| Версия контракта | `1.1.78` |
| sha256 копии (`app/contract.lock`) | `a990400c2f5266b152a78e07ab8c8b2b1d9439d971032845cbc13e4010285504` |
| Синхронизировано | `2026-09-26T08:10:26Z` |

**Руками не править.** Правится реестр у лаунчера, сюда изменение приезжает
синхронизацией: `bash app/tool/sync_contract.sh --to <sha>` или
`LX_CONTRACT_SRC=<path> bash app/tool/sync_contract.sh`. Ручная правка
потеряется на следующем прогоне, а тест-страж
(`app/test/contract/docs_mirror_test.dart`) поймает рассинхрон зеркала с
реестром раньше.

Точка входа — [index.md](index.md); коды предупреждений — [warnings.md](warnings.md).
