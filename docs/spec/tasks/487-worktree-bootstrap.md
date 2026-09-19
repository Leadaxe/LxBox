# §487 — bootstrap git worktree: libbox, подпись, контракт

| | |
|---|---|
| **Статус** | Реализовано |
| **Дата** | 2026-09-19 |
| **Связанные** | §104 (fetch libbox), §103 (контракт), `scripts/build-local-apk.sh`, `app/tool/sync_contract.sh` |

## Проблема

Параллельные агенты работают в отдельных `git worktree`. В чистом worktree нет
gitignored файлов основного дерева:

| Артефакт | Путь | Без него |
|---|---|---|
| Ядро libbox | `app/android/app/libs/` (`libbox.aar`, `classes.jar`, `.libbox.version`) | сборка APK падает или тянет AAR заново |
| Ключи подписи | `app/android/key.properties`, `upload-keystore.jks` | release подписывается debug-ключом → `INSTALL_FAILED_UPDATE_INCOMPATIBLE` при `install -r` |
| SDK-путь | `app/android/local.properties` | Gradle не находит SDK без `ANDROID_SDK_ROOT` |
| Секреты CI | `.keys/` (симлинк, содержимое не читается) | только для скриптов публикации |
| Копия контракта | `app/contract/` | корпусные тесты скипаются («запустите sync_contract.sh») |

До §486 `app/tool/sync_contract.sh` без `LX_CONTRACT_SRC` тянул чужую версию
контракта и переписывал зеркала — в worktree это было запрещено. Теперь
умолчание скрипта — restore по `source_sha` из lock (зеркала не трогает);
бамп по-прежнему только через `--to` / `LX_CONTRACT_SRC`.

## Решение

Скрипт `tool/worktree_bootstrap.sh`:

- `--main <путь>` — источник симлинков (default: первая запись `git worktree list
  --porcelain`, обычно основное дерево);
- симлинки на `libs/`, ключи подписи, `local.properties`, `.keys/` из основного
  дерева;
- `app/contract/` — `git archive <source_sha> contract` из репозитория
  лаунчера (`~/projects/singbox-launcher` или `LX_CONTRACT_REPO`), sha коммита
  берётся из поля `source_sha=` в `app/contract.lock`; если поля нет — понятная
  ошибка с командой ручного восстановления;
- после распаковки сверка sha256 дерева с `contract.lock`;
- зеркала `app/assets/contract/`, `docs/contract/`, сам `contract.lock` не
  меняются (`git status` в конце, откат при изменении);
- `--clean` снимает симлинки и удаляет `app/contract/`;
- идемпотентен.

Симлинки не должны попадать в git: паттерны `.gitignore` со слэшем на конце
(`.keys/`, `app/android/app/libs/`) накрывают только каталоги, а симлинк для
git — файл; рядом добавлены формы без слэша.

Документация: `docs/BUILD.md` (раздел worktree), `app/CLAUDE.md` (краткая
отсылка).

## Критерии приёмки

- `./tool/worktree_bootstrap.sh` в worktree создаёт симлинки на артефакты
  основного дерева; повторный запуск без изменений;
- `--clean` снимает симлинки и `app/contract/`;
- восстановление контракта работает при наличии `source_sha=` в lock и доступном
  коммите лаунчера; без `source_sha` — ошибка с командой, зеркала не трогаются;
- `git status` после bootstrap не показывает diff в `app/assets/contract/`,
  `docs/contract/`, `app/contract.lock`;
- после bootstrap с контрактом `flutter test -j 2 test/contract/contract_test.dart`
  исполняет кейсы, а не скипает;
- `flutter analyze` без новых issues.
