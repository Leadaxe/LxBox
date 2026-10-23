# Contract documentation (mirror)

Эти страницы — копия `contract/docs/generated/**` из репозитория лаунчера,
байт в байт. Их собирает генератор `contract/tools/gendocs` по реестру
контракта; здесь они лежат для того, чтобы ссылка «Learn more» из карточки
предупреждения вела в наш репозиторий, а не в чужой.

| | |
|---|---|
| Версия контракта | `1.1.136` |
| sha256 копии (`app/contract.lock`) | `b62b444bd7c2637efd27da98718829883a731a936ccbff6c06a5491f88819fc1` |
| Синхронизировано | `2026-10-23T15:06:27Z` |

**Руками не править.** Правится реестр у лаунчера, сюда изменение приезжает
синхронизацией: `bash app/tool/sync_contract.sh --to <sha>` или
`LX_CONTRACT_SRC=<path> bash app/tool/sync_contract.sh`. Ручная правка
потеряется на следующем прогоне, а тест-страж
(`app/test/contract/docs_mirror_test.dart`) поймает рассинхрон зеркала с
реестром раньше.

Точка входа — [index.md](index.md); коды предупреждений — [warnings.md](warnings.md).
