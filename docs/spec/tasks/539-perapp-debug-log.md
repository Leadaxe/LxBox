# 539 — per-app: сводка применённых пакетов в логе, только в debug-режиме

| Поле | Значение |
|------|----------|
| Статус | **Done** |
| Дата старта | 2026-09-24 |
| Дата завершения | 2026-09-24 |
| Коммиты | ветка `task-539` → `develop` |
| Связанные spec'ы | §046 (per-app split-tunneling), §049/§069 (allowBypass), §345 (verbose core-логи), §043 (core-лог в Logs) |

---

## Зачем

Форум (4PDA): в режиме белого списка приложение якобы шло в туннель, хотя в
списке его не было; репро на эмуляторе не подтвердилось. По логу пользователя
нельзя было понять, что реально получил `VpnService.Builder`: пакеты, которых
нет на устройстве, `NameNotFoundException` глотался молча. Решение владельца
24.09.2026: лог нужен, но только в режиме отладки.

## Решение

- `BoxVpnService.openTun`, блок per-app (`includePackage` / `excludePackage`):
  при установке туннеля пишется ОДНА строка
  `INFO per-app: mode=<allow|deny|allow+deny|off> allow_bypass=<bool> applied=N [pkg,...] not_installed=M [pkg,...]`.
  Форматирование — `BoxVpnService.perAppDebugLine` (companion).
- Гейт — существующий переключатель **Verbose (TRACE/DEBUG)** (App Settings →
  Diagnostics, §345; prefs `boxvpn_boot.core_logs_verbose`,
  `BootReceiver.isCoreLogsVerbose`), читается так же, как `isAllowBypass`.
  Новых ключей и тумблеров нет.
- Канал: `BoxService.writeDebugMessage` → `lxbox/coreLog` → Logs (источник core)
  и дублем `Log.i` в logcat (строка не теряется, если Flutter не подписан на
  core-лог, например при старте без UI).
- `not_installed` = пакеты, отвергнутые Builder'ом (`NameNotFoundException`),
  плюс пакеты, которые Builder принял, но PackageManager не видит. Вторая
  проверка нужна потому, что на API 34 (эмулятор) Builder принял
  неустановленный `org.mozilla.firefox_beta` без исключения. Проверка идёт только
  в debug-режиме.
- Штатный режим (Verbose выключен): списки не собираются, строка не пишется,
  поведение Builder'а прежнее.

## Проверка

Kotlin-юнит-тестов в проекте нет — проверено руками на эмуляторе `LxBox_test`
(API 34): Verbose включён, `PUT /settings/tun_apps {"mode":"allow","packages":["com.android.chrome","org.mozilla.firefox_beta"]}`,
пересборка конфига, старт VPN. Строка — в отчёте задачи и в `/logs?source=core&q=per-app`.
Ядро само добавляет в include-список пакет LxBox, он виден в `applied`.

## Что осталось

- Строка пишется при каждом `openTun` (старт, reconnect), а не при смене списка
  на лету — список применяется Android только на `establish()`.
- Причина случая с форума не найдена; строка нужна, чтобы её увидеть в логе
  пользователя.
