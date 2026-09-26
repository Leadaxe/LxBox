# Contract documentation (mirror)

Эти страницы — копия `contract/docs/generated/**` из репозитория лаунчера,
байт в байт. Их собирает генератор `contract/tools/gendocs` по реестру
контракта; здесь они лежат для того, чтобы ссылка «Learn more» из карточки
предупреждения вела в наш репозиторий, а не в чужой.

| | |
|---|---|
| Версия контракта | `1.1.74` |
| sha256 копии (`app/contract.lock`) | `6b9ce67ff85624bc3ccdc6c683ba0c47f1afa95ec45509aff0efd2350eb923a1` |
| Синхронизировано | `2026-09-26T06:32:51Z` |

**Руками не править.** Правится реестр у лаунчера, сюда изменение приезжает
синхронизацией: `bash app/tool/sync_contract.sh --to <sha>` или
`LX_CONTRACT_SRC=<path> bash app/tool/sync_contract.sh`. Ручная правка
потеряется на следующем прогоне, а тест-страж
(`app/test/contract/docs_mirror_test.dart`) поймает рассинхрон зеркала с
реестром раньше.

Точка входа — [index.md](index.md); коды предупреждений — [warnings.md](warnings.md).
