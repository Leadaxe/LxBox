# Contract documentation (mirror)

Эти страницы — копия `contract/docs/generated/**` из репозитория лаунчера,
байт в байт. Их собирает генератор `contract/tools/gendocs` по реестру
контракта; здесь они лежат для того, чтобы ссылка «Learn more» из карточки
предупреждения вела в наш репозиторий, а не в чужой.

| | |
|---|---|
| Версия контракта | `1.1.107` |
| sha256 копии (`app/contract.lock`) | `b8d9a8aa1e9e1c8fd993ec41f53eebc858c9376072320683d045dfa1fd171c90` |
| Синхронизировано | `2026-09-29T16:30:33Z` |

**Руками не править.** Правится реестр у лаунчера, сюда изменение приезжает
синхронизацией: `bash app/tool/sync_contract.sh --to <sha>` или
`LX_CONTRACT_SRC=<path> bash app/tool/sync_contract.sh`. Ручная правка
потеряется на следующем прогоне, а тест-страж
(`app/test/contract/docs_mirror_test.dart`) поймает рассинхрон зеркала с
реестром раньше.

Точка входа — [index.md](index.md); коды предупреждений — [warnings.md](warnings.md).
